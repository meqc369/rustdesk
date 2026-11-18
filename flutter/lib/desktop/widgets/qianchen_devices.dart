// Qianchen Desk: device panel on the main window, modelled on ToDesk.
// Left: my devices (address book) and recent connections. Right: the selected
// device with its connection and power actions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import '../../utils/http_service.dart' as http;

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
  String _selectedId = bind.getLocalFlutterOption(k: 'qc-last-device');
  bool? _recentExpanded;
  String _tag = '';
  Timer? _timer;
  Worker? _loginWorker;
  final Set<String> _busy = {};
  // Public IP, region and LAN IPs per device, from the server.
  Map<String, Map<String, dynamic>> _ips = {};
  final Map<String, String> _savedLan = {};
  String _myPublicIp = '';
  List<String> _myLanIps = [];
  int _tick = 0;

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
    // userName is set before the login dialog stores access_token; pulling
    // right away gets a 401, which logs the user straight back out.
    _loginWorker = ever(gFFI.userModel.userName, (String name) async {
      if (name.isEmpty) return;
      for (var i = 0;
          i < 30 && bind.mainGetLocalOption(key: 'access_token').isEmpty;
          i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (mounted) _pullAb();
      Future.delayed(const Duration(seconds: 2), _fetchIps);
    });
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      _queryOnlines();
      if (++_tick % 5 == 0) _fetchIps();
      if (_tick % 10 == 0) _syncAccount();
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      _queryOnlines();
      _fetchIps();
    });
  }

  @override
  void dispose() {
    platformFFI.unregisterEventHandler('callback_query_onlines', _handlerName);
    _timer?.cancel();
    _loginWorker?.dispose();
    _search.dispose();
    super.dispose();
  }

  void _select(String id) {
    if (id == _selectedId) return;
    setState(() => _selectedId = id);
    bind.setLocalFlutterOption(k: 'qc-last-device', v: id);
  }

  /// Every minute: check the login is still valid (changing the account password
  /// signs every device out) and pull remark names edited on other computers.
  Future<void> _syncAccount() async {
    if (!gFFI.userModel.isLogin) return;
    gFFI.userModel.refreshCurrentUser();
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    if (!gFFI.userModel.isLogin) {
      showToast(translate('qc-login-expired'));
      return;
    }
    gFFI.abModel.pullAb(force: ForcePullAb.current, quiet: true);
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

  bool _isOnline(Peer p) =>
      (_online[p.id] ?? p.online) || _ips[p.id]?['online'] == true;

  bool _isSelf(Peer p) =>
      p.id.isNotEmpty &&
      p.id == trimID(gFFI.serverModel.serverId.text);

  Future<void> _fetchIps() async {
    try {
      final mine = <String>[];
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          final o = a.rawAddress;
          if (a.isLoopback || (o[0] == 169 && o[1] == 254)) continue;
          if (o[0] == 198 && (o[1] == 18 || o[1] == 19)) continue; // VPN fake IPs
          mine.add(a.address);
        }
      }
      _myLanIps = mine;
    } catch (_) {}
    final ids = {
      ..._myDevices().map((e) => e.id),
      ...gFFI.recentPeersModel.peers.map((e) => e.id),
    };
    for (final id in ids) {
      // LAN addresses the device reported on our last connection to it.
      _savedLan[id] = bind.mainGetPeerOptionSync(id: id, key: 'qc-lan-ips');
    }
    if (ids.isEmpty || !gFFI.userModel.isLogin) {
      if (mounted) setState(() {});
      return;
    }
    try {
      final api = await bind.mainGetApiServer();
      final resp = await http.get(
          Uri.parse('$api/qc-api/peer-ips?ids=${ids.join(',')}'),
          headers: getHttpHeaders());
      final body = jsonDecode(decode_http_response(resp));
      if (body is Map && body['code'] == 0 && body['data'] is Map) {
        final data = body['data'] as Map;
        _myPublicIp = data['me']?.toString() ?? '';
        _ips = (data['peers'] as Map? ?? {}).map((k, v) =>
            MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
        // Keep LAN addresses and the server-signed identity with the peer, so a
        // connection can go straight over the LAN without asking the server first.
        _ips.forEach((id, v) {
          for (final kv in [
            ['qc-lan-ips', v['lan']?.toString() ?? ''],
            ['qc-signed-pk', v['spk']?.toString() ?? ''],
          ]) {
            if (kv[1].isNotEmpty &&
                bind.mainGetPeerOptionSync(id: id, key: kv[0]) != kv[1]) {
              bind.mainSetPeerOption(id: id, key: kv[0], value: kv[1]);
            }
          }
        });
      }
    } catch (e) {
      debugPrint('peer-ips: $e');
    }
    if (mounted) setState(() {});
  }

  static bool _sameSubnet(String a, String b) {
    final x = a.split('.'), y = b.split('.');
    return x.length == 4 && y.length == 4 && x[0] == y[0] && x[1] == y[1] && x[2] == y[2];
  }

  String _publicIp(Peer p) => _ips[p.id]?['ip']?.toString() ?? '';

  /// LAN address to show: the one on our own subnet if there is one.
  String _lanIp(Peer p) {
    var raw = _ips[p.id]?['lan']?.toString() ?? '';
    if (raw.isEmpty) raw = _savedLan[p.id] ?? '';
    final list = raw.split(',').where((e) => e.trim().isNotEmpty).toList();
    if (list.isEmpty) return '';
    return list.firstWhere((ip) => _myLanIps.any((m) => _sameSubnet(m, ip)),
        orElse: () => list.first);
  }

  /// Same network as this computer: same subnet and, when known, the same public IP.
  bool _isLan(Peer p) {
    final lan = _lanIp(p);
    if (lan.isEmpty || !_myLanIps.any((m) => _sameSubnet(m, lan))) return false;
    final pub = _publicIp(p);
    return pub.isEmpty || _myPublicIp.isEmpty || pub == _myPublicIp;
  }

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
        final tags = loggedIn ? gFFI.abModel.currentAbTags.toList() : <String>[];
        if (_tag.isNotEmpty && !tags.contains(_tag)) _tag = '';
        final mine = _filterSort(abPeers
            .where((p) => _tag.isEmpty || p.tags.contains(_tag)));
        final recent = _filterSort(
            gFFI.recentPeersModel.peers.where((p) => !abIds.contains(p.id)));
        final all = [...mine, ...recent];
        Peer? selected = all.firstWhereOrNull((p) => p.id == _selectedId);
        selected ??= all.isNotEmpty ? all.first : null;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 280,
              child: _buildList(context, loggedIn, mine, recent, abPeers,
                  selected?.id ?? '', tags),
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
      List<Peer> recent, List<Peer> abPeers, String selectedId,
      List<String> tags) {
    final onlineCount = abPeers.where(_isOnline).length;
    // Collapsed by default only when there are devices of our own to show.
    final recentExpanded = _recentExpanded ?? mine.isEmpty;
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
              _fetchIps();
            },
          ),
          PopupMenuButton<String>(
            tooltip: translate('qc-batch'),
            icon: const Icon(Icons.checklist_rounded, size: 20),
            enabled: mine.isNotEmpty,
            onSelected: (v) => _batch(mine, shutdown: v == 'shutdown'),
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'shutdown',
                  child: Text(translate('qc-batch-shutdown'))),
              PopupMenuItem(
                  value: 'wake', child: Text(translate('qc-batch-wake'))),
            ],
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
              if (loggedIn && tags.isNotEmpty) _buildTags(context, tags),
              if (!loggedIn) _buildLoginHint(context),
              if (loggedIn && abPeers.isEmpty)
                _hint(context, translate('qc-no-devices-tip')),
              ...mine.map((p) => _buildItem(context, p, p.id == selectedId)),
              if (recent.isNotEmpty)
                _sectionHeader(
                    context, '${translate('Recent sessions')} (${recent.length})',
                    expanded: recentExpanded,
                    onTap: () =>
                        setState(() => _recentExpanded = !recentExpanded)),
              if (recentExpanded)
                ...recent.map((p) => _buildItem(context, p, p.id == selectedId)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTags(BuildContext context, List<String> tags) {
    Widget chip(String label, String value, Color? color) {
      final selected = _tag == value;
      return ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        visualDensity: VisualDensity.compact,
        avatar: color == null
            ? null
            : CircleAvatar(backgroundColor: color, radius: 5),
        selectedColor: MyTheme.accent.withOpacity(0.18),
        onSelected: (_) => setState(() => _tag = value),
      );
    }

    return Wrap(spacing: 6, runSpacing: 6, children: [
      chip(translate('All'), '', null),
      ...tags.map((t) => chip(t, t, gFFI.abModel.getCurrentAbTagColor(t))),
    ]).paddingSymmetric(horizontal: 12, vertical: 4);
  }

  Future<void> _batch(List<Peer> peers, {required bool shutdown}) async {
    final targets = peers.where((p) => _isOnline(p) == shutdown).toList();
    if (targets.isEmpty) {
      showToast(translate(shutdown
          ? 'qc-batch-none-online'
          : 'qc-batch-none-offline'));
      return;
    }
    final names = targets.map(_name).join('、');
    final ok = await gFFI.dialogManager.show<bool>(
        (setState, close, context) => CustomAlertDialog(
              title: Text(translate(
                  shutdown ? 'qc-batch-shutdown' : 'qc-batch-wake')),
              content: Text('$names (${targets.length})'),
              actions: [
                dialogButton('Cancel', onPressed: close, isOutline: true),
                dialogButton('OK', onPressed: () => close(true)),
              ],
              onCancel: close,
              onSubmit: () => close(true),
            ));
    if (ok != true) return;
    showToast(translate(shutdown
        ? 'Sending shutdown command...'
        : 'Sending wake-up command...'));
    final results = await Future.wait(targets.map((p) async {
      if (!shutdown) return await bind.mainWakePeer(id: p.id);
      final r = await _serverCommand(p.id, 'shutdown');
      return r == 'skip' ? await bind.mainShutdownPeer(id: p.id) : r;
    }));
    final failed = results.where((e) => e.isNotEmpty).length;
    showToast('${translate('Done')}: ${targets.length - failed}'
        '${failed > 0 ? ', ${translate('Failed')}: $failed' : ''}');
    Future.delayed(const Duration(seconds: 10), _queryOnlines);
  }

  Future<void> _addToMine(Peer p) async {
    final err = await gFFI.abModel
        .addIdToCurrent(p.id, p.alias, '', _tag.isEmpty ? [] : [_tag], '');
    showToast(err == null || err.isEmpty
        ? translate('qc-added-to-my-devices')
        : '${translate('Failed')}: $err');
  }

  Future<void> _removeFromMine(Peer p) async {
    final ok = await gFFI.dialogManager.show<bool>(
        (setState, close, context) => CustomAlertDialog(
              title: Text(translate('qc-remove-from-my-devices')),
              content: Text('${_name(p)} (${formatID(p.id)})'),
              actions: [
                dialogButton('Cancel', onPressed: close, isOutline: true),
                dialogButton('OK', onPressed: () => close(true)),
              ],
              onCancel: close,
              onSubmit: () => close(true),
            ));
    if (ok == true) await gFFI.abModel.deletePeers([p.id]);
  }

  Future<void> _showItemMenu(BuildContext context, Peer p, Offset pos) async {
    final online = _isOnline(p);
    final inAb = gFFI.userModel.isLogin &&
        gFFI.abModel.currentAbPeers.any((e) => e.id == p.id);
    final canEdit = inAb && gFFI.abModel.current.canWrite();
    final desktopPeer = p.platform != kPeerPlatformAndroid;
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem(
            value: value,
            height: 36,
            child: Row(children: [
              Icon(icon, size: 18),
              const SizedBox(width: 10),
              Text(translate(label)),
            ]));
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        item('connect', Icons.desktop_windows_rounded, 'Remote control'),
        item('file', Icons.drive_file_move_rounded, 'File transfer'),
        if (desktopPeer && online) ...[
          const PopupMenuDivider(),
          item('lock', Icons.lock_rounded, 'Lock screen'),
          item('restart', Icons.restart_alt_rounded, 'Restart'),
          item('shutdown', Icons.power_settings_new_rounded, 'Shut down'),
        ],
        if (desktopPeer && !online)
          item('wake', Icons.power_rounded, 'Wake up remote device'),
        const PopupMenuDivider(),
        item('rename', Icons.edit_rounded, 'qc-edit-remark'),
        if (!inAb && gFFI.userModel.isLogin)
          item('add', Icons.add_rounded, 'qc-add-to-my-devices'),
        if (canEdit)
          item('remove', Icons.delete_outline_rounded,
              'qc-remove-from-my-devices'),
      ],
    );
    if (!mounted || v == null) return;
    switch (v) {
      case 'connect':
        connect(context, p.id);
        break;
      case 'file':
        connect(context, p.id, isFileTransfer: true);
        break;
      case 'lock':
        _power(p, 'lock', 'Lock screen');
        break;
      case 'restart':
        _power(p, 'restart', 'Restart');
        break;
      case 'shutdown':
        _power(p, 'shutdown', 'Shut down');
        break;
      case 'wake':
        _power(p, 'wake', 'Wake up remote device');
        break;
      case 'rename':
        _editRemark(p, canEdit);
        break;
      case 'add':
        _addToMine(p);
        break;
      case 'remove':
        _removeFromMine(p);
        break;
    }
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
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final isLan = _isLan(p);
    final ip = isLan ? _lanIp(p) : _publicIp(p);
    return Material(
      color: selected ? MyTheme.accent.withOpacity(0.11) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        hoverColor: MyTheme.accent.withOpacity(0.05),
        onTap: () => _select(p.id),
        onDoubleTap: () => connect(context, p.id),
        onSecondaryTapDown: (d) {
          _select(p.id);
          _showItemMenu(context, p, d.globalPosition);
        },
        child: Row(children: [
          _avatar(context, p, 38, online),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(_name(p),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500)),
                  ),
                  if (_isSelf(p))
                    _chip(translate('qc-this-device'), const Color(0xFFC77A12))
                        .paddingOnly(left: 6),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  Text(formatID(p.id),
                      style: TextStyle(
                          fontSize: 12,
                          color: muted,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  if (ip.isNotEmpty) ...[
                    Text('  ·  ', style: TextStyle(fontSize: 12, color: muted)),
                    if (isLan)
                      Tooltip(
                        message: translate('qc-lan-same-tip'),
                        child: const Icon(Icons.lan_rounded,
                            size: 13, color: MyTheme.accent),
                      ).paddingOnly(right: 3),
                    Flexible(
                      child: Text(ip,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: isLan ? MyTheme.accent : muted,
                              fontWeight:
                                  isLan ? FontWeight.w500 : FontWeight.normal)),
                    ),
                  ],
                ]),
              ],
            ),
          ),
        ]).paddingSymmetric(horizontal: 10, vertical: 9),
      ),
    ).paddingSymmetric(horizontal: 8, vertical: 2);
  }

  /// Platform icon on a tinted tile with a presence dot.
  Widget _avatar(BuildContext context, Peer p, double size, bool online) {
    final dot = size * 0.27;
    return SizedBox(
      width: size + 2,
      height: size + 2,
      child: Stack(children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: (online ? MyTheme.accent : Colors.grey)
                .withOpacity(online ? 0.12 : 0.10),
            borderRadius: BorderRadius.circular(size * 0.28),
          ),
          child: Center(child: _platformIcon(p.platform, size * 0.52, online)),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: online ? const Color(0xFF22B573) : const Color(0xFFB8BEC4),
              border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor, width: 2),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _platformIcon(String platform, double size, bool online) {
    final IconData icon;
    if (platform == kPeerPlatformMacOS) {
      icon = Icons.apple;
    } else if (platform == kPeerPlatformLinux) {
      icon = Icons.terminal_rounded;
    } else if (platform == kPeerPlatformAndroid) {
      icon = Icons.android_rounded;
    } else if (platform.isEmpty) {
      icon = Icons.devices_rounded;
    } else {
      icon = Icons.window_rounded;
    }
    return Icon(icon,
        size: size,
        color: online ? MyTheme.accent : Colors.grey.withOpacity(0.6));
  }

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
    final lanIp = _lanIp(p);
    final isLan = _isLan(p);
    final pub = _publicIp(p);
    final region = _ips[p.id]?['region']?.toString() ?? '';
    final system = [
      if (p.platform.isNotEmpty) p.platform,
      if (p.username.isNotEmpty || p.hostname.isNotEmpty)
        [p.username, p.hostname].where((e) => e.isNotEmpty).join('@'),
    ].join(' · ');
    final desktopPeer = p.platform == kPeerPlatformWindows ||
        p.platform == kPeerPlatformMacOS ||
        p.platform == kPeerPlatformLinux ||
        p.platform.isEmpty;
    final line = Theme.of(context).dividerColor.withOpacity(0.6);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: [
        // Device header with the main action.
        Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                MyTheme.accent.withOpacity(online ? 0.13 : 0.05),
                MyTheme.accent.withOpacity(0.02),
              ],
            ),
            border: Border.all(color: MyTheme.accent.withOpacity(0.12)),
          ),
          child: Row(children: [
            _avatar(context, p, 54, online),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(_name(p),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 18,
                              height: 1.25,
                              fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      tooltip: translate('qc-edit-remark'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.edit_rounded, size: 15, color: muted),
                      onPressed: () => _editRemark(p, canEdit),
                    ),
                  ]),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    if (_isSelf(p))
                      _chip(translate('qc-this-device'), const Color(0xFFC77A12),
                          icon: Icons.person_pin_circle_rounded),
                    _chip(online ? translate('Online') : translate('Offline'),
                        online ? const Color(0xFF1E9E63) : Colors.grey),
                    if (isLan)
                      _chip(translate('qc-lan'), MyTheme.accent,
                          icon: Icons.lan_rounded),
                    if (inAb) _chip(translate('My devices'), const Color(0xFF5B6B9A)),
                  ]),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.desktop_windows_rounded, size: 18),
              label: Text(translate('Remote control'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () => connect(context, p.id),
            ),
          ]),
        ),
        if (!inAb && gFFI.userModel.isLogin)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(translate('qc-add-to-my-devices')),
              onPressed: () => _addToMine(p),
            ),
          ).paddingOnly(top: 6),
        const SizedBox(height: 16),
        // Facts about the device.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).hoverColor.withOpacity(0.45),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(children: [
            _infoRow(context, Icons.tag_rounded, translate('qc-device-id'),
                formatID(p.id),
                copy: p.id),
            if (lanIp.isNotEmpty) ...[
              Divider(height: 1, color: line),
              _infoRow(context, Icons.lan_rounded, translate('qc-lan-ip'), lanIp,
                  copy: lanIp,
                  accent: isLan,
                  hint: isLan ? translate('qc-lan-same-tip') : null),
            ],
            if (pub.isNotEmpty) ...[
              Divider(height: 1, color: line),
              _infoRow(context, Icons.public_rounded, translate('qc-public-ip'),
                  pub,
                  copy: pub, hint: region.isEmpty ? null : region),
            ],
            if (system.isNotEmpty) ...[
              Divider(height: 1, color: line),
              _infoRow(context, Icons.computer_rounded, translate('System'), system),
            ],
            if (p.note.isNotEmpty) ...[
              Divider(height: 1, color: line),
              _infoRow(context, Icons.sticky_note_2_outlined, translate('qc-note'),
                  p.note),
            ],
          ]),
        ),
        const SizedBox(height: 22),
        _sectionTitle(context, translate('qc-more-ways')),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _tile(Icons.drive_file_move_rounded, 'File transfer',
              () => connect(context, p.id, isFileTransfer: true)),
          _tile(Icons.terminal_rounded, 'Terminal',
              () => connect(context, p.id, isTerminal: true)),
          if (p.platform == kPeerPlatformWindows ||
              p.platform == kPeerPlatformLinux)
            _tile(Icons.videocam_rounded, 'View camera',
                () => connect(context, p.id, isViewCamera: true)),
        ]),
        if (desktopPeer) ...[
          const SizedBox(height: 22),
          _sectionTitle(context, translate('Power')),
          const SizedBox(height: 10),
          if (online)
            Wrap(spacing: 10, runSpacing: 10, children: [
              _powerButton(p, Icons.lock_rounded, 'Lock screen', 'lock'),
              _powerButton(p, Icons.restart_alt_rounded, 'Restart', 'restart'),
              _powerButton(
                  p, Icons.power_settings_new_rounded, 'Shut down', 'shutdown',
                  danger: true),
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

  Widget _chip(String text, Color color, {IconData? icon}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) Icon(icon, size: 12, color: color).paddingOnly(right: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 12, color: color, fontWeight: FontWeight.w500)),
        ]),
      );

  Widget _infoRow(BuildContext context, IconData icon, String label, String value,
      {String? copy, bool accent = false, String? hint}) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    return Row(children: [
      Icon(icon, size: 16, color: accent ? MyTheme.accent : muted),
      const SizedBox(width: 10),
      SizedBox(
        width: 76,
        child: Text(label, style: TextStyle(fontSize: 13, color: muted)),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(value,
                style: TextStyle(
                    fontSize: 14,
                    color: accent ? MyTheme.accent : null,
                    fontWeight: accent ? FontWeight.w600 : FontWeight.normal)),
            if (hint != null)
              Text(hint, style: TextStyle(fontSize: 12, color: muted)),
          ],
        ),
      ),
      if (copy != null)
        IconButton(
          tooltip: translate('Copy'),
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.copy_rounded, size: 15, color: muted),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: copy));
            showToast(translate('Copied'));
          },
        )
      else
        const SizedBox(height: 40),
    ]).paddingSymmetric(vertical: 4);
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: MyTheme.accent.withOpacity(0.06),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: MyTheme.accent.withOpacity(0.14))),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        hoverColor: MyTheme.accent.withOpacity(0.10),
        onTap: onTap,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: MyTheme.accent),
          const SizedBox(width: 8),
          Text(translate(label), style: const TextStyle(fontSize: 13)),
        ]).paddingSymmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  Widget _powerButton(Peer p, IconData icon, String label, String action,
      {bool primary = false, bool danger = false}) {
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
            style: danger
                ? OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD9534F),
                    side: BorderSide(
                        color: const Color(0xFFD9534F).withOpacity(0.4)))
                : null,
            onPressed: onPressed,
            icon: child,
            label: Text(translate(label)));
  }

  Widget _sectionTitle(BuildContext context, String text) => Text(text,
      style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.7)));

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
    String err = 'skip';
    if (action != 'wake') err = await _serverCommand(p.id, action);
    if (err == 'skip') {
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

  /// Lock, restart or shut down through the server with the signed-in account, so no
  /// device password is needed. Returns "" on success, an error, or 'skip' to fall
  /// back to a direct connection (not signed in, no permission, older device).
  Future<String> _serverCommand(String id, String action) async {
    if (!gFFI.userModel.isLogin) return 'skip';
    try {
      final api = '${await bind.mainGetApiServer()}/qc-api/peer-cmd';
      final headers = getHttpHeaders();
      headers['Content-Type'] = 'application/json';
      final resp = await http.post(Uri.parse(api),
          headers: headers, body: jsonEncode({'peer_id': id, 'action': action}));
      final body = jsonDecode(decode_http_response(resp));
      if (resp.statusCode == 409) return 'qc-device-offline';
      if (body is! Map || body['code'] != 0) return 'skip';
      final cid = body['data']['cid'];
      // The device picks the command up with its next heartbeat (every 15 s).
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(seconds: 2));
        final r = await http.get(Uri.parse('$api?cid=$cid'), headers: headers);
        final d = jsonDecode(decode_http_response(r));
        final data = d is Map ? d['data'] : null;
        final status = data is Map ? data['status'] : null;
        if (status == 'ok') return '';
        if (status == 'failed') {
          final msg = '${data!['msg']}';
          return msg.startsWith('unknown action') ? 'skip' : msg;
        }
        if (status == 'expired') return 'qc-cmd-timeout';
        // Restart and shut down act a few seconds after the device acknowledges.
        if (status == 'delivered' && action != 'lock' && i >= 3) return '';
      }
      return 'qc-cmd-timeout';
    } catch (e) {
      debugPrint('peer-cmd: $e');
      return 'skip';
    }
  }

  /// Remark name (alias) for any device; the note is kept in the address book.
  void _editRemark(Peer p, bool canEditAb) {
    final alias = TextEditingController(text: p.alias);
    final note = TextEditingController(text: p.note);
    gFFI.dialogManager.show((setState, close, context) {
      submit() async {
        final newAlias = alias.text.trim();
        final newNote = note.text.trim();
        close();
        final inAb = gFFI.abModel.currentAbPeers.any((e) => e.id == p.id);
        if (!inAb && gFFI.userModel.isLogin && gFFI.abModel.current.canWrite()) {
          // Keep the name in the account so every signed-in computer sees it.
          await gFFI.abModel.addIdToCurrent(
              p.id, newAlias, '', _tag.isEmpty ? [] : [_tag], newNote);
        }
        if (newAlias != p.alias) {
          if (canEditAb) {
            await gFFI.abModel.changeAlias(id: p.id, alias: newAlias);
          }
          await bind.mainSetPeerAlias(id: p.id, alias: newAlias);
          bind.mainLoadRecentPeers();
        }
        if (canEditAb && newNote != p.note) {
          await gFFI.abModel.changeNote(id: p.id, note: newNote);
        }
        showToast(translate('Successful'));
      }

      return CustomAlertDialog(
        title: Text(translate('qc-edit-remark')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(translate('qc-remark-name'),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: alias,
              autofocus: true,
              decoration: InputDecoration(
                  hintText: p.hostname.isNotEmpty ? p.hostname : formatID(p.id)),
            ),
            if (canEditAb) ...[
              const SizedBox(height: 14),
              Text(translate('qc-note'), style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 6),
              TextField(
                controller: note,
                minLines: 2,
                maxLines: 4,
                decoration:
                    InputDecoration(hintText: translate('qc-note-hint')),
              ),
            ],
          ],
        ).paddingOnly(top: 4),
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
