import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/mesh_service.dart';

/// ResQNet — BLE Mesh Scanner Screen
/// Shows all nearby Bluetooth devices with:
///   - ResQNet devices highlighted in blue
///   - Active packet sender highlighted in green (pulsing)
///   - Signal strength bars
///   - Real-time scan updates

class MeshScannerScreen extends StatefulWidget {
  final String activePacketOrigin; // device currently sending us a packet

  const MeshScannerScreen({
    super.key,
    this.activePacketOrigin = '',
  });

  @override
  State<MeshScannerScreen> createState() => _MeshScannerScreenState();
}

class _MeshScannerScreenState extends State<MeshScannerScreen>
    with TickerProviderStateMixin {

  List<MeshDevice> _devices   = [];
  bool             _scanning  = false;
  String           _status    = 'Tap scan to discover nearby devices';
  String           _activeOrigin = '';
  Timer?           _refreshTimer;
  Timer?           _pulseTimer;
  bool             _pulseOn   = false;

  late AnimationController _scanAnim;

  // Saved callbacks — restored on dispose to avoid stacking
  Function(List<MeshDevice>)? _prevDevicesCb;
  Function(String)?           _prevStatusCb;
  Function(MeshPacket)?       _prevPacketCb;

  @override
  void initState() {
    super.initState();
    _activeOrigin = widget.activePacketOrigin;

    _scanAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    // Hook into MeshService callbacks (save originals for dispose)
    _prevDevicesCb = MeshService.onDevicesUpdated;
    _prevStatusCb  = MeshService.onStatusUpdate;
    _prevPacketCb  = MeshService.onPacketReceived;

    MeshService.onDevicesUpdated = (devices) {
      _prevDevicesCb?.call(devices);
      if (!mounted) return;
      setState(() {
        _devices  = devices;
        _scanning = false;
      });
      _scanAnim.stop();
    };

    MeshService.onStatusUpdate = (msg) {
      _prevStatusCb?.call(msg);
      if (!mounted) return;
      setState(() {
        _status   = msg;
        _scanning = MeshService.isScanning;
      });
      if (_scanning) _scanAnim.repeat();
      else           _scanAnim.stop();
    };

    MeshService.onPacketReceived = (packet) {
      _prevPacketCb?.call(packet);
      if (!mounted) return;
      setState(() => _activeOrigin = packet.displayOrigin);
      HapticFeedback.mediumImpact();
    };

    // Pulse timer for active sender highlight
    _pulseTimer = Timer.periodic(
      const Duration(milliseconds: 600), (_) {
        if (mounted) setState(() => _pulseOn = !_pulseOn);
      });

    // Auto-refresh device list every 3s
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3), (_) {
        if (mounted) setState(() {
          _devices  = MeshService.nearbyDevices;
          _scanning = MeshService.isScanning;
        });
      });

    // Load current devices immediately
    setState(() {
      _devices  = MeshService.nearbyDevices;
      _scanning = MeshService.isScanning;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _pulseTimer?.cancel();
    _scanAnim.dispose();
    // Restore original callbacks so home screen keeps working normally
    MeshService.onDevicesUpdated = _prevDevicesCb;
    MeshService.onStatusUpdate   = _prevStatusCb;
    MeshService.onPacketReceived = _prevPacketCb;
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _status   = 'Scanning for nearby devices...';
      _devices  = [];
    });
    _scanAnim.repeat();
    HapticFeedback.lightImpact();
    try {
      if (!MeshService.isActive) {
        await MeshService.startMesh();
      }
    } catch (e) {
      if (mounted) setState(() {
        _scanning = false;
        _status   = 'Scan failed: $e';
      });
      _scanAnim.stop();
    }
  }

  // Signal strength to bars (0-4)
  int _rssiBars(int rssi) {
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    if (rssi >= -90) return 1;
    return 0;
  }

  Color _rssiColor(int rssi) {
    if (rssi >= -65) return const Color(0xFF34C759);
    if (rssi >= -75) return const Color(0xFFFF9500);
    return const Color(0xFFFF3B30);
  }

  String _rssiLabel(int rssi) {
    if (rssi >= -65) return 'Excellent';
    if (rssi >= -75) return 'Good';
    if (rssi >= -85) return 'Fair';
    return 'Weak';
  }

  String _distanceLabel(double dist) {
    if (dist < 1)  return '< 1m';
    if (dist < 5)  return '~${dist.toStringAsFixed(1)}m';
    if (dist < 20) return '~${dist.round()}m';
    return '> 20m';
  }

  @override
  Widget build(BuildContext context) {
    // Sort: active sender first, then ResQNet, then others
    final sorted = [..._devices]..sort((a, b) {
      final aActive = _activeOrigin.isNotEmpty &&
          (a.deviceId.contains(_activeOrigin) ||
           _activeOrigin.contains(a.deviceId.substring(0,
             a.deviceId.length > 8 ? 8 : a.deviceId.length)));
      final bActive = _activeOrigin.isNotEmpty &&
          (b.deviceId.contains(_activeOrigin) ||
           _activeOrigin.contains(b.deviceId.substring(0,
             b.deviceId.length > 8 ? 8 : b.deviceId.length)));
      if (aActive && !bActive) return -1;
      if (!aActive && bActive) return 1;
      if (a.isResQNet && !b.isResQNet) return -1;
      if (!a.isResQNet && b.isResQNet) return 1;
      return b.rssi.compareTo(a.rssi); // stronger signal first
    });

    final resqnetCount = sorted.where((d) => d.isResQNet).length;

    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios,
            color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('BLE Mesh Scanner',
          style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700,
            color: Colors.white)),
        actions: [
          // Scan button
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: _scanning ? null : _startScan,
              child: AnimatedBuilder(
                animation: _scanAnim,
                builder: (_, child) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: _scanning
                        ? const Color(0xFF0A84FF).withOpacity(0.2)
                        : const Color(0xFF0A84FF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _scanning
                          ? const Color(0xFF0A84FF).withOpacity(
                              0.4 + _scanAnim.value * 0.4)
                          : const Color(0xFF0A84FF).withOpacity(0.4))),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_scanning) ...[
                      SizedBox(
                        width: 10, height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: const Color(0xFF0A84FF),
                          value: null,
                        )),
                      const SizedBox(width: 6),
                    ] else
                      const Icon(Icons.radar,
                        color: Color(0xFF0A84FF), size: 13),
                    const SizedBox(width: 5),
                    Text(
                      _scanning ? 'Scanning...' : 'Scan',
                      style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700,
                        color: Color(0xFF0A84FF),
                        fontFamily: 'Courier New')),
                  ]),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(children: [
        // ── Summary bar ──────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F0F0F),
            border: Border(bottom: BorderSide(
              color: const Color(0xFF1E1E1E)))),
          child: Row(children: [
            _summaryChip(
              '${sorted.length}',
              'All Devices',
              const Color(0xFF555555)),
            const SizedBox(width: 10),
            _summaryChip(
              '$resqnetCount',
              'ResQNet',
              const Color(0xFF0A84FF)),
            const SizedBox(width: 10),
            if (_activeOrigin.isNotEmpty)
              _summaryChip(
                '1',
                'Active Sender',
                const Color(0xFF34C759)),
            const Spacer(),
            // Status text
            Text(
              _status.length > 30
                  ? '${_status.substring(0, 30)}...' : _status,
              style: const TextStyle(
                fontSize: 9,
                fontFamily: 'Courier New',
                color: Color(0xFF555555))),
          ]),
        ),

        // ── Legend ───────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 8),
          color: const Color(0xFF0A0A0A),
          child: Row(children: [
            _legendItem(const Color(0xFF34C759), 'Active sender'),
            const SizedBox(width: 16),
            _legendItem(const Color(0xFF0A84FF), 'ResQNet device'),
            const SizedBox(width: 16),
            _legendItem(const Color(0xFF555555), 'Unknown BT device'),
          ]),
        ),

        // ── Device list ───────────────────────────────────────
        Expanded(
          child: sorted.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: sorted.length,
                  itemBuilder: (ctx, i) =>
                    _buildDeviceCard(sorted[i], i)),
        ),
      ]),
    );
  }

  Widget _buildDeviceCard(MeshDevice device, int index) {
    // Determine if this device is the active packet sender
    final isActive = _activeOrigin.isNotEmpty && (
      device.deviceId.contains(_activeOrigin) ||
      (device.deviceId.length >= 8 &&
       _activeOrigin.contains(
         device.deviceId.substring(0, 8))));

    final isResQNet = device.isResQNet;
    final bars      = _rssiBars(device.rssi);
    final sigColor  = _rssiColor(device.rssi);

    // Colors based on device type
    Color borderColor;
    Color bgColor;
    Color labelColor;
    String typeLabel;
    IconData typeIcon;

    if (isActive) {
      borderColor = _pulseOn
          ? const Color(0xFF34C759)
          : const Color(0xFF34C759).withOpacity(0.4);
      bgColor     = const Color(0xFF34C759).withOpacity(0.07);
      labelColor  = const Color(0xFF34C759);
      typeLabel   = '📡 ACTIVE SENDER';
      typeIcon    = Icons.cell_tower;
    } else if (isResQNet) {
      borderColor = const Color(0xFF0A84FF).withOpacity(0.6);
      bgColor     = const Color(0xFF0A84FF).withOpacity(0.06);
      labelColor  = const Color(0xFF0A84FF);
      typeLabel   = '🛡 ResQNet Node';
      typeIcon    = Icons.app_shortcut;
    } else if (device.name.toLowerCase().contains('resqnet') ||
               device.name.toLowerCase().contains('rqn')) {
      // Name-based fallback detection
      borderColor = const Color(0xFF0A84FF).withOpacity(0.4);
      bgColor     = const Color(0xFF0A84FF).withOpacity(0.04);
      labelColor  = const Color(0xFF0A84FF);
      typeLabel   = '🛡 ResQNet (name match)';
      typeIcon    = Icons.app_shortcut;
    } else {
      borderColor = const Color(0xFF1E1E1E);
      bgColor     = const Color(0xFF0F0F0F);
      labelColor  = const Color(0xFF444444);
      typeLabel   = 'Unknown Device';
      typeIcon    = Icons.bluetooth;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: borderColor,
          width: isActive ? 1.5 : 1.0)),
      child: Row(children: [
        // Icon
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: labelColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: labelColor.withOpacity(0.3))),
          child: Center(child: Icon(
            typeIcon, color: labelColor, size: 18))),
        const SizedBox(width: 12),

        // Device info
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Type badge
            Row(children: [
              Text(typeLabel,
                style: TextStyle(
                  fontSize: 9, fontWeight: FontWeight.w700,
                  color: labelColor,
                  fontFamily: 'Courier New',
                  letterSpacing: 0.5)),
              if (isActive) ...[
                const SizedBox(width: 6),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _pulseOn
                        ? const Color(0xFF34C759)
                        : Colors.transparent,
                    border: Border.all(
                      color: const Color(0xFF34C759),
                      width: 1))),
              ],
            ]),
            const SizedBox(height: 4),

            // Device ID
            Text(
              device.name != 'Unknown' && device.name.isNotEmpty
                  ? device.name
                  : device.deviceId,
              style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: Color(0xFFCCCCCC)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),

            // MAC / ID
            if (device.name != 'Unknown' && device.name.isNotEmpty)
              Text(device.deviceId,
                style: const TextStyle(
                  fontFamily: 'Courier New',
                  fontSize: 10, color: Color(0xFF555555)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),

            const SizedBox(height: 5),

            // Distance
            Text(_distanceLabel(device.distance),
              style: TextStyle(
                fontSize: 10, color: sigColor,
                fontWeight: FontWeight.w600)),
          ])),

        // Signal strength
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Bars
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(4, (i) {
                final active = i < bars;
                return Container(
                  width: 5,
                  height: 6.0 + i * 5,
                  margin: const EdgeInsets.only(left: 2),
                  decoration: BoxDecoration(
                    color: active
                        ? sigColor
                        : const Color(0xFF222222),
                    borderRadius: BorderRadius.circular(1.5)));
              })),
            const SizedBox(height: 4),
            Text('${device.rssi} dBm',
              style: const TextStyle(
                fontFamily: 'Courier New',
                fontSize: 10, color: Color(0xFF555555))),
            const SizedBox(height: 2),
            Text(_rssiLabel(device.rssi),
              style: TextStyle(
                fontSize: 9, color: sigColor,
                fontWeight: FontWeight.w600)),
          ]),
      ]),
    );
  }

  Widget _buildEmptyState() => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.bluetooth_searching,
          color: Color(0xFF1E1E1E), size: 64),
        const SizedBox(height: 16),
        const Text('No devices found',
          style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600,
            color: Color(0xFF444444))),
        const SizedBox(height: 8),
        const Text('Tap Scan to search for nearby devices',
          style: TextStyle(
            fontSize: 11, color: Color(0xFF333333),
            fontFamily: 'Courier New')),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: _startScan,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0A84FF).withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFF0A84FF).withOpacity(0.4))),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.radar,
                  color: Color(0xFF0A84FF), size: 16),
                SizedBox(width: 8),
                Text('Start Scanning',
                  style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600,
                    color: Color(0xFF0A84FF))),
              ]))),
      ]));

  Widget _summaryChip(String count, String label, Color color) =>
    Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(count,
          style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w800,
            color: color, fontFamily: 'Courier New')),
        const SizedBox(width: 5),
        Text(label,
          style: TextStyle(
            fontSize: 9, color: color,
            fontWeight: FontWeight.w600)),
      ]));

  Widget _legendItem(Color color, String label) =>
    Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(label,
        style: const TextStyle(
          fontSize: 9, color: Color(0xFF555555),
          fontFamily: 'Courier New')),
    ]);
}