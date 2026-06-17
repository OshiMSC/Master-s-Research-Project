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
import 'classic_beacon_service.dart';

/// ResQNet BLE Mesh Service — v6 Final
///
/// Architecture:
///   Victim phone  → advertises SOS continuously, no scanning during alert
///   Relay phone   → scans continuously, briefly advertises when relaying
///
/// BLE packet: manufacturer data only (0x1234 + 20-byte payload)
///
/// Payload layout (19 bytes — fits comfortably in 31-byte BLE limit):
///   0-1:  originId   uint16  ← victim's permanent numeric ID
///   2-3:  relayId    uint16  ← current relay's ID (0 = victim itself)
///   4:    seqNum     uint8   ← packet sequence (dedup: originId+seqNum)
///   5:    ttl        uint8   ← hops remaining (start=5, stop at 0)
///   6:    confidence uint8   ← 0–100
///   7-10: latitude   float32
///   11-14:longitude  float32
///   15:   battery    uint8
///   16:   hopCount   uint8
///   17:   soundCode  uint8   ← 'S'=SOS 'C'=CNN 'B'=Beacon
///   18:   0xAA       uint8   ← end marker for validation
///   = 19 bytes ✓

class MeshService {

  // ── Constants ──────────────────────────────────────────────────
  static const int    MANUFACTURER_ID = 0x1234;
  static const int    NETWORK_ID      = 0xBEEF; // Fix 3: reject non-ResQNet packets
  // localName removed — rely on mfData[0x1234]+networkId instead
  static const int    DEFAULT_TTL     = 5;
  static const int    MAX_HOPS        = DEFAULT_TTL; // alias for UI references
  static const String PREFS_ID_KEY    = 'resqnet_numeric_id_v4';
  static const int    PAYLOAD_BYTES   = 20;      // 3+4+20=27 bytes (no localName needed)
  static const int    DEVICE_EXPIRY_S = 60;

  // FIX: stop retrying BLE advertising forever once it's clearly not
  // going to work on this device's hardware/chipset. See the
  // _doAdvertise() failure-tracking fields below for the full
  // rationale. Without this, the watchdog in broadcastAlert() retries
  // every 5s indefinitely — harmless to correctness (SMS/Dashboard/
  // Telegram/Classic Bluetooth already carried the alert), but noisy
  // in logs and a needless drain on battery/CPU during an actual
  // emergency, especially on hardware confirmed (via manifest check +
  // confirmed-granted runtime permissions + non-standard error code
  // analysis) to lack support for the underlying startAdvertisingSet()
  // extended-advertising API rather than suffering a transient glitch.
  static const int ADVERTISE_FAILURE_GIVEUP_THRESHOLD = 5;

  // FIX: a victim phone that ONLY advertises (the original design) can
  // never receive another nearby victim's packet, even if that second
  // phone is sitting right next to it — because BLE hardware on most
  // phones can't advertise and scan simultaneously, the original code
  // simply stopped scanning entirely for the whole duration of an
  // alert. That trades away the self-healing, multi-hop relay behavior
  // that's the actual point of a mesh: two victims near each other
  // could otherwise relay for one another even with no third "relay
  // mode" bystander phone nearby. The fix is to alternate: spend most
  // of the time advertising (still the victim's primary job), but
  // briefly pause every SCAN_BURST_INTERVAL_S to scan for
  // SCAN_BURST_DURATION_S, then resume advertising. Any packet caught
  // during a burst goes through the exact same _handlePacket()
  // pipeline as relay mode — dedup, forwarding, relaying — with no
  // special-casing needed.
  static const int SCAN_BURST_INTERVAL_S  = 6; // how often to pause-and-listen
  static const int SCAN_BURST_DURATION_S  = 2; // how long each listen window lasts

  // ── Singleton peripheral ────────────────────────────────────────
  static final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();

  // ── Identity ────────────────────────────────────────────────────
  static int?    _numericId;    // permanent uint16, never changes
  static String? _deviceId;    // "RQN-XXXX" display string

  // ── Mode ────────────────────────────────────────────────────────
  static bool    _isActive        = false;
  static bool    _isVictimMode    = false; // true = advertising SOS
  static bool    _isScanning      = false;
  static bool    _scanLoopActive    = false; // Fix 3: loop guard
  static bool    _relayAdvertising  = false; // prevent overlapping relay ads

  // ── BLE advertising health tracking (NEW) ────────────────────────
  // Counts CONSECUTIVE advertising failures. Reset to 0 on any success.
  // Once this hits ADVERTISE_FAILURE_GIVEUP_THRESHOLD, the watchdog
  // stops retrying and _bleAdvertisingUnsupported is set so the UI/log
  // can communicate this clearly instead of silently retrying forever.
  static int     _consecutiveAdvertiseFailures = 0;
  static bool    _bleAdvertisingUnsupported = false;

  // ── Timers ──────────────────────────────────────────────────────
  static Timer?  _advertiseTimer;
  static Timer?  _cleanupTimer;
  static Timer?  _scanBurstTimer;
  static bool    _scanBurstInProgress = false;
  static StreamSubscription? _scanSub;

  // ── Packet tracking ─────────────────────────────────────────────
  static int _seqCounter = 0;
  // Fix 6: Map<key, timestamp> — expire after 10 minutes not just count-based
  static final Map<String, DateTime>   _seenKeys     = {};
  static final Map<String, MeshPacket> _pendingRelay = {};
  // Fix 4: track lastSeen for expiry
  static final Map<String, MeshDevice> _nearbyDevices = {};
  // Collects non-ResQNet manufacturer IDs seen between debug summaries
  static final Set<int> _seenOtherMfgIds = {};

  // ── Rate-limited logging ────────────────────────────────────────
  // Several states (advertising heartbeat, scan-cycle results) used to
  // print on every single tick, flooding the terminal over a multi-minute
  // test. This logs at most once per [every] per [key], regardless of how
  // often it's called — pass force:true for events that always matter
  // (state changes, errors, first detection of a packet).
  static final Map<String, DateTime> _lastLogAt = {};
  static bool _throttled(String key, {Duration every = const Duration(seconds: 30)}) {
    final now = DateTime.now();
    final last = _lastLogAt[key];
    if (last != null && now.difference(last) < every) return true; // skip
    _lastLogAt[key] = now;
    return false; // not throttled — go ahead and log
  }

  // ── Callbacks ────────────────────────────────────────────────────
  static Function(MeshPacket)?       onPacketReceived;
  static Function(List<MeshDevice>)? onDevicesUpdated;
  static Function(String)?           onStatusUpdate;

  // ═══════════════════════════════════════════════════════════════
  // PUBLIC API
  // ═══════════════════════════════════════════════════════════════

  /// Called once when app starts or relay button pressed
  static Future<void> startMesh() async {
    if (_isActive) return;
    _isActive = true;
    await _init();
    _startCleanupTimer();     // Fix 4: expire old devices
    _beginScan();             // relay-side: always scanning (BLE)
    unawaited(ClassicBeaconService.startScanning(_onClassicPacketBytes));
    onStatusUpdate?.call('Mesh ready [$_deviceId]');
    print('MeshService: startMesh() ✓ id=$_deviceId numeric=$_numericId');
  }

  /// Relay mode — same as startMesh but labels relay
  static Future<void> startRelayMode({
    Function(String)?     onStatusUpdate,
    Function(MeshPacket)? onPacketRelayed,
  }) async {
    if (_isActive) { await stopMesh(); await Future.delayed(const Duration(milliseconds: 400)); }
    MeshService.onStatusUpdate = onStatusUpdate;
    final prev = MeshService.onPacketReceived;
    MeshService.onPacketReceived = (p) { prev?.call(p); onPacketRelayed?.call(p); };
    _isActive = true;
    await _init();
    _startCleanupTimer();
    _beginScan();
    unawaited(ClassicBeaconService.startScanning(_onClassicPacketBytes));
    onStatusUpdate?.call('Relay mode ready [$_deviceId] — scanning...');
    print('MeshService: startRelayMode() ✓');
  }

  /// Victim: start broadcasting SOS (Fix 1: advertise only, no scanning)
  static Future<void> broadcastAlert({
    required double latitude,
    required double longitude,
    required double confidence,
    required String soundType,
    required int    battery,
  }) async {
    if (!_isActive) await startMesh();

    _isVictimMode = true;

    // Previously: _stopScan() here, permanently, for the whole alert.
    // Now: scanning is paused only briefly and periodically via
    // _scanBurstTimer (set up below), so this phone can still receive
    // and relay a nearby second victim's packet instead of being
    // permanently deaf the moment it starts broadcasting its own SOS.
    await _stopScan(); // stop any in-progress scan cleanly before advertising starts

    final seq = _nextSeqNum();
    final packet = MeshPacket(
      originId:   _numericId!,
      relayId:    0,
      networkId:  NETWORK_ID,  // Fix 3
      seqNum:     seq,
      ttl:        DEFAULT_TTL,
      confidence: confidence,
      latitude:   latitude,
      longitude:  longitude,
      battery:    battery,
      hopCount:   0,
      soundCode:  _soundCode(soundType),
    );

    _seenKeys[packet.dedupKey] = DateTime.now();
    print('MeshService: broadcastAlert() key=${packet.dedupKey} '
          'numericId=$_numericId seq=$seq');
    onStatusUpdate?.call('Mesh: SOS broadcasting...');

    // Advertise once — Android BLE keeps broadcasting until stop() is called
    // The periodic timer only CHECKS if advertising stopped (not re-calls start)
    _advertiseTimer?.cancel();
    await _doAdvertise(packet);  // single start — Android handles the rest

    // Second, independent channel — runs in parallel with BLE, not instead
    // of it. If this device's BLE radio doesn't actually transmit (the
    // failure mode we confirmed via nRF Connect), this is what saves the
    // alert from being undetectable entirely.
    unawaited(ClassicBeaconService.startBroadcasting(packet.toBytes()));

    // Watchdog: every 5s verify still advertising, restart ONLY if stopped.
    // The check itself stays frequent for fast restart on failure; the
    // success log is throttled so a multi-minute broadcast doesn't flood
    // the terminal with the same line over and over.
    //
    // NEW: also gives up after ADVERTISE_FAILURE_GIVEUP_THRESHOLD
    // consecutive failures, instead of retrying forever. See
    // _doAdvertise() for where the failure counter is tracked.
    _advertiseTimer = Timer.periodic(
      const Duration(seconds: 5), (_) async {
        if (!_isActive || !_isVictimMode) return;
        if (_bleAdvertisingUnsupported) {
          // Already gave up this session — don't even attempt the
          // isAdvertising check, just stay quiet. broadcastAlert()
          // already logged the give-up message once when this flag
          // was set; repeating it every 5s would be exactly the kind
          // of log spam this fix is meant to eliminate.
          return;
        }
        if (_scanBurstInProgress) {
          // A scan burst is deliberately holding advertising paused
          // right now (see _runScanBurst) — that's expected, not a
          // failure. Don't restart advertising out from under it; the
          // burst itself resumes advertising when it finishes.
          return;
        }
        try {
          final isAdv = await _peripheral.isAdvertising;
          if (isAdv) {
            if (!_throttled('ble_advertising_active')) {
              print('MeshService: ✓ advertising active (BLE)');
            }
            return; // still going — do nothing
          }
          // Stopped unexpectedly — always log, this is a real state change
          print('MeshService: advertising stopped unexpectedly — restarting');
          await _doAdvertise(packet);
        } catch (e) {
          print('MeshService: watchdog error — $e');
        }
    });

    // NEW: scan-burst timer — periodically pause advertising for a
    // short window to listen for nearby packets (see SCAN_BURST_*
    // constants above for the rationale). Runs independently of the
    // advertise watchdog above; the two coordinate via
    // _scanBurstInProgress so the watchdog doesn't fight the burst by
    // trying to "restart" advertising while a burst has deliberately
    // paused it.
    _scanBurstTimer?.cancel();
    _scanBurstTimer = Timer.periodic(
      const Duration(seconds: SCAN_BURST_INTERVAL_S), (_) {
        if (!_isActive || !_isVictimMode) return;
        unawaited(_runScanBurst(packet));
      });
  }

  /// Briefly pauses this victim phone's own advertising to listen for
  /// a nearby device's packet, then resumes advertising its own SOS.
  /// Scanning itself still works even if BLE advertising has been
  /// marked unsupported on this hardware (_bleAdvertisingUnsupported)
  /// — receiving someone else's alert has value on its own, even on a
  /// phone that can't transmit its own via BLE (it still has SMS,
  /// Dashboard, Telegram, and Classic Bluetooth for that).
  static Future<void> _runScanBurst(MeshPacket ownPacket) async {
    if (_scanBurstInProgress) return; // don't overlap with a prior burst
    if (!_isActive || !_isVictimMode) return;

    _scanBurstInProgress = true;
    try {
      if (!_throttled('scan_burst', every: const Duration(seconds: 30))) {
        print('MeshService: victim scan burst — listening for '
              '${SCAN_BURST_DURATION_S}s...');
      }

      // Pause advertising only if it was actually running — on hardware
      // where it's already given up, there's nothing to pause.
      if (!_bleAdvertisingUnsupported) {
        try { await _peripheral.stop(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 150));
      }

      await FlutterBluePlus.startScan(
        timeout:         Duration(seconds: SCAN_BURST_DURATION_S),
        androidScanMode: AndroidScanMode.lowLatency,
      );

      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen(
        (results) { for (final r in results) _onScanResult(r); },
        onError: (e) => print('MeshService: scan burst error — $e'),
      );

      await Future.delayed(const Duration(seconds: SCAN_BURST_DURATION_S));
      await _stopScan();

    } catch (e) {
      print('MeshService: scan burst failed — $e');
    } finally {
      _scanBurstInProgress = false;
      // Resume advertising our own SOS — still the primary job. Only
      // attempt this if BLE advertising hasn't already been given up
      // on for this session.
      if (_isActive && _isVictimMode && !_bleAdvertisingUnsupported) {
        try {
          final isAdv = await _peripheral.isAdvertising;
          if (!isAdv) {
            await _doAdvertise(ownPacket);
          }
        } catch (e) {
          print('MeshService: resume-advertise after burst failed — $e');
        }
      }
    }
  }

  /// Stop everything
  static Future<void> stopMesh() async {
    _isActive          = false;
    _isVictimMode      = false;
    _relayAdvertising  = false;
    _scanLoopActive = false;    // Fix 3
    _advertiseTimer?.cancel();
    _advertiseTimer = null;
    _scanBurstTimer?.cancel();
    _scanBurstTimer = null;
    _scanBurstInProgress = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _stopScan();
    try { await _peripheral.stop(); } catch (_) {}
    await ClassicBeaconService.stopBroadcasting();
    await ClassicBeaconService.stopScanning();
    await Future.delayed(const Duration(milliseconds: 400));
    _seenKeys.clear();
    _pendingRelay.clear();
    _nearbyDevices.clear();
    onStatusUpdate?.call('Mesh: Stopped');
    print('MeshService: stopMesh() ✓');
  }

  /// Reset BLE-advertising health tracking. Called on stopMesh() is
  /// intentionally NOT done automatically — the unsupported-hardware
  /// finding should persist for the lifetime of the app session (the
  /// hardware doesn't change between mesh start/stop cycles), so we
  /// don't waste another 5x5s of retries re-discovering the same fact
  /// every time the user toggles relay/victim mode. Call this
  /// explicitly only if you want to force a fresh attempt (e.g. after
  /// the user has been told and explicitly asks "try again").
  static void resetAdvertisingHealthCheck() {
    _consecutiveAdvertiseFailures = 0;
    _bleAdvertisingUnsupported = false;
    print('MeshService: BLE advertising health check reset — will retry on next attempt');
  }

  static bool get isBleAdvertisingUnsupported => _bleAdvertisingUnsupported;

  // ═══════════════════════════════════════════════════════════════
  // INIT
  // ═══════════════════════════════════════════════════════════════

  static Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    int? id = prefs.getInt(PREFS_ID_KEY);
    if (id == null) {
      id = Random().nextInt(0xFFFE) + 1; // 1–65534, permanent
      await prefs.setInt(PREFS_ID_KEY, id);
    }
    _numericId = id;
    _deviceId  = 'RQN-${id.toRadixString(16).toUpperCase().padLeft(4,'0')}';
    print('MeshService: _init() numericId=$_numericId deviceId=$_deviceId');

    // Fix 7: Check Bluetooth state (permissions should be in AndroidManifest)
    final state = await FlutterBluePlus.adapterState.first;
    print('MeshService: BT adapter state = $state');
    if (state != BluetoothAdapterState.on) {
      onStatusUpdate?.call('Mesh: Bluetooth is OFF — please enable');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SCANNING (relay mode — continuous, Fix 1 & Fix 3)
  // ═══════════════════════════════════════════════════════════════

  static void _beginScan() {
    // Fix 3: prevent double scan loops
    if (_scanLoopActive) {
      print('MeshService: scan already running — skipping');
      return;
    }
    _scanLoopActive = true;
    _doScanLoop();
  }

  static Future<void> _doScanLoop() async {
    print('MeshService: continuous scan loop started');
    while (_isActive && _scanLoopActive) {
      if (_isVictimMode || _isScanning) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }
      await _runOneScan();
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _scanLoopActive = false;
    print('MeshService: scan loop ended');
  }

  static Future<void> _runOneScan() async {
    _isScanning = true;
    try {
      // Stop advertising during scan (BLE radio conflict)
      try {
        if (await _peripheral.isAdvertising) await _peripheral.stop();
      } catch (_) {}

      print('MeshService: starting scan (low latency)...');
      onStatusUpdate?.call('Mesh: Scanning...');

      await FlutterBluePlus.startScan(
        timeout:         const Duration(seconds: 8),
        androidScanMode: AndroidScanMode.lowLatency,
      );

      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen(
        (results) { for (final r in results) _onScanResult(r); },
        onError: (e) => print('MeshService: scan error — $e'),
      );

      await Future.delayed(const Duration(seconds: 8));
      await _stopScan();

      onDevicesUpdated?.call(_nearbyDevices.values.toList());
      final resqCount = _nearbyDevices.values.where((d) => d.isResQNet).length;
      // Always log immediately when we actually find something — that's
      // the one result that matters. Otherwise, this fires every ~8s
      // during continuous relay scanning, so throttle the routine case.
      if (resqCount > 0 || !_throttled('ble_scan_done', every: const Duration(seconds: 30))) {
        print('MeshService: scan done — '
              '${_nearbyDevices.length} total, $resqCount ResQNet');
      }
      onStatusUpdate?.call(
          'Mesh: $resqCount ResQNet / ${_nearbyDevices.length} nearby');

    } catch (e) {
      print('MeshService: scan cycle error — $e');
    } finally {
      _isScanning = false;
    }
  }

  static Future<void> _stopScan() async {
    _scanSub?.cancel();
    _scanSub = null;
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    _isScanning = false;
  }

  // ═══════════════════════════════════════════════════════════════
  // SCAN RESULT PROCESSING
  // ═══════════════════════════════════════════════════════════════

  static void _onScanResult(ScanResult result) {
    final mac    = result.device.remoteId.toString();
    final rssi   = result.rssi;
    final mfData = result.advertisementData.manufacturerData;
    // Use advertisementData.localName — more reliable than device.platformName
    // platformName is often empty on Android until GATT connected
    // advertisementData.localName reads directly from BLE advertisement packet
    final advName  = result.advertisementData.localName;
    final devName  = result.device.platformName;
    final name     = advName.isNotEmpty ? advName : devName;

    // Primary filter: manufacturer ID 0x1234
    // networkId 0xBEEF validated inside packet — no localName needed
    final payload    = mfData[MANUFACTURER_ID];
    final hasPayload = payload != null && payload.length >= PAYLOAD_BYTES;
    final isResQNet  = hasPayload;

    // Update scanner UI device list (ALL devices shown, ResQNet highlighted)
    _nearbyDevices[mac] = MeshDevice(
      deviceId:  mac,
      name:      name.isEmpty ? 'Unknown' : name,
      rssi:      rssi,
      distance:  _rssiToDistance(rssi),
      isResQNet: isResQNet,
      lastSeen:  DateTime.now(),
    );

    // Skip if no payload to process
    if (!hasPayload) {
      // Track unmatched manufacturer IDs for periodic debug summary instead
      // of printing one line per device per scan cycle — with 10-15+
      // nearby BLE devices repeating every ~8s, the old per-device print
      // flooded the terminal within seconds.
      if (mfData.isNotEmpty) {
        for (final id in mfData.keys) {
          _seenOtherMfgIds.add(id);
        }
        if (!_throttled('other_mfg_ids', every: const Duration(seconds: 30))) {
          print('MeshService: other manufacturer IDs seen nearby (last 30s): '
                '${_seenOtherMfgIds.toList()..sort()}');
          _seenOtherMfgIds.clear();
        }
      }
      return;
    }

    if (!_throttled('mfg_match_$mac', every: const Duration(seconds: 30))) {
      print('MeshService: mfData[0x1234] found! mac=$mac rssi=$rssi '
            'len=${payload!.length} name="$name" '
            'advName="$advName" devName="$devName"');
    }

    try {
      // Network ID validated in payload bytes 0-1 (0xBEEF)
      final packet = MeshPacket.fromBytes(payload);
      _handlePacket(packet, via: 'BLE');
    } catch (e) {
      print('MeshService: packet parse error — $e');
    }
  }

  /// Entry point for packets arriving via the classic Bluetooth fallback
  /// channel (decoded from a discovered device name). Feeds the exact
  /// same dedup/relay pipeline as BLE — the rest of the app doesn't need
  /// to know or care which transport a packet came in on.
  static void _onClassicPacketBytes(Uint8List bytes, String mac, int? rssi) {
    try {
      final packet = MeshPacket.fromBytes(bytes);
      _handlePacket(packet, via: 'Classic', mac: mac, rssi: rssi);
    } catch (e) {
      print('MeshService: classic packet parse error — $e');
    }
  }

  /// Shared packet-handling pipeline, transport-agnostic. Both BLE scan
  /// results and classic Bluetooth discovery results end up here after
  /// being decoded into a MeshPacket.
  static void _handlePacket(MeshPacket packet, {
    required String via,
    String? mac,
    int? rssi,
  }) {
    // Verify network ID — reject non-ResQNet data that happened to land
    // in the same field (manufacturer ID collisions, stray name matches).
    if (packet.networkId != NETWORK_ID) {
      print('MeshService: wrong networkId 0x${packet.networkId.toRadixString(16)} '
            '— expected 0x${NETWORK_ID.toRadixString(16)} (via $via)');
      return;
    }

    // Fix 6: dedup by originId + seqNum — same map regardless of which
    // transport the packet arrived on, so a packet seen via BLE and then
    // again via Classic (or vice versa) is still only processed once.
    if (_seenKeys.containsKey(packet.dedupKey)) {
      return; // expected and frequent — not worth logging every time
    }

    // Skip our own packets (originId is the victim, not us as relay)
    if (packet.originId == _numericId) return;

    _seenKeys[packet.dedupKey] = DateTime.now();

    final source = mac != null ? '$via mac=$mac' + (rssi != null ? ' rssi=$rssi' : '') : via;
    print('MeshService: ✓ NEW packet via $source '
          'origin=${packet.displayOrigin} '
          'relay=${packet.displayRelay} '
          'ttl=${packet.ttl} hop=${packet.hopCount}');
    onStatusUpdate?.call(
        'Mesh: ✓ ${packet.displayOrigin} via ${packet.displayRelay} '
        '(hop ${packet.hopCount}, $via)');

    onPacketReceived?.call(packet);
    _forwardToDashboard(packet);

    // Relay if TTL > 0 (relayId = our numericId, originId preserved).
    // Relay on BOTH channels regardless of which one this packet arrived
    // on — a nearby phone might only be capable of detecting one of them.
    if (packet.ttl > 1) {
      final relay = packet.withRelay(_numericId!);
      _seenKeys[relay.dedupKey] = DateTime.now(); // prevent loop

      if (!_relayAdvertising) {
        _relayAdvertising = true;
        _doAdvertise(relay, durationSeconds: 2).catchError(
            (e) => print('MeshService: BLE relay failed — $e')
        ).whenComplete(() => _relayAdvertising = false);
      } else {
        print('MeshService: BLE relay already advertising — skipping overlap');
      }

      unawaited(ClassicBeaconService.startBroadcasting(relay.toBytes())
          .then((_) => Future.delayed(const Duration(seconds: 3)))
          .then((_) => ClassicBeaconService.stopBroadcasting()));
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ADVERTISING
  // ═══════════════════════════════════════════════════════════════

  static Future<void> _doAdvertise(MeshPacket packet, {int durationSeconds = 0}) async {
    // NEW: if we've already concluded BLE advertising is unsupported on
    // this device this session, don't even attempt it — every attempt
    // costs a radio stop/start cycle and ~250-300ms of delay for a
    // result we already know. ClassicBeaconService and the other alert
    // channels (SMS/Dashboard/Telegram) are unaffected by this and
    // continue to carry the alert.
    if (_bleAdvertisingUnsupported) {
      if (!_throttled('ble_advertise_skip_unsupported', every: const Duration(seconds: 60))) {
        print('MeshService: BLE advertising unsupported on this device — '
              'skipping (SMS/Dashboard/Telegram/Classic Bluetooth unaffected)');
      }
      return;
    }

    // During relay (not victim): brief stop of scan
    if (!_isVictimMode && _isScanning) {
      await _stopScan();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    try { await _peripheral.stop(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));

    try {
      await _peripheral.start(
        advertiseData: AdvertiseData(
          includeDeviceName: false,
          includePowerLevel: false,
          manufacturerId:    MANUFACTURER_ID,
          manufacturerData:  packet.toBytes(),
        ),
        advertiseSettings: AdvertiseSettings(
          advertiseMode: AdvertiseMode.advertiseModeLowLatency,
          txPowerLevel:  AdvertiseTxPower.advertiseTxPowerHigh,
          connectable:   false,
          timeout:       0,
        ),
      );

      // Fix 3: verify advertising started
      await Future.delayed(const Duration(milliseconds: 250));
      final isAdv = await _peripheral.isAdvertising;
      final plen = packet.toBytes().length;
    // No localName: 3(flags)+4(mfr overhead)+payload = actual size
    print('MeshService: payload=${plen}B '
          'adv=3+4+$plen=${3+4+plen}B (limit 31) '
          '${3+4+plen <= 31 ? "✓ fits" : "✗ OVERFLOW"}');
    print('MeshService: _doAdvertise() isAdvertising=$isAdv '
            'origin=${packet.displayOrigin} relay=${packet.displayRelay}');

      if (!isAdv) {
        print('MeshService: WARNING — advertise started but isAdvertising=false');
        _recordAdvertiseFailure();
      } else {
        // Genuine success — reset the failure counter so a single past
        // bad run doesn't permanently disable advertising for the rest
        // of the session if the device recovers (e.g. after a Bluetooth
        // toggle off/on by the user).
        _consecutiveAdvertiseFailures = 0;
        if (durationSeconds > 0) {
          // Fix 4: hold for relay window, then STOP (not victim — victim uses timer)
          print('MeshService: holding advertisement for ${durationSeconds}s...');
          await Future.delayed(Duration(seconds: durationSeconds));
          if (!_isVictimMode) {
            try { await _peripheral.stop(); } catch (_) {}
            print('MeshService: relay advertisement stopped after ${durationSeconds}s');
          }
        }
      }
    } catch (e) {
      print('MeshService: _doAdvertise() error — $e');
      _recordAdvertiseFailure();
    }
  }

  /// Tracks consecutive BLE advertising failures. After
  /// ADVERTISE_FAILURE_GIVEUP_THRESHOLD in a row, concludes the
  /// device's Bluetooth hardware/chipset doesn't support the
  /// startAdvertisingSet() extended-advertising API this plugin uses
  /// (a real, documented Android hardware compatibility gap — distinct
  /// from basic BLE peripheral mode, which may still work fine) and
  /// stops retrying for the rest of this app session. This does NOT
  /// affect SMS, Dashboard, Telegram, or the Classic Bluetooth fallback
  /// beacon — only the BLE-advertising-based mesh relay channel.
  static void _recordAdvertiseFailure() {
    _consecutiveAdvertiseFailures++;
    if (_consecutiveAdvertiseFailures >= ADVERTISE_FAILURE_GIVEUP_THRESHOLD &&
        !_bleAdvertisingUnsupported) {
      _bleAdvertisingUnsupported = true;
      print('MeshService: ✗ BLE advertising failed $_consecutiveAdvertiseFailures '
            'times in a row — concluding this device\'s Bluetooth hardware '
            'does not support BLE advertising (startAdvertisingSet). '
            'Giving up on BLE mesh relay for this session. '
            'SMS, Dashboard, Telegram, and Classic Bluetooth fallback '
            'remain fully active and unaffected.');
      onStatusUpdate?.call(
          'Mesh: BLE advertising unsupported on this device — '
          'using SMS/Dashboard/Telegram/Classic Bluetooth instead');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // DASHBOARD FORWARDING
  // ═══════════════════════════════════════════════════════════════

  static Future<void> _forwardToDashboard(MeshPacket packet) async {
    String ip = '';
    try { ip = await SmsService.getDashboardIp(); } catch (_) {}
    if (ip.isEmpty) return;

    // Defense in depth: SmsService.getDashboardIp() already strips any
    // accidental ":port"/scheme/path (see the bug-history comment in
    // sms_service.dart — a stored "host:48702" once silently broke
    // dashboard delivery by colliding with the ":5000" appended below,
    // producing "host:48702:5000" and routing to the wrong port).
    // Stripping again here costs nothing and means this file never has
    // to trust that the stored preference value is well-formed.
    if (ip.contains(':')) {
      ip = ip.split(':').first;
    }

    try {
      final res = await http.post(
        Uri.parse('http://$ip:5000/alert'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'latitude':   packet.latitude,
          'longitude':  packet.longitude,
          'confidence': packet.confidence,
          'sound_type': '${packet.soundTypeFull} [Mesh hop ${packet.hopCount}]',
          'battery':    packet.battery,
          'timestamp':  DateTime.now().toString().substring(0, 19),
          'mesh_relay': true,
          'hop_count':  packet.hopCount,
          'origin_id':  packet.displayOrigin,
          'relay_id':   packet.displayRelay,
          'ttl':        packet.ttl,
        }),
      ).timeout(const Duration(seconds: 5));
      print('MeshService: dashboard '
            '${res.statusCode == 200 ? "✓" : "failed ${res.statusCode}"}');
    } catch (e) {
      print('MeshService: dashboard unreachable — $e');
    }
    try {
      await DatabaseService.saveAlert(AlertRecord(
        soundType:  packet.soundTypeFull,
        confidence: packet.confidence,
        latitude:   packet.latitude,
        longitude:  packet.longitude,
        smsSent:    false,
        dashSent:   true,
      ));
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════
  // DEVICE EXPIRY (Fix 4)
  // ═══════════════════════════════════════════════════════════════

  static void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _cleanupDevices());
  }

  static void _cleanupDevices() {
    final now     = DateTime.now();
    final expiry  = const Duration(seconds: DEVICE_EXPIRY_S);
    _nearbyDevices.removeWhere(
        (_, d) => now.difference(d.lastSeen) > expiry);
    // Fix 6: expire seen keys older than 10 minutes
    final expireTime = const Duration(minutes: 10);
    _seenKeys.removeWhere((_, t) => DateTime.now().difference(t) > expireTime);
    print('MeshService: cleanup — '
          '${_nearbyDevices.length} devices, ${_seenKeys.length} seen keys');
  }

  // ═══════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════

  static int _nextSeqNum() => ++_seqCounter & 0xFF;

  static int _soundCode(String t) {
    final s = t.toLowerCase();
    if (s.contains('cnn') || s.contains('distress')) return 0x43;
    if (s.contains('beacon'))                         return 0x42;
    return 0x53; // SOS
  }

  static double _rssiToDistance(int rssi) {
    const txPower = -59.0; const n = 2.5;
    return pow(10, (txPower - rssi) / (10 * n)).toDouble();
  }

  static String get deviceId   => _deviceId  ?? 'NOT_INIT';
  static int    get numericId  => _numericId ?? 0;
  static bool   get isActive   => _isActive;
  static bool   get isScanning => _isScanning;
  static bool   get isVictim   => _isVictimMode;
  static List<MeshDevice> get nearbyDevices =>
      _nearbyDevices.values.toList();
}

// ═══════════════════════════════════════════════════════════════
// DATA MODELS
// ═══════════════════════════════════════════════════════════════

class MeshPacket {
  final int    originId;    // victim's permanent numeric ID
  final int    relayId;     // relay device ID (0 = this is the origin)
  final int    networkId;   // Fix 3: must equal NETWORK_ID (0xBEEF)
  final int    seqNum;      // 0–255 sequence counter
  final int    ttl;         // hops remaining (decrements each relay)
  final double confidence;
  final double latitude;
  final double longitude;
  final int    battery;
  final int    hopCount;
  final int    soundCode;   // 0x53=SOS 0x43=CNN 0x42=Beacon

  const MeshPacket({
    required this.originId,
    required this.relayId,
    required this.networkId,
    required this.seqNum,
    required this.ttl,
    required this.confidence,
    required this.latitude,
    required this.longitude,
    required this.battery,
    required this.hopCount,
    required this.soundCode,
  });

  // Fix 6: dedup key = originId + seqNum (unique per alert session)
  String get dedupKey => '${originId}_$seqNum';

  String get displayOrigin =>
      'RQN-${originId.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  String get displayRelay => relayId == 0
      ? displayOrigin
      : 'RQN-${relayId.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  String get soundTypeFull {
    switch (soundCode) {
      case 0x43: return 'CNN Distress Detection';
      case 0x42: return 'Acoustic Beacon';
      default:   return 'Manual SOS';
    }
  }

  /// 19-byte payload — EXACT fit: 3(flags)+5(name)+4(mfr overhead)+19=31 bytes ✓
  ///   0-1:  networkId uint16  (0xBEEF) — reject non-ResQNet packets
  ///   2-3:  originId  uint16  — victim's permanent ID
  ///   4-5:  relayId   uint16  — relay device ID (0=origin)
  ///   6:    seqNum    uint8   — deduplication sequence
  ///   7:    ttl       uint8   — hops remaining
  ///   8:    confidence uint8  — 0-100
  ///   9-12: latitude  float32
  ///   13-16:longitude float32
  ///   17:   battery   uint8
  ///   18:   hopCount  uint8
  ///   = 19 bytes ✓
  ///
  ///   Note: Identified by mfData[0x1234]+networkId(0xBEEF). No localName needed.
  Uint8List toBytes() {
    final buf = ByteData(MeshService.PAYLOAD_BYTES); // 20
    // 20-byte payload → 3(flags)+4(mfr overhead)+20 = 27 bytes total ✓
    buf.setUint16(0,  MeshService.NETWORK_ID,               Endian.big);
    buf.setUint16(2,  originId  & 0xFFFF,                   Endian.big);
    buf.setUint16(4,  relayId   & 0xFFFF,                   Endian.big);
    buf.setUint8(6,   seqNum    & 0xFF);
    buf.setUint8(7,   ttl.clamp(0, 255));
    buf.setUint8(8,   (confidence * 100).round().clamp(0, 100));
    buf.setFloat32(9, latitude,  Endian.big);
    buf.setFloat32(13,longitude, Endian.big);
    buf.setUint8(17,  battery.clamp(0, 100));
    buf.setUint8(18,  hopCount.clamp(0, 10));
    buf.setUint8(19,  soundCode);                           // byte 19 restored
    return buf.buffer.asUint8List();
  }

  factory MeshPacket.fromBytes(List<int> bytes) {
    if (bytes.length < MeshService.PAYLOAD_BYTES) {
      throw FormatException('Short packet: ${bytes.length} < ${MeshService.PAYLOAD_BYTES}');
    }
    final d = ByteData.sublistView(Uint8List.fromList(bytes));
    return MeshPacket(
      networkId:  d.getUint16(0, Endian.big),
      originId:   d.getUint16(2, Endian.big),
      relayId:    d.getUint16(4, Endian.big),
      seqNum:     d.getUint8(6),
      ttl:        d.getUint8(7),
      confidence: d.getUint8(8) / 100.0,
      latitude:   d.getFloat32(9,  Endian.big),
      longitude:  d.getFloat32(13, Endian.big),
      battery:    d.getUint8(17),
      hopCount:   d.getUint8(18),
      soundCode:  d.getUint8(19),           // restored at byte 19
    );
  }

  /// Relay: preserve originId, set relayId=our ID, decrement TTL
  MeshPacket withRelay(int myNumericId) => MeshPacket(
    originId:   originId,
    relayId:    myNumericId,  // ← Fix 2: relay identity preserved
    networkId:  networkId,
    seqNum:     seqNum,
    ttl:        ttl - 1,
    confidence: confidence,
    latitude:   latitude,
    longitude:  longitude,
    battery:    battery,
    hopCount:   hopCount + 1,
    soundCode:  soundCode,
  );
}

class MeshDevice {
  final String   deviceId, name;
  final int      rssi;
  final double   distance;
  bool           isResQNet;
  final DateTime lastSeen;   // Fix 4: for expiry

  MeshDevice({
    required this.deviceId,  required this.name,
    required this.rssi,      required this.distance,
    required this.isResQNet, required this.lastSeen,
  });
}