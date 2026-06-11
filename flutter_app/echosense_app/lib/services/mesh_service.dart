import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'database_service.dart';
import 'sms_service.dart';

/// ResQNet — Bluetooth Mesh Service (Fixed)
///
/// Fixes applied:
///   1. broadcastAlert() now ALWAYS restarts advertising immediately
///   2. Scan interval reduced: 4s scan + 6s interval (was 6s+12s)
///   3. Relay phone continues advertising received packets
///   4. _isActive guard fixed so relay mode works independently
///   5. _now() timestamp fixed
class MeshService {
  static const int MAX_HOPS          = 3;
  static const int SCAN_DURATION_SEC = 4;   // reduced from 6
  static const int RESCAN_INTERVAL   = 6;   // reduced from 12
  static const int MANUFACTURER_ID   = 0xFFFF;

  static final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();

  static String? _deviceId;
  static bool    _isScanning         = false;
  static bool    _isActive           = false;
  static int     _relayRotationIndex = 0;
  static Timer?  _scanTimer;
  static Timer?  _beaconTimer;

  static final Map<String, MeshPacket> _receivedPackets = {};
  static final Map<String, MeshPacket> _pendingRelay    = {};
  static final Map<String, MeshDevice> _nearbyDevices   = {};

  static Function(MeshPacket)?       onPacketReceived;
  static Function(List<MeshDevice>)? onDevicesUpdated;
  static Function(String)?           onStatusUpdate;

  // ── Initialise ────────────────────────────────────────────────
  static Future<void> initialise() async {
    _deviceId = await _getOrCreateDeviceId();
    onStatusUpdate?.call('MeshService: Device ID = $_deviceId');
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      onStatusUpdate?.call('MeshService: Bluetooth OFF');
      return;
    }
    onStatusUpdate?.call('MeshService: Initialised ✓');
  }

  static Future<String> _getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? id  = prefs.getString('mesh_device_id');
    if (id == null) {
      final rand = Random();
      id = 'RQN-' + List.generate(4, (_) =>
          rand.nextInt(16).toRadixString(16).toUpperCase()).join();
      await prefs.setString('mesh_device_id', id);
    }
    return id;
  }

  // ── Start mesh (victim mode) ──────────────────────────────────
  static Future<void> startMesh() async {
    if (_isActive) return;
    _isActive = true;
    onStatusUpdate?.call('MeshService: Starting...');
    await initialise();
    _startScanLoop();
    // Don't start advertising yet — wait for broadcastAlert()
    onStatusUpdate?.call('MeshService: Mesh active ✓ — waiting for alert');
  }

  // ── Start relay mode ──────────────────────────────────────────
  static Future<void> startRelayMode({
    Function(String)?     onStatusUpdate,
    Function(MeshPacket)? onPacketRelayed,
  }) async {
    if (_isActive) return;
    _isActive = true;
    MeshService.onStatusUpdate = onStatusUpdate;
    // Merge with existing onPacketReceived callback
    // so home_screen counter AND relay callback both fire
    final existingCb = MeshService.onPacketReceived;
    MeshService.onPacketReceived = (packet) {
      existingCb?.call(packet);    // home_screen counter
      onPacketRelayed?.call(packet); // relay-specific callback
    };
    onStatusUpdate?.call('Relay mode active — scanning...');
    await initialise();
    _startScanLoop();
    onStatusUpdate?.call('Relay mode ready ✓');
  }

  // ── Stop mesh ─────────────────────────────────────────────────
  static Future<void> stopMesh() async {
    _isActive = false;
    _scanTimer?.cancel();
    _beaconTimer?.cancel();
    try {
      await FlutterBluePlus.stopScan();
      await _peripheral.stop();
    } catch (_) {}
    _nearbyDevices.clear();
    _pendingRelay.clear();
    onStatusUpdate?.call('MeshService: Stopped');
  }

  // ── Broadcast alert ───────────────────────────────────────────
  /// FIX: Immediately starts advertising after adding packet.
  /// Previous bug: advertising started before packet existed.
  static Future<void> broadcastAlert({
    required double latitude,
    required double longitude,
    required double confidence,
    required String soundType,
    required int    battery,
  }) async {
    final packet = MeshPacket(
      originId:   _deviceId ?? 'UNK',
      deviceId:   _deviceId ?? 'UNK',
      alertType:  'DISTRESS',
      confidence: confidence,
      latitude:   latitude,
      longitude:  longitude,
      hopCount:   0,
      maxHops:    MAX_HOPS,
      timestamp:  _now(),
      battery:    battery,
      soundType:  soundType,
    );

    // Add to relay queue FIRST
    _receivedPackets[packet.originId] = packet;
    _pendingRelay[packet.originId]    = packet;

    onStatusUpdate?.call(
        'Mesh: Broadcasting alert — ${_pendingRelay.length} packet(s)');

    // FIX: Always restart advertising immediately with the new packet
    // Cancel old timer and start fresh
    _beaconTimer?.cancel();
    if (_isActive) {
      await _advertiseNow(packet);  // advertise immediately
      _startActiveAdvertising();    // then continue periodic advertising
    }
  }

  // ── Advertise a single packet immediately ─────────────────────
  static Future<void> _advertiseNow(MeshPacket packet) async {
    if (_isScanning) {
      onStatusUpdate?.call('Mesh: Waiting for scan to finish...');
      await Future.delayed(const Duration(seconds: 1));
    }
    try {
      final payloadBytes  = packet.toBinaryPayload();
      final advertiseData = AdvertiseData(
        includeDeviceName: false,
        includePowerLevel: false,
        manufacturerId:    MANUFACTURER_ID,
        manufacturerData:  payloadBytes,
      );
      await _peripheral.stop();
      await _peripheral.start(advertiseData: advertiseData);
      onStatusUpdate?.call('Mesh: Advertising immediately ✓ origin=${packet.originId}');
    } catch (e) {
      onStatusUpdate?.call('Mesh: Advertise error — $e');
    }
  }

  // ── Periodic advertising ──────────────────────────────────────
  static void _startActiveAdvertising() {
    if (!_isActive) return;
    _beaconTimer?.cancel();
    _beaconTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_isActive || _pendingRelay.isEmpty) {
        timer.cancel();
        try { await _peripheral.stop(); } catch (_) {}
        return;
      }
      if (_isScanning) return;

      final packets = _pendingRelay.values.toList();
      if (_relayRotationIndex >= packets.length) _relayRotationIndex = 0;
      final packet = packets[_relayRotationIndex++];

      try {
        final payloadBytes  = packet.toBinaryPayload();
        final advertiseData = AdvertiseData(
          includeDeviceName: false,
          includePowerLevel: false,
          manufacturerId:    MANUFACTURER_ID,
          manufacturerData:  payloadBytes,
        );
        await _peripheral.stop();
        await _peripheral.start(advertiseData: advertiseData);
        onStatusUpdate?.call('Mesh: Advertising ${packet.originId} hop=${packet.hopCount}');
      } catch (e) {
        onStatusUpdate?.call('Mesh advertise error: $e');
      }
    });
  }

  // ── Scan loop ─────────────────────────────────────────────────
  static void _startScanLoop() {
    _scanTimer?.cancel();
    _scanCycle();
    _scanTimer = Timer.periodic(
        Duration(seconds: RESCAN_INTERVAL), (_) => _scanCycle());
  }

  static Future<void> _scanCycle() async {
    if (!_isActive || _isScanning) return;
    _isScanning = true;
    try {
      onStatusUpdate?.call('Mesh: Scanning...');
      if (await _peripheral.isAdvertising) await _peripheral.stop();

      await FlutterBluePlus.startScan(
          timeout: Duration(seconds: SCAN_DURATION_SEC));

      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) _processScanResult(r);
      });

      await Future.delayed(Duration(seconds: SCAN_DURATION_SEC));
      await FlutterBluePlus.stopScan();
      await sub.cancel();

      onStatusUpdate?.call(
          'Mesh: Scan done — ${_nearbyDevices.length} nodes');
      onDevicesUpdated?.call(_nearbyDevices.values.toList());

    } catch (e) {
      onStatusUpdate?.call('Mesh scan error: $e');
    } finally {
      _isScanning = false;
      // Resume advertising after scan
      if (_pendingRelay.isNotEmpty) _startActiveAdvertising();
    }
  }

  // ── Process scan result ───────────────────────────────────────
  static void _processScanResult(ScanResult result) {
    final device   = result.device;
    final rssi     = result.rssi;
    final mfData   = result.advertisementData.manufacturerData;
    final targetId = device.remoteId.toString();

    String localName = 'Unknown';
    try {
      localName = device.platformName.isNotEmpty
          ? device.platformName : 'Unknown';
    } catch (_) {}

    final meshDevice = MeshDevice(
      deviceId:  targetId,
      name:      localName,
      rssi:      rssi,
      distance:  _rssiToDistance(rssi),
      isResQNet: false,
      lastSeen:  DateTime.now(),
    );

    if (mfData.containsKey(MANUFACTURER_ID)) {
      meshDevice.isResQNet = true;
      try {
        final packet = MeshPacket.fromBinaryPayload(
            mfData[MANUFACTURER_ID]!);

        // Accept packet if:
        // - Not already seen from this origin
        // - Has hops remaining
        // - Not from ourselves
        if (!_receivedPackets.containsKey(packet.originId) &&
            packet.hopCount < packet.maxHops &&
            packet.originId != _deviceId) {

          _receivedPackets[packet.originId] = packet;
          onPacketReceived?.call(packet);
          onStatusUpdate?.call(
              'Mesh: ✓ Received from ${packet.originId} '
              '(hop ${packet.hopCount}/${packet.maxHops})');

          // Store for relay with incremented hop count
          final relayPacket = packet.copyWithNextHop(_deviceId ?? 'RELAY');
          _pendingRelay[packet.originId] = relayPacket;

          // Forward to dashboard if we have internet
          _forwardRelayPacket(packet);

          // Start advertising the relayed packet immediately
          _advertiseNow(relayPacket);
        }
      } catch (e) {
        onStatusUpdate?.call('Mesh: Packet parse error — $e');
      }
    }
    _nearbyDevices[targetId] = meshDevice;
  }

  // ── DTN forward ───────────────────────────────────────────────
  static Future<void> _forwardRelayPacket(MeshPacket packet) async {
    String dashboardIp = '';
    try { dashboardIp = await SmsService.getDashboardIp(); } catch (_) {}

    bool posted = false;
    if (dashboardIp.isNotEmpty) {
      posted = await _postToDashboard(packet, dashboardIp);
    }

    try {
      await DatabaseService.saveAlert(AlertRecord(
        soundType:  packet.soundType,
        confidence: packet.confidence,
        latitude:   packet.latitude,
        longitude:  packet.longitude,
        smsSent:    false,
        dashSent:   posted,
      ));
    } catch (e) {
      onStatusUpdate?.call('Mesh: DB error — $e');
    }
  }

  // ── Post to dashboard ─────────────────────────────────────────
  static Future<bool> _postToDashboard(MeshPacket packet, String ip) async {
    try {
      final res = await http.post(
        Uri.parse('http://$ip:5000/alert'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'latitude':   packet.latitude,
          'longitude':  packet.longitude,
          'confidence': packet.confidence,
          'sound_type': '${packet.soundType} [Mesh hop ${packet.hopCount}]',
          'battery':    packet.battery,
          'timestamp':  packet.timestamp,
          'mesh_relay': true,
          'hop_count':  packet.hopCount,
          'origin_id':  packet.originId,
        }),
      ).timeout(const Duration(seconds: 5));
      final ok = res.statusCode == 200 || res.statusCode == 201;
      onStatusUpdate?.call('Mesh: Dashboard ${ok ? "✓" : "failed"}');
      return ok;
    } catch (e) {
      onStatusUpdate?.call('Mesh: Dashboard unreachable');
      return false;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────
  static double _rssiToDistance(int rssi) {
    const txPower = -59.0; const n = 2.5;
    return pow(10, (txPower - rssi) / (10 * n)).toDouble();
  }

  static String _now() {
    final d = DateTime.now();
    return '${d.year}-${_p(d.month)}-${_p(d.day)} '
           '${_p(d.hour)}:${_p(d.minute)}:${_p(d.second)}';
  }
  static String _p(int n) => n.toString().padLeft(2, '0');

  static String get deviceId      => _deviceId ?? 'NOT_INIT';
  static bool   get isActive      => _isActive;
  static bool   get isScanning    => _isScanning;
  static List<MeshDevice> get nearbyDevices   => _nearbyDevices.values.toList();
  static List<MeshPacket> get receivedPackets => _receivedPackets.values.toList();
}

// ── Data models ───────────────────────────────────────────────

class MeshPacket {
  final String originId, deviceId, alertType, timestamp, soundType;
  final double confidence, latitude, longitude;
  final int    hopCount, maxHops, battery;

  MeshPacket({
    required this.originId,   required this.deviceId,
    required this.alertType,  required this.confidence,
    required this.latitude,   required this.longitude,
    required this.hopCount,   required this.maxHops,
    required this.timestamp,  required this.battery,
    required this.soundType,
  });

  Uint8List toBinaryPayload() {
    final buf = ByteData(22);
    buf.setUint16(0,  originId.replaceFirst('RQN-', '').hashCode & 0xFFFF, Endian.big);
    buf.setUint16(2,  deviceId.replaceFirst('RQN-', '').hashCode & 0xFFFF, Endian.big);
    buf.setUint8(4,   (confidence * 100).round().clamp(0, 100));
    buf.setFloat32(5, latitude,  Endian.big);
    buf.setFloat32(9, longitude, Endian.big);
    buf.setUint8(13,  hopCount);
    buf.setUint8(14,  maxHops);
    buf.setUint8(15,  battery.clamp(0, 100));
    final sb = utf8.encode(soundType);
    for (int i = 0; i < 6; i++)
      buf.setUint8(16 + i, i < sb.length ? sb[i] : 0x20);
    return buf.buffer.asUint8List();
  }

  factory MeshPacket.fromBinaryPayload(List<int> bytes) {
    final d  = ByteData.sublistView(Uint8List.fromList(bytes));
    final sc = List.generate(6, (i) => d.getUint8(16 + i));
    final st = utf8.decode(sc).trim();
    return MeshPacket(
      originId:   'RQN-${d.getUint16(0, Endian.big).toRadixString(16).toUpperCase()}',
      deviceId:   'RQN-${d.getUint16(2, Endian.big).toRadixString(16).toUpperCase()}',
      alertType:  'DISTRESS',
      confidence: d.getUint8(4).toDouble() / 100.0,
      latitude:   d.getFloat32(5, Endian.big),
      longitude:  d.getFloat32(9, Endian.big),
      hopCount:   d.getUint8(13),
      maxHops:    d.getUint8(14),
      battery:    d.getUint8(15),
      timestamp:  DateTime.now().toString().substring(0, 19),
      soundType:  st.isEmpty ? 'Distress' : st,
    );
  }

  MeshPacket copyWithNextHop(String newDeviceId) => MeshPacket(
    originId:   originId,   deviceId:   newDeviceId,
    alertType:  alertType,  confidence: confidence,
    latitude:   latitude,   longitude:  longitude,
    hopCount:   hopCount + 1, maxHops:  maxHops,
    timestamp:  timestamp,  battery:    battery,
    soundType:  soundType,
  );
}

class MeshDevice {
  final String   deviceId, name;
  final int      rssi;
  final double   distance;
  bool           isResQNet;
  final DateTime lastSeen;

  MeshDevice({
    required this.deviceId,  required this.name,
    required this.rssi,      required this.distance,
    required this.isResQNet, required this.lastSeen,
  });
}