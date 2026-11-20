// Qianchen Desk: device panel on the main window, modelled on ToDesk.
// Left: my devices (address book) and recent connections. Right: the selected
// device with its connection and power actions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

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

/// Qianchen Desk: this computer's heartbeat reaches the server even when UDP registration
/// does not (a VPN), so connections still work; the status bar shows that instead of
/// "not ready".
final qcHeartbeatOnline = false.obs;

String _qcGb(double b) => (b / 1024 / 1024 / 1024).toStringAsFixed(1);

/// Qianchen Desk: colour for a 0..1 load: teal, then amber, then red.
Color _qcLevelColor(double v) => v >= 0.85
    ? const Color(0xFFE5484D)
    : v >= 0.65
        ? const Color(0xFFF2A33A)
        : MyTheme.accent;

/// 270° arc gauge with a gradient, glow and ticks; the needle value animates.
class QcGauge extends StatelessWidget {
  final double size;
  final double value; // 0..1
  final String label;
  final String text;
  final String unit;
  final String sub;
  final Color? color;
  const QcGauge(
      {Key? key,
      required this.size,
      required this.value,
      required this.label,
      required this.text,
      this.unit = '',
      this.sub = '',
      this.color})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = Theme.of(context).textTheme.titleLarge?.color ?? Colors.black;
    final muted = Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        final c = color ?? _qcLevelColor(v);
        return SizedBox(
          width: size,
          height: size,
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _QcGaugePainter(
                    v,
                    c,
                    dark ? Colors.white.withOpacity(0.08) : c.withOpacity(0.10),
                    muted.withOpacity(0.35),
                    size * 0.085),
              ),
            ),
            Container(
              width: size * 0.66,
              height: size * 0.5,
              padding: EdgeInsets.only(bottom: size * 0.04),
              child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(text,
                        style: TextStyle(
                            fontSize: size * (text.length > 5 ? 0.13 : 0.22),
                            height: 1.0,
                            fontWeight: FontWeight.w700,
                            color: fg,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                    if (unit.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(left: 1, bottom: size * 0.015),
                        child: Text(unit,
                            style: TextStyle(
                                fontSize: size * 0.10,
                                height: 1.0,
                                fontWeight: FontWeight.w600,
                                color: muted)),
                      ),
                  ],
                ),
                if (sub.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: size * 0.04),
                    child: Text(sub,
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: size * 0.085, height: 1.0, color: muted)),
                  ),
              ]),
              ),
            ),
            Positioned(
              bottom: size * 0.02,
              child: Text(label,
                  style: TextStyle(
                      fontSize: size * 0.095,
                      height: 1.0,
                      fontWeight: FontWeight.w600,
                      color: c)),
            ),
          ]),
        );
      },
    );
  }
}

class _QcGaugePainter extends CustomPainter {
  final double v;
  final Color color;
  final Color track;
  final Color tick;
  final double stroke;
  _QcGaugePainter(this.v, this.color, this.track, this.tick, this.stroke);

  static const _start = 0.75 * pi;
  static const _sweep = 1.5 * pi;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2 - stroke / 2 - 1;
    final rect = Rect.fromCircle(center: center, radius: r);
    canvas.drawArc(
        rect,
        _start,
        _sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = track);
    // Ticks inside the track, every 10 %.
    final tp = Paint()
      ..color = tick
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i <= 10; i++) {
      final a = _start + _sweep * i / 10;
      final r1 = r - stroke / 2 - 3;
      final r2 = r1 - (i % 5 == 0 ? stroke * 0.8 : stroke * 0.45);
      canvas.drawLine(center + Offset(cos(a), sin(a)) * r1,
          center + Offset(cos(a), sin(a)) * r2, tp);
    }
    if (v <= 0.002) return;
    final sweep = _sweep * v;
    final shader = SweepGradient(
      colors: [color.withOpacity(0.35), color],
      stops: const [0.0, 1.0],
      endAngle: max(sweep, 0.01),
      transform: const GradientRotation(_start),
    ).createShader(rect);
    // Soft glow under the value arc.
    canvas.drawArc(
        rect,
        _start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = color.withOpacity(0.35)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.6));
    canvas.drawArc(
        rect,
        _start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..shader = shader);
    // Bright dot at the tip.
    final a = _start + sweep;
    canvas.drawCircle(center + Offset(cos(a), sin(a)) * r, stroke * 0.32,
        Paint()..color = Colors.white.withOpacity(0.9));
  }

  @override
  bool shouldRepaint(_QcGaugePainter old) =>
      old.v != v || old.color != color || old.track != track;
}

String _qcShortRate(double b) {
  if (b < 1024) return '${b.toStringAsFixed(0)}B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(b < 10240 ? 1 : 0)}K';
  return '${(b / 1024 / 1024).toStringAsFixed(1)}M';
}

/// Qianchen Desk: CPU / memory / network / temperature gauges for a stats map from
/// qianchen_stats.rs (another computer's heartbeat, or this one directly).
/// [columns] 4 = one row (device panel), 2 = a 2×2 grid (left pane).
Widget qcStatsGauges(BuildContext context, Map stats,
    {int columns = 4, double maxSize = 132}) {
  double n(String k) => (stats[k] as num?)?.toDouble() ?? 0;
  final cpu = n('cpu').clamp(0, 100).toDouble();
  final memTotal = n('mem_total');
  final mem =
      memTotal > 0 ? (n('mem') / memTotal * 100).clamp(0, 100).toDouble() : 0.0;
  final rx = n('rx'), tx = n('tx');
  // Network on a log scale: 1 KB/s empty, 100 MB/s full.
  final total = rx + tx;
  final netV = total <= 1024
      ? 0.0
      : ((log(total) / ln10 - 3) / 5).clamp(0.0, 1.0).toDouble();
  final temp = (stats['temp'] as num?)?.toDouble();
  return LayoutBuilder(builder: (context, box) {
    const gap = 10.0;
    final size = min(maxSize, (box.maxWidth - gap * (columns - 1)) / columns);
    final gauges = <Widget>[
      QcGauge(
          size: size,
          value: cpu / 100,
          label: 'CPU',
          text: cpu.toStringAsFixed(0),
          unit: '%'),
      QcGauge(
          size: size,
          value: mem / 100,
          label: translate('qc-stat-mem'),
          text: mem.toStringAsFixed(0),
          unit: '%',
          sub: memTotal > 0
              ? '${_qcGb(n('mem'))}/${_qcGb(memTotal)}G'
              : ''),
      QcGauge(
          size: size,
          value: netV,
          label: translate('qc-stat-net'),
          text: '↓${_qcShortRate(rx)}',
          sub: '↑${_qcShortRate(tx)}',
          color: const Color(0xFF3B82F6)),
      QcGauge(
          size: size,
          value: temp == null ? 0 : (temp - 20) / 80,
          label: translate('qc-stat-temp'),
          text: temp == null ? '--' : temp.toStringAsFixed(0),
          unit: temp == null ? '' : '°C',
          sub: temp == null ? translate('qc-stat-na') : ''),
    ];
    final rows = <Widget>[];
    for (var i = 0; i < gauges.length; i += columns) {
      final row = gauges.sublist(i, min(i + columns, gauges.length));
      rows.add(Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: row));
    }
    return Column(
        children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const SizedBox(height: gap),
        rows[i],
      ]
    ]);
  });
}

/// Qianchen Desk: live stats of this computer for the left pane of the main window.
class QcLocalStatsCard extends StatefulWidget {
  const QcLocalStatsCard({Key? key}) : super(key: key);

  @override
  State<QcLocalStatsCard> createState() => _QcLocalStatsCardState();
}

class _QcLocalStatsCardState extends State<QcLocalStatsCard> {
  Map? _stats;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final s = jsonDecode(await bind.mainGetCommon(key: 'qc-sys-stats'));
      if (s is Map && mounted) setState(() => _stats = s);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_stats == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MyTheme.accent.withOpacity(0.12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(translate('qc-local-status'),
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).textTheme.bodySmall?.color)),
        const SizedBox(height: 2),
        qcStatsGauges(context, _stats!, columns: 2, maxSize: 100),
      ]),
    );
  }
}

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
  // LAN addresses that actually answered on the direct port (21118) from here.
  final Map<String, bool> _lanOk = {};
  String _myPublicIp = '';
  // Thumbnail view: on/off (remembered) and the latest JPEG per device.
  bool _grid = bind.getLocalFlutterOption(k: 'qc-grid-view') == 'Y';
  final Map<String, ({int t, Uint8List jpg})> _thumbs = {};
  Timer? _thumbTimer;
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
      if (++_tick % 2 == 0) _fetchIps();
      if (_tick % 10 == 0) _syncAccount();
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      _queryOnlines();
      _fetchIps();
    });
    if (_grid) _startThumbs();
  }

  @override
  void dispose() {
    platformFFI.unregisterEventHandler('callback_query_onlines', _handlerName);
    _timer?.cancel();
    _thumbTimer?.cancel();
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
    final selfId = trimID(gFFI.serverModel.serverId.text);
    if (selfId.isNotEmpty) ids.add(selfId);
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
        qcHeartbeatOnline.value = _ips[selfId]?['online'] == true;
        await _probeLan();
        // One write at a time: each one loads and stores the whole peer file.
        for (final e in _ips.entries) {
          for (final kv in [
            ['qc-lan-ips', e.value['lan']?.toString() ?? ''],
            ['qc-signed-pk', e.value['spk']?.toString() ?? ''],
          ]) {
            if (kv[1].isNotEmpty &&
                bind.mainGetPeerOptionSync(id: e.key, key: kv[0]) != kv[1]) {
              await bind.mainSetPeerOption(id: e.key, key: kv[0], value: kv[1]);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('peer-ips: $e');
    }
    if (mounted) setState(() {});
  }

  /// Same subnet is not proof of being on the same network (another home may also use
  /// 192.168.0.x), and a VPN makes public IPs differ; so knock on the direct port.
  Future<void> _probeLan() async {
    final futures = <Future>[];
    for (final e in _ips.entries) {
      final ips = (e.value['lan']?.toString() ?? '')
          .split(',')
          .where((ip) => _myLanIps.any((m) => _sameSubnet(m, ip)))
          .toList();
      if (ips.isEmpty) {
        _lanOk.remove(e.key);
        continue;
      }
      futures.add(() async {
        var ok = false;
        for (final ip in ips) {
          try {
            final s = await Socket.connect(ip, 21118,
                timeout: const Duration(milliseconds: 500));
            s.destroy();
            ok = true;
            break;
          } catch (_) {}
        }
        _lanOk[e.key] = ok;
      }());
    }
    await Future.wait(futures);
  }

  static bool _sameSubnet(String a, String b) {
    final x = a.split('.'), y = b.split('.');
    return x.length == 4 && y.length == 4 && x[0] == y[0] && x[1] == y[1] && x[2] == y[2];
  }

  String _publicIp(Peer p) => _ips[p.id]?['ip']?.toString() ?? '';

  /// "3 分钟前在线" style text for an offline device, from the server's last heartbeat.
  String _lastSeen(Peer p) {
    final last = (_ips[p.id]?['last'] as num?)?.toInt() ?? 0;
    if (last <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(last * 1000);
    final d = DateTime.now().difference(t);
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    final String when;
    if (d.inMinutes < 1) {
      when = translate('qc-just-now');
    } else if (d.inMinutes < 60) {
      when = '${d.inMinutes} ${translate('qc-minutes-ago')}';
    } else if (d.inHours < 24 && t.day == DateTime.now().day) {
      when = '${d.inHours} ${translate('qc-hours-ago')}';
    } else if (d.inDays < 2 &&
        DateTime.now().subtract(const Duration(days: 1)).day == t.day) {
      when = '${translate('qc-yesterday')} $hm';
    } else {
      when = '${t.month}-${t.day} $hm';
    }
    return '$when${translate('qc-was-online')}';
  }

  /// Our endpoints on the server (/qc-api/...), signed in as the current account.
  Future<dynamic> _qcApi(String path, {Map<String, dynamic>? body}) async {
    final api = await bind.mainGetApiServer();
    final headers = getHttpHeaders();
    headers['Content-Type'] = 'application/json';
    final uri = Uri.parse('$api/qc-api/$path');
    final resp = body == null
        ? await http.get(uri, headers: headers)
        : await http.post(uri, headers: headers, body: jsonEncode(body));
    final r = jsonDecode(decode_http_response(resp));
    if (r is Map && r['code'] == 0) return r['data'];
    throw (r is Map ? r['message'] : null) ?? 'HTTP ${resp.statusCode}';
  }

  void _setGrid(bool on) {
    setState(() => _grid = on);
    bind.setLocalFlutterOption(k: 'qc-grid-view', v: on ? 'Y' : '');
    _thumbTimer?.cancel();
    if (on) _startThumbs();
  }

  void _startThumbs() {
    _fetchThumbs();
    _thumbTimer = Timer.periodic(const Duration(seconds: 10), (_) => _fetchThumbs());
  }

  /// Online devices send a fresh screenshot within ~20 s of being asked.
  Future<void> _fetchThumbs() async {
    if (!_grid || !gFFI.userModel.isLogin) return;
    final ids = _myDevices().where(_isOnline).map((e) => e.id).toList();
    if (ids.isEmpty) return;
    try {
      final data = await _qcApi('thumbs?ids=${ids.join(',')}');
      if (data is! Map || !mounted) return;
      var changed = false;
      data.forEach((id, v) {
        final t = (v['t'] as num?)?.toInt() ?? 0;
        if (_thumbs[id]?.t == t) return;
        _thumbs[id] = (t: t, jpg: base64Decode(v['jpg'] as String));
        changed = true;
      });
      if (changed) setState(() {});
    } catch (e) {
      debugPrint('thumbs: $e');
    }
  }

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
    final probed = _lanOk[p.id];
    if (probed != null) return probed;
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
        if (_grid && loggedIn) return _buildGrid(context, mine, tags);
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
        _buildToolbar(mine),
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

  Widget _buildToolbar(List<Peer> mine) {
    return Row(children: [
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
          IconButton(
            tooltip: translate(_grid ? 'qc-list-view' : 'qc-grid-view'),
            icon: Icon(
                _grid ? Icons.view_agenda_outlined : Icons.grid_view_rounded,
                size: 20),
            onPressed: () => _setGrid(!_grid),
          ),
          _moreMenu(mine),
        ]).paddingOnly(left: 4, right: 4, top: 10, bottom: 6);
  }

  /// Thumbnail view: a card per device with its latest screen.
  Widget _buildGrid(BuildContext context, List<Peer> mine, List<String> tags) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: tags.isEmpty ? const SizedBox.shrink() : _buildTags(context, tags)),
        SizedBox(width: 420, child: _buildToolbar(mine)),
      ]),
      Expanded(
        child: mine.isEmpty
            ? _hint(context, translate('qc-no-devices-tip'))
            : GridView.extent(
                maxCrossAxisExtent: 300,
                childAspectRatio: 1.25,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                children: mine.map((p) => _buildCard(context, p)).toList(),
              ),
      ),
    ]);
  }

  Widget _buildCard(BuildContext context, Peer p) {
    final online = _isOnline(p);
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final thumb = _thumbs[p.id];
    final hover = false.obs;
    Widget screen;
    if (online && thumb != null) {
      screen = Image.memory(thumb.jpg,
          fit: BoxFit.cover, gaplessPlayback: true, width: double.infinity);
    } else {
      screen = Container(
        color: online
            ? MyTheme.accent.withOpacity(0.08)
            : Colors.grey.withOpacity(0.12),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(online ? Icons.hourglass_top_rounded : Icons.power_settings_new_rounded,
              size: 28, color: online ? MyTheme.accent : Colors.grey),
          const SizedBox(height: 6),
          Text(online ? translate('qc-thumb-loading') : _lastSeen(p),
              style: TextStyle(fontSize: 12, color: muted)),
        ]),
      );
    }
    Widget action(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: translate(tip),
          child: Material(
            color: Colors.black.withOpacity(0.55),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Icon(icon, size: 18, color: Colors.white).paddingAll(8),
            ),
          ),
        );
    return MouseRegion(
      onEnter: (_) => hover.value = true,
      onExit: (_) => hover.value = false,
      child: Material(
        color: Theme.of(context).cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Theme.of(context).dividerColor.withOpacity(0.6))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => connect(context, p.id),
          onSecondaryTapDown: (d) {
            _select(p.id);
            _showItemMenu(context, p, d.globalPosition);
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(fit: StackFit.expand, children: [
                screen,
                Obx(() => AnimatedOpacity(
                      opacity: hover.value ? 1 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          action(Icons.drive_file_move_rounded, 'File transfer',
                              () => connect(context, p.id, isFileTransfer: true)),
                          const SizedBox(width: 6),
                          action(Icons.info_outline_rounded, 'qc-show-detail', () {
                            _select(p.id);
                            _setGrid(false);
                          }),
                        ]).paddingAll(8),
                      ),
                    )),
              ]),
            ),
            Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: online ? const Color(0xFF1E9E63) : Colors.grey),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_name(p),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              Text(formatID(p.id), style: TextStyle(fontSize: 11, color: muted)),
            ]).paddingSymmetric(horizontal: 12, vertical: 10),
          ]),
        ),
      ),
    );
  }

  Widget _moreMenu(List<Peer> mine) => PopupMenuButton<String>(
        tooltip: translate('More'),
        icon: const Icon(Icons.more_vert_rounded, size: 20),
        onSelected: (v) {
          switch (v) {
            case 'shutdown':
            case 'wake':
              _batch(mine, shutdown: v == 'shutdown');
              break;
            case 'schedule':
              _editSchedules();
              break;
            case 'alerts':
              _editAlerts();
              break;
            case 'classic':
              widget.onShowClassic();
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
              value: 'shutdown',
              enabled: mine.isNotEmpty,
              child: Text(translate('qc-batch-shutdown'))),
          PopupMenuItem(
              value: 'wake',
              enabled: mine.isNotEmpty,
              child: Text(translate('qc-batch-wake'))),
          const PopupMenuDivider(),
          PopupMenuItem(
              value: 'schedule',
              enabled: gFFI.userModel.isLogin,
              child: Text(translate('qc-schedule'))),
          PopupMenuItem(
              value: 'alerts',
              enabled: gFFI.userModel.isLogin,
              child: Text(translate('qc-alerts'))),
          const PopupMenuDivider(),
          PopupMenuItem(
              value: 'classic', child: Text(translate('Classic view'))),
        ],
      );

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
    final isLan = online && _isLan(p);
    final seen = online ? '' : _lastSeen(p);
    final ip = seen.isNotEmpty ? seen : (isLan ? _lanIp(p) : _publicIp(p));
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
    final pubHint = [
      if (region.isNotEmpty) region,
      if (_ips[p.id]?['vpn'] == true) translate('qc-via-vpn'),
    ].join(' · ');
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
          // Narrow window: the button goes under the name so the name keeps one line.
          child: LayoutBuilder(builder: (context, c) {
            final narrow = c.maxWidth < 460;
            final info = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Tooltip(
                      message: _name(p),
                      waitDuration: const Duration(milliseconds: 600),
                      child: Text(_name(p),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 18,
                              height: 1.25,
                              fontWeight: FontWeight.w700)),
                    ),
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
                  _chip(
                      online
                          ? translate('Online')
                          : [translate('Offline'), _lastSeen(p)]
                              .where((e) => e.isNotEmpty)
                              .join(' · '),
                      online ? const Color(0xFF1E9E63) : Colors.grey),
                  if (isLan)
                    _chip(translate('qc-lan'), MyTheme.accent,
                        icon: Icons.lan_rounded),
                  if (inAb) _chip(translate('My devices'), const Color(0xFF5B6B9A)),
                ]),
              ],
            );
            final button = ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.desktop_windows_rounded, size: 18),
              label: Text(translate('Remote control'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () => connect(context, p.id),
            );
            final top = Row(children: [
              _avatar(context, p, 54, online),
              const SizedBox(width: 14),
              Expanded(child: info),
              if (!narrow) ...[const SizedBox(width: 12), button],
            ]);
            if (!narrow) return top;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              top,
              const SizedBox(height: 12),
              button,
            ]);
          }),
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
                  copy: pub,
                  hint: pubHint.isEmpty ? null : pubHint),
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
        if (online) ...[
          const SizedBox(height: 22),
          _sectionTitle(context, translate('qc-run-status')),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Theme.of(context).hoverColor.withOpacity(0.45),
              borderRadius: BorderRadius.circular(14),
            ),
            child: _ips[p.id]?['stats'] is Map
                ? qcStatsGauges(context, _ips[p.id]!['stats'] as Map)
                : Text(translate('qc-stats-wait'),
                        style: TextStyle(fontSize: 12, color: muted))
                    .paddingSymmetric(vertical: 6),
          ),
        ],
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

  /// Scheduled power on / off per tag ("*" = every device). Runs on the server.
  Future<void> _editSchedules() async {
    Map data;
    try {
      data = (await _qcApi('schedule')) as Map? ?? {};
    } catch (e) {
      showToast('$e');
      return;
    }
    final groups = ['*', ...gFFI.abModel.currentAbTags.toList()];
    final cfg = <String, Map<String, dynamic>>{
      for (final g in groups)
        g: {
          'enabled': data[g]?['enabled'] == true,
          'on': data[g]?['on'] ?? '',
          'off': data[g]?['off'] ?? '',
          'days': List<int>.from(data[g]?['days'] ?? [1, 2, 3, 4, 5, 6, 7]),
        }
    };
    final times = [
      '',
      for (var h = 0; h < 24; h++)
        for (final m in ['00', '30']) '${h.toString().padLeft(2, '0')}:$m'
    ];
    const dayNames = ['一', '二', '三', '四', '五', '六', '日'];
    gFFI.dialogManager.show((setState, close, context) {
      Widget timeBox(String g, String key) => DropdownButton<String>(
            value: cfg[g]![key] as String,
            isDense: true,
            items: times
                .map((t) => DropdownMenuItem(
                    value: t,
                    child: Text(t.isEmpty ? translate('qc-not-set') : t,
                        style: const TextStyle(fontSize: 13))))
                .toList(),
            onChanged: (v) => setState(() => cfg[g]![key] = v ?? ''),
          );
      Widget row(String g) {
        final c = cfg[g]!;
        final days = c['days'] as List<int>;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(4, 4, 10, 8),
          decoration: BoxDecoration(
            color: Theme.of(context).hoverColor.withOpacity(0.4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Checkbox(
                  value: c['enabled'] as bool,
                  onChanged: (v) => setState(() => c['enabled'] = v == true)),
              Text(g == '*' ? translate('qc-all-devices') : g,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${translate('qc-power-on-at')} ', style: const TextStyle(fontSize: 13)),
              timeBox(g, 'on'),
              const SizedBox(width: 14),
              Text('${translate('qc-power-off-at')} ', style: const TextStyle(fontSize: 13)),
              timeBox(g, 'off'),
            ]),
            Wrap(spacing: 4, children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text('周${dayNames[d - 1]}', style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  selected: days.contains(d),
                  selectedColor: MyTheme.accent.withOpacity(0.18),
                  showCheckmark: false,
                  onSelected: (on) => setState(() => on ? days.add(d) : days.remove(d)),
                ),
            ]).paddingOnly(left: 12),
          ]),
        );
      }

      submit() async {
        try {
          await _qcApi('schedule', body: {'schedules': cfg});
          close();
          showToast(translate('Successful'));
        } catch (e) {
          showToast('$e');
        }
      }

      return CustomAlertDialog(
        title: Text(translate('qc-schedule')),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(translate('qc-schedule-tip'),
                style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color)),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(child: Column(children: groups.map(row).toList())),
            ),
          ]),
        ),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton('OK', onPressed: submit),
        ],
        onCancel: close,
        onSubmit: submit,
      );
    });
  }

  /// WeChat alerts through PushPlus or Server酱; sent by the server.
  Future<void> _editAlerts() async {
    Map data;
    try {
      data = (await _qcApi('alerts')) as Map? ?? {};
    } catch (e) {
      showToast('$e');
      return;
    }
    var provider = data['provider'] == 'serverchan' ? 'serverchan' : 'pushplus';
    final token = TextEditingController(text: data['token']?.toString() ?? '');
    final opts = {
      'offline': data.isEmpty || data['offline'] == true,
      'cpu': data.isEmpty || data['cpu'] == true,
      'disk': data.isEmpty || data['disk'] == true,
    };
    Map<String, dynamic> body() =>
        {'provider': provider, 'token': token.text.trim(), ...opts};
    gFFI.dialogManager.show((setState, close, context) {
      final muted = Theme.of(context).textTheme.bodySmall?.color;
      submit() async {
        try {
          await _qcApi('alerts', body: body());
          close();
          showToast(translate('Successful'));
        } catch (e) {
          showToast('$e');
        }
      }

      Widget check(String key, String label) => CheckboxListTile(
            value: opts[key],
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(translate(label), style: const TextStyle(fontSize: 13)),
            onChanged: (v) => setState(() => opts[key] = v == true),
          );
      return CustomAlertDialog(
        title: Text(translate('qc-alerts')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              ChoiceChip(
                  label: const Text('PushPlus'),
                  selected: provider == 'pushplus',
                  onSelected: (_) => setState(() => provider = 'pushplus')),
              const SizedBox(width: 8),
              ChoiceChip(
                  label: const Text('Server酱'),
                  selected: provider == 'serverchan',
                  onSelected: (_) => setState(() => provider = 'serverchan')),
            ]),
            const SizedBox(height: 6),
            Text(translate(provider == 'pushplus' ? 'qc-pushplus-tip' : 'qc-serverchan-tip'),
                style: TextStyle(fontSize: 12, color: muted)),
            const SizedBox(height: 8),
            TextField(
              controller: token,
              decoration: InputDecoration(
                  isDense: true,
                  hintText: translate(provider == 'pushplus' ? 'qc-pushplus-token' : 'qc-serverchan-key')),
            ),
            const SizedBox(height: 10),
            check('offline', 'qc-alert-offline'),
            check('cpu', 'qc-alert-cpu'),
            check('disk', 'qc-alert-disk'),
          ]),
        ),
        actions: [
          dialogButton('qc-send-test', isOutline: true, onPressed: () async {
            try {
              await _qcApi('alerts/test', body: body());
              showToast(translate('qc-test-sent'));
            } catch (e) {
              showToast('$e');
            }
          }),
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton('OK', onPressed: submit),
        ],
        onCancel: close,
        onSubmit: submit,
      );
    });
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
