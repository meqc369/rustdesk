// Qianchen Desk: device panel on the main window, modelled on ToDesk.
// Left: my devices (address book) and recent connections. Right: the selected
// device with its connection and power actions.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/login.dart';
import '../../consts.dart';
import '../../models/ab_model.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';

class QianchenDevicesPanel extends StatefulWidget {
  final VoidCallback onShowClassic;
  const QianchenDevicesPanel({Key? key, required this.onShowClassic})
      : super(key: key);

  @override
  State<QianchenDevicesPanel> createState() => _QianchenDevicesPanelState();
}

class _QianchenDevicesPanelState extends State<QianchenDevicesPanel> {
  static const _handlerName = 'qianchen_devices';
  final _search = TextEditingController();
  final Map<String, bool> _online = {};
  String _selectedId = '';
  bool _recentExpanded = false;
  Timer? _timer;
  Worker? _loginWorker;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    platformFFI.registerEventHandler('callback_query_onlines', _handlerName,
        (evt) async {
      final onlines = (evt['onlines'] as String? ?? '').split(',');
      final offlines = (evt['offlines'] as String? ?? '').split(',');
      if (!mounted) return;
      setState(() {
        for (final id in onlines) {
          if (id.isNotEmpty) _online[id] = true;
        }
        for (final id in offlines) {
          if (id.isNotEmpty) _online[id] = false;
        }
      });
    }, replace: true);
    bind.mainLoadRecentPeers();
    _pullAb();
    _loginWorker = ever(gFFI.userModel.userName, (_) => _pullAb());
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _queryOnlines());
    Future.delayed(const Duration(milliseconds: 800), _queryOnlines);
  }

  @override
  void dispose() {
    platformFFI.unregisterEventHandler('callback_query_onlines', _handlerName);
    _timer?.cancel();
    _loginWorker?.dispose();
    _search.dispose();
    super.dispose();
  }

  void _pullAb() {
    if (gFFI.userModel.isLogin) {
      gFFI.abModel.pullAb(force: null, quiet: true);
    }
  }

  void _queryOnlines() {
    final ids = {
      ..._myDevices().map((e) => e.id),
      ...gFFI.recentPeersModel.peers.map((e) => e.id),
    }.toList();
    if (ids.isNotEmpty) bind.queryOnlines(ids: ids);
  }

  bool _isOnline(Peer p) => _online[p.id] ?? p.online;

  String _name(Peer p) {
    if (p.alias.isNotEmpty) return p.alias;
    if (p.hostname.isNotEmpty) return p.hostname;
    return formatID(p.id);
  }

  List<Peer> _myDevices() =>
      gFFI.userModel.isLogin ? gFFI.abModel.currentAbPeers.toList() : [];

  List<Peer> _filterSort(Iterable<Peer> peers) {
    final q = _search.text.trim().toLowerCase();
    final list = peers.where((p) {
      if (q.isEmpty) return true;
      return p.id.contains(q.replaceAll(' ', '')) ||
          p.alias.toLowerCase().contains(q) ||
          p.hostname.toLowerCase().contains(q) ||
          p.username.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) {
      final oa = _isOnline(a), ob = _isOnline(b);
      if (oa != ob) return oa ? -1 : 1;
      return _name(a).toLowerCase().compareTo(_name(b).toLowerCase());
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: gFFI.recentPeersModel,
      builder: (context, _) => Obx(() {
        // Read the reactive values so Obx rebuilds on login and address book changes.
        final loggedIn = gFFI.userModel.userName.value.isNotEmpty;
        final abPeers = loggedIn ? gFFI.abModel.currentAbPeers.toList() : <Peer>[];
        final abIds = abPeers.map((e) => e.id).toSet();
        final mine = _filterSort(abPeers);
        final recent = _filterSort(
            gFFI.recentPeersModel.peers.where((p) => !abIds.contains(p.id)));
        final all = [...mine, ...recent];
        Peer? selected = all.firstWhereOrNull((p) => p.id == _selectedId);
        selected ??= mine.isNotEmpty ? mine.first : null;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 300,
              child: _buildList(context, loggedIn, mine, recent, abPeers,
                  selected?.id ?? ''),
            ),
            VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
            Expanded(
                child: selected == null
                    ? _buildEmptyDetail(context, loggedIn)
                    : _buildDetail(context, selected, abIds.contains(selected.id))),
          ],
        );
      }),
    );
  }

  Widget _buildList(BuildContext context, bool loggedIn, List<Peer> mine,
      List<Peer> recent, List<Peer> abPeers, String selectedId) {
    final onlineCount = abPeers.where(_isOnline).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: translate('Search'),
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18)),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: translate('qc-refresh'),
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: () {
              bind.mainLoadRecentPeers();
              if (gFFI.userModel.isLogin) {
                gFFI.abModel.pullAb(force: ForcePullAb.current, quiet: true);
              }
              _queryOnlines();
            },
          ),
          IconButton(
            tooltip: translate('Classic view'),
            icon: const Icon(Icons.view_list_rounded, size: 20),
            onPressed: widget.onShowClassic,
          ),
        ]).paddingOnly(left: 4, right: 4, top: 10, bottom: 6),
        Expanded(
          child: ListView(
            children: [
              _sectionHeader(
                  context,
                  loggedIn
                      ? '${translate('My devices')} ($onlineCount/${abPeers.length})'
                      : translate('My devices'),
                  expanded: true),
              if (!loggedIn) _buildLoginHint(context),
              if (loggedIn && abPeers.isEmpty)
                _hint(context, translate('qc-no-devices-tip')),
              ...mine.map((p) => _buildItem(context, p, p.id == selectedId)),
              if (recent.isNotEmpty)
                _sectionHeader(
                    context, '${translate('Recent sessions')} (${recent.length})',
                    expanded: _recentExpanded,
                    onTap: () =>
                        setState(() => _recentExpanded = !_recentExpanded)),
              if (_recentExpanded)
                ...recent.map((p) => _buildItem(context, p, p.id == selectedId)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String text,
      {required bool expanded, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Row(children: [
        Icon(expanded ? Icons.arrow_drop_down_rounded : Icons.arrow_right_rounded,
            size: 22),
        Text(text,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ]).paddingSymmetric(vertical: 8, horizontal: 4),
    );
  }

  Widget _hint(BuildContext context, String text) => Text(text,
          style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).textTheme.bodySmall?.color))
      .paddingSymmetric(horizontal: 14, vertical: 6);

  Widget _buildLoginHint(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hint(context, translate('qc-login-tip')),
        ElevatedButton(onPressed: loginDialog, child: Text(translate('Login')))
            .paddingOnly(left: 14, top: 4, bottom: 8),
      ],
    );
  }

  Widget _buildItem(BuildContext context, Peer p, bool selected) {
    final online = _isOnline(p);
    final name = _name(p);
    final sub = p.alias.isNotEmpty && p.hostname.isNotEmpty
        ? '${formatID(p.id)} · ${p.hostname}'
        : formatID(p.id);
    return Material(
      color: selected ? MyTheme.accent.withOpacity(0.12) : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedId = p.id),
        onDoubleTap: () => connect(context, p.id),
        child: Row(children: [
          _statusDot(online),
          const SizedBox(width: 10),
          Opacity(
              opacity: online ? 1 : 0.5,
              child: getPlatformImage(p.platform, size: 20)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).textTheme.bodySmall?.color)),
              ],
            ),
          ),
        ]).paddingSymmetric(horizontal: 14, vertical: 8),
      ),
    );
  }

  Widget _statusDot(bool online) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: online ? const Color(0xFF22B573) : Colors.grey.withOpacity(0.45),
        ),
      );

  Widget _buildEmptyDetail(BuildContext context, bool loggedIn) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.devices_other_rounded,
            size: 56, color: MyTheme.accent.withOpacity(0.5)),
        const SizedBox(height: 12),
        Text(translate(loggedIn ? 'qc-select-device-tip' : 'qc-login-tip'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color)),
      ]).paddingAll(24),
    );
  }

  Widget _buildDetail(BuildContext context, Peer p, bool inAb) {
    final online = _isOnline(p);
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final canEdit = inAb && gFFI.abModel.current.canWrite();
    final system = [
      if (p.platform.isNotEmpty) p.platform,
      if (p.username.isNotEmpty || p.hostname.isNotEmpty)
        [p.username, p.hostname].where((e) => e.isNotEmpty).join('@'),
    ].join(' · ');
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      children: [
        Row(children: [
          getPlatformImage(p.platform, size: 30),
          const SizedBox(width: 12),
          Flexible(
            child: Text(_name(p),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          ),
          if (canEdit)
            IconButton(
              tooltip: translate('Rename'),
              icon: const Icon(Icons.edit_rounded, size: 18),
              onPressed: () => _rename(p),
            ),
          const SizedBox(width: 6),
          _chip(online ? translate('Online') : translate('Offline'),
              online ? const Color(0xFF22B573) : Colors.grey),
        ]),
        const SizedBox(height: 14),
        _infoRow(context, translate('qc-device-id'), formatID(p.id), copy: p.id),
        if (system.isNotEmpty) _infoRow(context, translate('System'), system),
        const SizedBox(height: 18),
        Text(translate('Connect'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _tile(Icons.desktop_windows_rounded, 'Remote control',
              () => connect(context, p.id)),
          _tile(Icons.drive_file_move_rounded, 'File transfer',
              () => connect(context, p.id, isFileTransfer: true)),
          _tile(Icons.terminal_rounded, 'Terminal',
              () => connect(context, p.id, isTerminal: true)),
          if (p.platform == kPeerPlatformWindows ||
              p.platform == kPeerPlatformLinux)
            _tile(Icons.videocam_rounded, 'View camera',
                () => connect(context, p.id, isViewCamera: true)),
        ]),
        const SizedBox(height: 22),
        if (p.platform == kPeerPlatformWindows ||
            p.platform == kPeerPlatformMacOS ||
            p.platform == kPeerPlatformLinux ||
            p.platform.isEmpty) ...[
          Text(translate('Power'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (online)
            Wrap(spacing: 10, runSpacing: 10, children: [
              _powerButton(p, Icons.lock_rounded, 'Lock screen', 'lock'),
              _powerButton(p, Icons.restart_alt_rounded, 'Restart', 'restart'),
              _powerButton(
                  p, Icons.power_settings_new_rounded, 'Shut down', 'shutdown'),
            ])
          else ...[
            _powerButton(p, Icons.power_rounded, 'Wake up remote device', 'wake',
                primary: true),
            const SizedBox(height: 8),
            Text(translate('qc-wake-tip'),
                style: TextStyle(fontSize: 12, color: muted)),
          ],
        ],
      ],
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(fontSize: 12, color: color)),
      );

  Widget _infoRow(BuildContext context, String label, String value,
      {String? copy}) {
    return Row(children: [
      SizedBox(
        width: 72,
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).textTheme.bodySmall?.color)),
      ),
      Expanded(
          child: SelectableText(value, style: const TextStyle(fontSize: 14))),
      if (copy != null)
        IconButton(
          tooltip: translate('Copy'),
          icon: const Icon(Icons.copy_rounded, size: 16),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: copy));
            showToast(translate('Copied'));
          },
        ),
    ]).paddingSymmetric(vertical: 2);
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      width: 92,
      height: 84,
      child: Material(
        color: MyTheme.accent.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 28, color: MyTheme.accent),
            const SizedBox(height: 8),
            Text(translate(label),
                style: const TextStyle(fontSize: 13),
                textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }

  Widget _powerButton(Peer p, IconData icon, String label, String action,
      {bool primary = false}) {
    final busy = _busy.contains('${p.id}/$action');
    final child = busy
        ? const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(icon, size: 18);
    final onPressed = busy ? null : () => _power(p, action, label);
    return primary
        ? ElevatedButton.icon(
            onPressed: onPressed, icon: child, label: Text(translate(label)))
        : OutlinedButton.icon(
            onPressed: onPressed, icon: child, label: Text(translate(label)));
  }

  Future<void> _power(Peer p, String action, String label) async {
    if (action == 'restart' || action == 'shutdown') {
      final ok = await gFFI.dialogManager.show<bool>(
          (setState, close, context) => CustomAlertDialog(
                title: Text(translate(label)),
                content: Text(translate(action == 'restart'
                        ? 'Are you sure you want to restart'
                        : 'Are you sure you want to shut down') +
                    ' ${_name(p)} (${formatID(p.id)}) ?'),
                actions: [
                  dialogButton('Cancel', onPressed: close, isOutline: true),
                  dialogButton('OK', onPressed: () => close(true)),
                ],
                onCancel: close,
                onSubmit: () => close(true),
              ));
      if (ok != true) return;
    }
    final key = '${p.id}/$action';
    setState(() => _busy.add(key));
    String err;
    switch (action) {
      case 'lock':
        err = await bind.mainLockPeer(id: p.id);
        break;
      case 'restart':
        err = await bind.mainRestartPeer(id: p.id);
        break;
      case 'shutdown':
        err = await bind.mainShutdownPeer(id: p.id);
        break;
      default:
        err = await bind.mainWakePeer(id: p.id);
    }
    if (!mounted) return;
    setState(() => _busy.remove(key));
    if (err.isEmpty) {
      showToast(translate(action == 'wake' ? 'wake-sent-tip' : 'Done'));
      if (action == 'shutdown') {
        Future.delayed(const Duration(seconds: 10), _queryOnlines);
      }
    } else if (err == 'Password Required') {
      showToast(translate('shutdown-password-required-tip'));
    } else {
      showToast('${translate('Failed')}: ${translate(err)}');
    }
  }

  void _rename(Peer p) {
    final controller = TextEditingController(text: _name(p));
    gFFI.dialogManager.show((setState, close, context) {
      submit() async {
        final alias = controller.text.trim();
        close();
        if (alias != p.alias) {
          await gFFI.abModel.changeAlias(id: p.id, alias: alias);
        }
      }

      return CustomAlertDialog(
        title: Text(translate('Rename')),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton('OK', onPressed: submit),
        ],
        onCancel: close,
        onSubmit: submit,
      );
    });
  }
}
