import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/mesh_service.dart';

class BluetoothMeshScreen extends StatefulWidget {
  const BluetoothMeshScreen({super.key});
  @override
  State<BluetoothMeshScreen> createState() => _BluetoothMeshScreenState();
}

class _BluetoothMeshScreenState extends State<BluetoothMeshScreen>
    with TickerProviderStateMixin {

  // ── Animation controllers ──────────────────────────────────
  late AnimationController _radarController;
  late AnimationController _pulseController;
  late AnimationController _alertController;

  // ── State ──────────────────────────────────────────────────
  bool   _meshActive    = false;
  bool   _isScanning    = false;
  String _deviceId      = '...';
  String _statusMessage = 'Mesh network inactive';
  String _role          = 'IDLE';

  List<MeshDevice>  _devices         = [];
  List<MeshPacket>  _receivedPackets = [];
  List<String>      _activityLog     = [];
  MeshPacket?       _latestAlert;

  // ── Lifecycle ──────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _alertController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _setupCallbacks();
    _loadDeviceId();
  }

  @override
  void dispose() {
    _radarController.dispose();
    _pulseController.dispose();
    _alertController.dispose();
    super.dispose();
  }

  void _setupCallbacks() {
    MeshService.onStatusUpdate = (msg) {
      if (!mounted) return;
      setState(() {
        _statusMessage = msg;
        _addLog(msg);
        _isScanning = MeshService.isScanning;
      });
    };

    MeshService.onDevicesUpdated = (devices) {
      if (!mounted) return;
      setState(() => _devices = devices);
    };

    MeshService.onPacketReceived = (packet) {
      if (!mounted) return;
      setState(() {
        _latestAlert = packet;
        _receivedPackets = MeshService.receivedPackets;
        _role = packet.hopCount == 0 ? 'RELAY' : 'RESCUER';
      });
      _alertController.forward(from: 0);
      HapticFeedback.heavyImpact();
    };
  }

  Future<void> _loadDeviceId() async {
    await MeshService.initialise();
    if (mounted) setState(() => _deviceId = MeshService.deviceId);
  }

  void _addLog(String msg) {
    final time = TimeOfDay.now().format(context);
    _activityLog.insert(0, '[$time] $msg');
    if (_activityLog.length > 30) _activityLog.removeLast();
  }

  Future<void> _toggleMesh() async {
    HapticFeedback.mediumImpact();
    if (_meshActive) {
      await MeshService.stopMesh();
      setState(() {
        _meshActive = false;
        _role       = 'IDLE';
        _devices    = [];
      });
    } else {
      await MeshService.startMesh();
      setState(() {
        _meshActive = true;
        _role       = 'RELAY';
      });
    }
  }

  Future<void> _sendTestAlert() async {
    HapticFeedback.heavyImpact();
    await MeshService.broadcastAlert(
      latitude:   -36.8866,
      longitude:  174.7470,
      confidence: 0.87,
      soundType:  'Test Distress',
      battery:    85,
    );
    setState(() => _role = 'VICTIM');
    _addLog('Test alert broadcast via BLE');
  }

  // ── Build ──────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Stack(children: [
        // Grid background
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),

        SafeArea(child: Column(children: [
          _buildHeader(),
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              _buildDeviceIdCard(),
              const SizedBox(height: 12),
              _buildRoleCard(),
              const SizedBox(height: 12),
              _buildRadar(),
              const SizedBox(height: 12),
              if (_latestAlert != null) _buildAlertCard(),
              if (_latestAlert != null) const SizedBox(height: 12),
              _buildDeviceList(),
              const SizedBox(height: 12),
              _buildActivityLog(),
              const SizedBox(height: 12),
              _buildControlButtons(),
              const SizedBox(height: 24),
            ]),
          )),
        ])),
      ]),
    );
  }

  // ── Header ────────────────────────────────────────────────
  Widget _buildHeader() => Container(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFF1A1A1A)))),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: const Color(0xFF0A84FF).withOpacity(0.15),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFF0A84FF).withOpacity(0.4))),
        child: const Icon(Icons.bluetooth, color: Color(0xFF0A84FF), size: 16)),
      const SizedBox(width: 10),
      const Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Bluetooth Mesh', style: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        Text('DTN Store-and-Forward Network',
          style: TextStyle(fontSize: 9, color: Color(0xFF555555),
            letterSpacing: 0.05)),
      ])),
      // Status indicator
      AnimatedBuilder(
        animation: _pulseController,
        builder: (_, __) => Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _meshActive
                ? Color.lerp(const Color(0xFF34C759),
                    const Color(0xFF34C759).withOpacity(0.3),
                    _pulseController.value)!
                : const Color(0xFF333333))),
      ),
      const SizedBox(width: 6),
      Text(_meshActive ? 'ACTIVE' : 'INACTIVE',
        style: TextStyle(
          fontFamily: 'Courier New', fontSize: 9,
          color: _meshActive
              ? const Color(0xFF34C759)
              : const Color(0xFF555555),
          letterSpacing: 0.08)),
    ]),
  );

  // ── Device ID card ────────────────────────────────────────
  Widget _buildDeviceIdCard() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF0F0F0F),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF1A1A1A))),
    child: Row(children: [
      const Icon(Icons.fingerprint, color: Color(0xFF0A84FF), size: 16),
      const SizedBox(width: 8),
      const Text('Device ID ', style: TextStyle(
        fontSize: 11, color: Color(0xFF555555))),
      Text(_deviceId, style: const TextStyle(
        fontFamily: 'Courier New', fontSize: 12,
        fontWeight: FontWeight.w700, color: Color(0xFF0A84FF))),
      const Spacer(),
      Text('Max ${MeshService.MAX_HOPS} hops',
        style: const TextStyle(
          fontFamily: 'Courier New', fontSize: 9,
          color: Color(0xFF555555))),
    ]),
  );

  // ── Role card ─────────────────────────────────────────────
  Widget _buildRoleCard() {
    final roleData = {
      'IDLE':    [const Color(0xFF555555), Icons.radio_button_unchecked,   'Mesh not active'],
      'VICTIM':  [const Color(0xFFFF3B30), Icons.warning_amber_rounded,    'Broadcasting distress alert'],
      'RELAY':   [const Color(0xFFFF9500), Icons.swap_horiz_rounded,       'Scanning and relaying alerts'],
      'RESCUER': [const Color(0xFF34C759), Icons.emergency_rounded,        'Received alert — posting to dashboard'],
    };

    final data  = roleData[_role] ?? roleData['IDLE']!;
    final color = data[0] as Color;
    final icon  = data[1] as IconData;
    final desc  = data[2] as String;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3))),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('ROLE: ', style: TextStyle(
              fontSize: 10, color: color.withOpacity(0.7),
              fontFamily: 'Courier New')),
            Text(_role, style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: color,
              fontFamily: 'Courier New')),
          ]),
          Text(desc, style: const TextStyle(
            fontSize: 10, color: Color(0xFF888888))),
        ])),
        // Relay counter
        if (_receivedPackets.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withOpacity(0.4))),
            child: Text('${_receivedPackets.length} relayed',
              style: TextStyle(
                fontFamily: 'Courier New', fontSize: 9,
                fontWeight: FontWeight.w700, color: color))),
      ]),
    );
  }

  // ── Radar ─────────────────────────────────────────────────
  Widget _buildRadar() => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF040A08),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF0A3020))),
    padding: const EdgeInsets.all(8),
    child: Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          const Icon(Icons.radar, color: Color(0xFF34C759), size: 13),
          const SizedBox(width: 6),
          const Text('BLE RADAR', style: TextStyle(
            fontFamily: 'Courier New', fontSize: 10,
            color: Color(0xFF34C759), letterSpacing: 0.1)),
          const Spacer(),
          Text('${_devices.length} devices',
            style: const TextStyle(
              fontFamily: 'Courier New', fontSize: 9,
              color: Color(0xFF336644))),
          const SizedBox(width: 8),
          if (_isScanning) ...[
            SizedBox(
              width: 10, height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: const Color(0xFF34C759),
              )),
            const SizedBox(width: 4),
            const Text('SCANNING', style: TextStyle(
              fontFamily: 'Courier New', fontSize: 8,
              color: Color(0xFF34C759))),
          ],
        ]),
      ),
      AspectRatio(
        aspectRatio: 1,
        child: AnimatedBuilder(
          animation: _radarController,
          builder: (_, __) => CustomPaint(
            painter: _RadarPainter(
              sweepAngle:  _radarController.value * 2 * pi,
              devices:     _devices,
              isActive:    _meshActive,
              hasAlert:    _latestAlert != null,
            ),
          ),
        ),
      ),
    ]),
  );

  // ── Alert card ────────────────────────────────────────────
  Widget _buildAlertCard() {
    final p = _latestAlert!;
    return AnimatedBuilder(
      animation: _alertController,
      builder: (_, __) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFF3B30).withOpacity(0.08 +
              0.04 * sin(_alertController.value * pi)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFFF3B30).withOpacity(0.5))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.warning_amber_rounded,
              color: Color(0xFFFF3B30), size: 16),
            const SizedBox(width: 8),
            const Text('MESH ALERT RECEIVED',
              style: TextStyle(
                fontFamily: 'Courier New', fontSize: 11,
                fontWeight: FontWeight.w700, color: Color(0xFFFF3B30),
                letterSpacing: 0.06)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFFF3B30).withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFFFF3B30).withOpacity(0.5))),
              child: Text('HOP ${p.hopCount}/${p.maxHops}',
                style: const TextStyle(
                  fontFamily: 'Courier New', fontSize: 9,
                  fontWeight: FontWeight.w700, color: Color(0xFFFF3B30)))),
          ]),
          const SizedBox(height: 10),
          _alertRow('Sound',      p.soundType),
          _alertRow('Confidence', '${(p.confidence * 100).toStringAsFixed(0)}%'),
          _alertRow('Origin',     p.originId),
          _alertRow('GPS',
            '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}'),
          _alertRow('Time',       p.timestamp),
        ]),
      ),
    );
  }

  Widget _alertRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      SizedBox(
        width: 80,
        child: Text('$label:', style: const TextStyle(
          fontSize: 10, color: Color(0xFF888888)))),
      Text(value, style: const TextStyle(
        fontFamily: 'Courier New', fontSize: 10,
        color: Colors.white, fontWeight: FontWeight.w500)),
    ]),
  );

  // ── Device list ───────────────────────────────────────────
  Widget _buildDeviceList() {
    if (_devices.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF0F0F0F),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF1A1A1A))),
        child: const Center(child: Text(
          'No nearby devices detected\nStart mesh and scan to discover nodes',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Color(0xFF555555),
            height: 1.6))));
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1A1A1A))),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(children: [
            const Icon(Icons.devices, color: Color(0xFF555555), size: 12),
            const SizedBox(width: 6),
            const Text('NEARBY DEVICES', style: TextStyle(
              fontFamily: 'Courier New', fontSize: 9,
              color: Color(0xFF555555), letterSpacing: 0.08)),
            const Spacer(),
            Text('${_devices.length} found',
              style: const TextStyle(
                fontFamily: 'Courier New', fontSize: 9,
                color: Color(0xFF555555))),
          ])),
        ..._devices.take(8).map((d) => _buildDeviceRow(d)),
      ]),
    );
  }

  Widget _buildDeviceRow(MeshDevice d) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Color(0xFF141414)))),
    child: Row(children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(
          color: d.isResQNet
              ? const Color(0xFF34C759).withOpacity(0.12)
              : const Color(0xFF0A84FF).withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: d.isResQNet
                ? const Color(0xFF34C759).withOpacity(0.3)
                : const Color(0xFF1A1A1A))),
        child: Icon(
          d.isResQNet ? Icons.shield_outlined : Icons.bluetooth,
          color: d.isResQNet
              ? const Color(0xFF34C759)
              : const Color(0xFF555555),
          size: 13)),
      const SizedBox(width: 10),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(d.isResQNet ? d.name : 'Generic BLE Device',
          style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w500,
            color: d.isResQNet ? Colors.white : const Color(0xFF888888))),
        Text(d.deviceId.substring(0, min(17, d.deviceId.length)),
          style: const TextStyle(
            fontFamily: 'Courier New', fontSize: 8,
            color: Color(0xFF555555))),
      ])),
      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${d.rssi} dBm', style: const TextStyle(
          fontFamily: 'Courier New', fontSize: 9,
          color: Color(0xFF888888))),
        Text('~${d.distance.toStringAsFixed(0)}m',
          style: TextStyle(
            fontFamily: 'Courier New', fontSize: 9,
            color: _distanceColor(d.distance))),
      ]),
    ]),
  );

  Color _distanceColor(double d) {
    if (d < 10)  return const Color(0xFF34C759);
    if (d < 30)  return const Color(0xFFFF9500);
    if (d < 100) return const Color(0xFFFF3B30);
    return const Color(0xFF555555);
  }

  // ── Activity log ──────────────────────────────────────────
  Widget _buildActivityLog() => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF050505),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF1A1A1A))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: Row(children: [
          const Icon(Icons.terminal, color: Color(0xFF555555), size: 12),
          const SizedBox(width: 6),
          const Text('MESH LOG', style: TextStyle(
            fontFamily: 'Courier New', fontSize: 9,
            color: Color(0xFF555555), letterSpacing: 0.08)),
        ])),
      Container(
        height: 160,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        child: _activityLog.isEmpty
            ? const Center(child: Text('No activity yet',
                style: TextStyle(fontSize: 10, color: Color(0xFF333333))))
            : ListView.builder(
                itemCount: _activityLog.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1.5),
                  child: Text(_activityLog[i],
                    style: TextStyle(
                      fontFamily: 'Courier New', fontSize: 9,
                      color: _logColor(_activityLog[i]))))),
      ),
    ]),
  );

  Color _logColor(String msg) {
    if (msg.contains('ERROR') || msg.contains('failed'))
      return const Color(0xFFFF3B30);
    if (msg.contains('✓') || msg.contains('Received'))
      return const Color(0xFF34C759);
    if (msg.contains('Relay') || msg.contains('broadcast'))
      return const Color(0xFFFF9500);
    if (msg.contains('Scanning'))
      return const Color(0xFF0A84FF);
    return const Color(0xFF555555);
  }

  // ── Control buttons ───────────────────────────────────────
  Widget _buildControlButtons() => Column(children: [
    // Main toggle
    GestureDetector(
      onTap: _toggleMesh,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: _meshActive
              ? const Color(0xFFFF3B30).withOpacity(0.12)
              : const Color(0xFF0A84FF).withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _meshActive
                ? const Color(0xFFFF3B30).withOpacity(0.5)
                : const Color(0xFF0A84FF).withOpacity(0.5))),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(
            _meshActive ? Icons.stop_circle_outlined : Icons.play_circle_outlined,
            color: _meshActive
                ? const Color(0xFFFF3B30)
                : const Color(0xFF0A84FF),
            size: 18),
          const SizedBox(width: 8),
          Text(
            _meshActive ? 'Stop Mesh Network' : 'Start Mesh Network',
            style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: _meshActive
                  ? const Color(0xFFFF3B30)
                  : const Color(0xFF0A84FF))),
        ]),
      ),
    ),
    const SizedBox(height: 8),

    // Test alert button
    if (_meshActive)
      GestureDetector(
        onTap: _sendTestAlert,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFFF9500).withOpacity(0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFFFF9500).withOpacity(0.4))),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.broadcast_on_personal,
              color: Color(0xFFFF9500), size: 16),
            SizedBox(width: 8),
            Text('Broadcast Test Alert',
              style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: Color(0xFFFF9500))),
          ]),
        ),
      ),

    const SizedBox(height: 12),

    // Info box
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1A1A1A))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('HOW IT WORKS', style: TextStyle(
          fontFamily: 'Courier New', fontSize: 9,
          color: Color(0xFF555555), letterSpacing: 0.08)),
        const SizedBox(height: 8),
        _infoRow('📱 Phone 1', 'CNN detects distress → broadcasts BLE alert'),
        _infoRow('📱 Phone 2', 'Receives alert → stores → re-broadcasts'),
        _infoRow('📱 Phone 3', 'Receives → posts to dashboard via WiFi'),
        _infoRow('📡 Range',   '~100m per hop × 3 hops = ~300m coverage'),
        _infoRow('⏱ Latency', '15-45 seconds end-to-end'),
      ]),
    ),
  ]);

  Widget _infoRow(String label, String desc) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2.5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 80,
        child: Text(label, style: const TextStyle(
          fontSize: 9, color: Color(0xFF888888)))),
      Expanded(child: Text(desc, style: const TextStyle(
        fontSize: 9, color: Color(0xFF555555)))),
    ]),
  );
}

// ── Radar painter ─────────────────────────────────────────────
class _RadarPainter extends CustomPainter {
  final double       sweepAngle;
  final List<MeshDevice> devices;
  final bool         isActive;
  final bool         hasAlert;

  _RadarPainter({
    required this.sweepAngle,
    required this.devices,
    required this.isActive,
    required this.hasAlert,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;
    final r  = min(cx, cy) - 4;

    // Background
    canvas.drawCircle(
      Offset(cx, cy), r,
      Paint()..color = const Color(0xFF010A05));

    // Concentric rings
    final ringPaint = Paint()
      ..color  = const Color(0xFF0A2A15)
      ..style  = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(Offset(cx, cy), r * i / 4, ringPaint);
    }

    // Cross hairs
    final linePaint = Paint()
      ..color       = const Color(0xFF0A2A15)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(cx, cy - r), Offset(cx, cy + r), linePaint);
    canvas.drawLine(Offset(cx - r, cy), Offset(cx + r, cy), linePaint);

    if (!isActive) {
      // Inactive — show greyed radar
      final textPainter = TextPainter(
        text: const TextSpan(
          text: 'INACTIVE',
          style: TextStyle(
            fontFamily: 'Courier New', fontSize: 12,
            color: Color(0xFF333333), letterSpacing: 0.1)),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(cx - textPainter.width / 2, cy - textPainter.height / 2));
      return;
    }

    // Sweep gradient
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: sweepAngle - 1.0,
        endAngle:   sweepAngle,
        colors: [
          Colors.transparent,
          const Color(0xFF34C759).withOpacity(0.5),
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(cx, cy), r, sweepPaint);

    // Sweep line
    final sweepLinePaint = Paint()
      ..color       = const Color(0xFF34C759)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + r * cos(sweepAngle), cy + r * sin(sweepAngle)),
      sweepLinePaint);

    // Draw devices as dots
    for (int i = 0; i < devices.length && i < 12; i++) {
      final d    = devices[i];
      final dist = d.distance.clamp(1.0, 100.0);
      final rad  = (dist / 100) * r;
      final ang  = (i * 2 * pi / max(devices.length, 1));
      final dx   = cx + rad * cos(ang);
      final dy   = cy + rad * sin(ang);

      // Glow effect for ResQNet devices
      if (d.isResQNet) {
        canvas.drawCircle(
          Offset(dx, dy), 8,
          Paint()..color = const Color(0xFF34C759).withOpacity(0.15));
      }

      canvas.drawCircle(
        Offset(dx, dy),
        d.isResQNet ? 5.0 : 3.0,
        Paint()..color = d.isResQNet
            ? const Color(0xFF34C759)
            : const Color(0xFF0A84FF).withOpacity(0.6));

      // Label ResQNet devices
      if (d.isResQNet) {
        final tp = TextPainter(
          text: TextSpan(
            text: d.name.length > 6 ? d.name.substring(0, 6) : d.name,
            style: const TextStyle(
              fontFamily: 'Courier New', fontSize: 7,
              color: Color(0xFF34C759))),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(dx + 6, dy - 4));
      }
    }

    // Center dot (this device)
    canvas.drawCircle(
      Offset(cx, cy), 6,
      Paint()..color = hasAlert
          ? const Color(0xFFFF3B30)
          : const Color(0xFF34C759));

    canvas.drawCircle(
      Offset(cx, cy), 3,
      Paint()..color = Colors.white);

    // Range labels
    final rangePaint = TextPainter(textDirection: TextDirection.ltr);
    for (final pair in [
      [r * 0.25, '25m'],
      [r * 0.5,  '50m'],
      [r * 0.75, '75m'],
      [r,        '100m'],
    ]) {
      rangePaint.text = TextSpan(
        text: pair[1] as String,
        style: const TextStyle(
          fontFamily: 'Courier New', fontSize: 7,
          color: Color(0xFF1A3A20)));
      rangePaint.layout();
      rangePaint.paint(
        canvas,
        Offset(cx + (pair[0] as double) - rangePaint.width / 2,
               cy - rangePaint.height - 2));
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.sweepAngle != sweepAngle ||
      old.devices.length != devices.length ||
      old.isActive != isActive ||
      old.hasAlert != hasAlert;
}

// ── Grid painter ──────────────────────────────────────────────
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color       = const Color(0x06FFFFFF)
      ..strokeWidth = 0.5;
    const s = 40.0;
    for (double x = 0; x <= size.width;  x += s)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y <= size.height; y += s)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}
