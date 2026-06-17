import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Fallback distress-signal transport using classic Bluetooth name
/// broadcasting + discovery.
///
/// WHY THIS EXISTS
/// ────────────────
/// BLE peripheral/advertising mode (BluetoothLeAdvertiser) is not reliably
/// supported across all Android hardware. We confirmed independently, via
/// nRF Connect bypassing our own code entirely, that some phones report a
/// successful advertise start while the radio never actually transmits the
/// custom data. Classic Bluetooth name broadcasting + discovery runs on a
/// completely different, much older Android API surface that is
/// implemented far more uniformly across budget chipsets. This class is
/// a second, independent channel so the app still works on hardware where
/// BLE advertising silently fails.
///
/// SCOPE
/// ─────
/// This class is transport-only — it knows nothing about MeshPacket. It
/// moves raw bytes in and out of a Bluetooth-name-safe string. The caller
/// (MeshService) owns packet semantics, dedup, and relay decisions.
///
/// KNOWN TRADE-OFF (read this before demo day)
/// ─────────────────────────────────────────────
/// Classic discoverable mode requires the device to respond to inquiry
/// scans, which Android only allows after the user grants a one-time
/// system permission dialog (ACTION_REQUEST_DISCOVERABLE). There is no
/// way for a normal app to skip this — it's a deliberate Android privacy
/// control, not a bug. Call [startBroadcasting] once when monitoring
/// begins (calm moment, user is present) rather than only at the instant
/// SOS fires, so the dialog is handled before any emergency.
class ClassicBeaconService {
  static const MethodChannel _channel =
      MethodChannel('resqnet/classic_beacon');
  static const EventChannel _events =
      EventChannel('resqnet/classic_beacon_events');

  // Short prefix so we can recognise our own names among random nearby
  // devices (headphones, cars, other phones) during discovery.
  static const String _prefix = 'R!';

  static String? _originalName;
  static bool _isBroadcasting = false;
  static Timer? _rediscoverableTimer;
  static StreamSubscription? _eventSub;
  static bool _isScanning = false;

  // ── rate-limited logging ────────────────────────────────────────────
  // Classic discovery cycles every ~12s — logging every cycle floods the
  // terminal over a multi-minute test. We log a summary on a timer instead.
  static int _cyclesSinceLog = 0;
  static int _hitsSinceLog = 0;
  static DateTime _lastLog = DateTime.now();
  static const Duration _logEvery = Duration(seconds: 20);

  static void _logSummaryIfDue({bool force = false}) {
    final due = DateTime.now().difference(_lastLog) >= _logEvery;
    if (!due && !force) return;
    print('ClassicBeacon: $_cyclesSinceLog discovery cycles, '
        '$_hitsSinceLog ResQNet name(s) seen (last ${_logEvery.inSeconds}s)');
    _cyclesSinceLog = 0;
    _hitsSinceLog = 0;
    _lastLog = DateTime.now();
  }

  // ── encode / decode raw bytes <-> Bluetooth-name-safe string ────────

  /// Encodes [bytes] into a short name-safe string using base64url
  /// (alphabet A-Z a-z 0-9 - _, no '+' or '/'). Padding is stripped to
  /// save characters — Bluetooth names are tight real estate.
  static String encodeBytes(Uint8List bytes) {
    final b64 = base64Url.encode(bytes).replaceAll('=', '');
    return '$_prefix$b64';
  }

  /// Returns the decoded bytes if [name] is a valid ResQNet-encoded name,
  /// or null if it doesn't match our prefix or fails to decode (e.g. some
  /// other device's name that happens to start the same way).
  static Uint8List? decodeName(String name) {
    if (!name.startsWith(_prefix)) return null;
    var b64 = name.substring(_prefix.length);
    final pad = (4 - b64.length % 4) % 4;
    b64 += '=' * pad;
    try {
      return base64Url.decode(b64);
    } catch (_) {
      return null;
    }
  }

  // ── broadcasting (victim / relay side) ──────────────────────────────

  /// Starts broadcasting [bytes] via device name + discoverable mode.
  /// Re-requests discoverable mode periodically since Android caps each
  /// request to a limited duration — see class doc for the permission
  /// dialog trade-off.
  static Future<bool> startBroadcasting(Uint8List bytes) async {
    final name = encodeBytes(bytes);
    try {
      final result =
          await _channel.invokeMethod('startBeacon', {'name': name});
      if (!_isBroadcasting) {
        _originalName = (result as Map?)?['originalName'] as String?;
      }
      _isBroadcasting = true;
      print('ClassicBeacon: broadcasting '
          '(${bytes.length}B -> ${name.length}-char name)');

      _rediscoverableTimer ??=
          Timer.periodic(const Duration(seconds: 90), (_) {
        _channel.invokeMethod('requestDiscoverable').catchError((e) {
          print('ClassicBeacon: re-discoverable request failed — $e');
        });
      });
      return true;
    } catch (e) {
      print('ClassicBeacon: startBeacon failed — $e');
      return false;
    }
  }

  static Future<void> stopBroadcasting() async {
    _rediscoverableTimer?.cancel();
    _rediscoverableTimer = null;
    if (!_isBroadcasting) return;
    try {
      await _channel
          .invokeMethod('stopBeacon', {'originalName': _originalName});
    } catch (e) {
      print('ClassicBeacon: stopBeacon failed — $e');
    }
    _isBroadcasting = false;
    print('ClassicBeacon: stopped broadcasting');
  }

  // ── scanning (relay side) ───────────────────────────────────────────

  /// Starts continuous classic discovery. [onPacketBytes] fires once per
  /// ResQNet-encoded name found, with decoded bytes, MAC, and RSSI (RSSI
  /// may be null — classic discovery reports it less consistently than
  /// BLE scanning).
  static Future<void> startScanning(
    void Function(Uint8List bytes, String mac, int? rssi) onPacketBytes,
  ) async {
    if (_isScanning) return;
    _isScanning = true;
    await _eventSub?.cancel();
    _eventSub = _events.receiveBroadcastStream().listen((event) {
      final map = event as Map;
      switch (map['type']) {
        case 'deviceFound':
          final name = map['name'] as String? ?? '';
          final mac = map['mac'] as String? ?? '';
          final rssi = map['rssi'] as int?;
          final bytes = decodeName(name);
          if (bytes != null) {
            _hitsSinceLog++;
            onPacketBytes(bytes, mac, rssi);
          }
          break;
        case 'discoveryFinished':
          _cyclesSinceLog++;
          _logSummaryIfDue();
          if (_isScanning) {
            _channel.invokeMethod('startDiscovery').catchError((_) {});
          }
          break;
      }
    }, onError: (e) => print('ClassicBeacon: event stream error — $e'));

    try {
      await _channel.invokeMethod('startDiscovery');
      print('ClassicBeacon: scanning started');
    } catch (e) {
      print('ClassicBeacon: startDiscovery failed — $e');
      _isScanning = false;
    }
  }

  static Future<void> stopScanning() async {
    _isScanning = false;
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _channel.invokeMethod('stopDiscovery');
    } catch (_) {}
    _logSummaryIfDue(force: true);
    print('ClassicBeacon: scanning stopped');
  }
}
