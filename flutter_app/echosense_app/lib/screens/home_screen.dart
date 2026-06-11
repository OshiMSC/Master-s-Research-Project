import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/audio_service.dart';
import '../services/gps_service.dart';
import '../services/sms_service.dart';
import '../services/chirp_service.dart';
import '../services/mesh_service.dart';
import 'active_emergency_screen.dart';

abstract class ResQColors {
  static const black    = Color(0xFF000000);
  static const bg2      = Color(0xFF0F0F0F);
  static const bg3      = Color(0xFF161616);
  static const red      = Color(0xFFFF3B30);
  static const orange   = Color(0xFFFF9500);
  static const green    = Color(0xFF34C759);
  static const blue     = Color(0xFF0A84FF);
  static const textPrim = Color(0xFFFFFFFF);
  static const textHint = Color(0xFF555555);
  static const border   = Color(0xFF1E1E1E);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {

  // ── UI state ──────────────────────────────────────────────
  bool   _disasterMode  = true;
  bool   _isHolding     = false;
  double _holdProgress  = 0.0;
  bool   _chirpActive   = false;
  bool   _flashActive   = false;
  String _systemStatus  = 'All Systems Ready';
  Color  _systemColor   = ResQColors.green;
  double _lat           = 0.0;
  double _lng           = 0.0;

  // ── Mesh state ────────────────────────────────────────────
  bool   _meshActive        = false;
  bool   _meshScanning      = false;
  int    _meshDeviceCount   = 0;
  int    _resqnetDeviceCount = 0;
  List<MeshDevice> _nearbyDevicesList = [];
  int    _meshRelayCount    = 0;
  String _meshStatus        = '';
  String _meshRole          = '';
  bool   _alertSentViaMesh  = false;
  String _lastRelayOrigin   = '';
  String _lastRelaySoundType = '';
  double _lastRelayConfidence = 0.0;

  // ── Alert channel state ───────────────────────────────────
  bool _smsSent       = false;
  bool _telegramSent  = false;
  bool _dashboardSent = false;
  DateTime? _lastAlertTime;
  static const _alertDebounce = Duration(seconds: 30);

  // ── Animation controllers ─────────────────────────────────
  late AnimationController _ringCtrl;
  late AnimationController _waveCtrl;
  late AnimationController _holdCtrl;
  late AnimationController _meshPulseCtrl;

  @override
  void initState() {
    super.initState();

    _ringCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _waveCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200),
    )..repeat();

    _holdCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3000),
    );
    _holdCtrl.addListener(
        () => setState(() => _holdProgress = _holdCtrl.value));
    _holdCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) _onSOSTriggered();
    });

    _meshPulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _fetchGps();
    _setupMeshCallbacks();

    // ── Setup chirp beacon callback ───────────────────────
    // When beacon button pressed → self-report alert immediately
    ChirpService.onBeaconStarted = () => _handleBeaconAlert();
    ChirpService.onBeaconStopped = () {
      if (mounted) {
        setState(() {
          _chirpActive  = false;
          _systemStatus = 'All Systems Ready';
          _systemColor  = ResQColors.green;
        });
      }
    };

    AudioService.initialise().then((_) {
      if (_disasterMode && mounted) {
        AudioService.startListening(
          onDetected: _handleEmergencyTriggered,
          onStatus:   _handleStatusChanged,
        );
      }
    });
  }

  // ── Setup mesh callbacks ──────────────────────────────────
  void _setupMeshCallbacks() {
    MeshService.onStatusUpdate = (msg) {
      if (!mounted) return;
      setState(() {
        _meshStatus  = msg;
        _meshScanning = MeshService.isScanning;
      });
    };
    MeshService.onDevicesUpdated = (devices) {
      if (!mounted) return;
      setState(() {
        _nearbyDevicesList  = devices;
        _meshDeviceCount    = devices.length;
        _resqnetDeviceCount = devices.where((d) => d.isResQNet).length;
        _meshScanning       = false;
      });
    };
    MeshService.onPacketReceived = (packet) {
      if (!mounted) return;
      setState(() {
        _meshRelayCount++;
        _meshRole             = 'RELAY';
        _alertSentViaMesh     = true;
        _meshActive           = true;
        _lastRelayOrigin      = packet.originId;
        _lastRelaySoundType   = packet.soundType;
        _lastRelayConfidence  = packet.confidence;
        _meshStatus = '✓ Packet from ${packet.originId} — relaying...';
      });
      HapticFeedback.heavyImpact();
      print('HomeScreen: BLE packet received from ${packet.originId}');
    };
  }

  // ── GPS ───────────────────────────────────────────────────
  Future<void> _fetchGps() async {
    final pos = await GpsService.getCurrentLocation();
    if (pos != null && mounted) {
      setState(() { _lat = pos.latitude; _lng = pos.longitude; });
    }
  }

  // ── CNN Emergency handler ─────────────────────────────────
  Future<void> _handleEmergencyTriggered(dynamic result) async {
    // Ignore while chirp beacon playing
    if (_chirpActive || ChirpService.isPlaying) {
      print('HomeScreen: Ignoring CNN — chirp beacon active');
      return;
    }
    // Debounce
    final now = DateTime.now();
    if (_lastAlertTime != null &&
        now.difference(_lastAlertTime!) < _alertDebounce) {
      print('HomeScreen: Debounced');
      return;
    }
    _lastAlertTime = now;
    print('HomeScreen: Distress detected — activating alert workflow');

    final position = await GpsService.getCurrentLocation();
    final lat = position?.latitude  ?? _lat;
    final lng = position?.longitude ?? _lng;

    if (mounted) {
      setState(() {
        _systemStatus  = 'DISTRESS CONFIRMED';
        _systemColor   = ResQColors.red;
        _smsSent       = false;
        _telegramSent  = false;
        _dashboardSent = false;
      });
    }

    final sent = await SmsService.sendSosAlert(
      latitude:   lat,
      longitude:  lng,
      confidence: result.confidence,
      soundType:  result.soundType,
    );

    if (mounted) {
      setState(() {
        _smsSent      = sent;
        _telegramSent = true;
      });
    }

    await _startMeshBroadcast(
      latitude: lat, longitude: lng,
      confidence: result.confidence, soundType: result.soundType,
    );

    if (!mounted) return;
    Navigator.pushNamed(context, '/emergency', arguments: {
      'soundType':  result.soundType,
      'confidence': result.confidence,
      'latitude':   lat,
      'longitude':  lng,
    });
  }

  // ── Beacon self-report alert ──────────────────────────────
  /// Triggered immediately when 🔊 button is pressed.
  /// Phone sends alert via SMS + Dashboard + BLE mesh
  /// without waiting for laptop mic detection.
  Future<void> _handleBeaconAlert() async {
    print('HomeScreen: Acoustic beacon activated — sending alert');

    final position = await GpsService.getCurrentLocation();
    final lat = position?.latitude  ?? _lat;
    final lng = position?.longitude ?? _lng;

    // Debounce
    final now = DateTime.now();
    if (_lastAlertTime != null &&
        now.difference(_lastAlertTime!) < _alertDebounce) {
      print('HomeScreen: Beacon alert debounced');
      return;
    }
    _lastAlertTime = now;

    if (mounted) {
      setState(() {
        _systemStatus  = 'BEACON ACTIVE';
        _systemColor   = ResQColors.orange;
        _smsSent       = false;
        _telegramSent  = false;
        _dashboardSent = false;
        _meshActive    = true;
        _meshRole      = 'VICTIM';
      });
    }

    // sendSosAlert handles SMS + Telegram + Dashboard in one call
    try {
      final sent = await SmsService.sendSosAlert(
        latitude:   lat,
        longitude:  lng,
        confidence: 1.0,
        soundType:  'Acoustic Beacon (SOS)',
      );
      if (mounted) {
        setState(() {
          _smsSent       = sent;
          _telegramSent  = true;
          _dashboardSent = true;
        });
      }
      print('HomeScreen: Beacon alert sent — SMS:$sent Dashboard:✓ Telegram:✓');
    } catch (e) {
      print('HomeScreen: Beacon alert error: $e');
    }

    // BLE mesh broadcast
    await _startMeshBroadcast(
      latitude:   lat,
      longitude:  lng,
      confidence: 1.0,
      soundType:  'Acoustic Beacon (SOS)',
    );

    print('HomeScreen: Beacon complete — SMS+Dashboard+Telegram+BLE');
  }

  // ── BLE mesh broadcast ────────────────────────────────────
  Future<void> _startMeshBroadcast({
    required double latitude,
    required double longitude,
    required double confidence,
    required String soundType,
  }) async {
    if (!mounted) return;
    setState(() {
      _meshActive = true;
      _meshRole   = 'VICTIM';
      _meshStatus = 'Broadcasting via BLE mesh...';
    });
    try {
      // Stop existing mesh first to clear _isActive guard
      // then restart fresh so broadcastAlert works correctly
      if (MeshService.isActive) {
        await MeshService.stopMesh();
        await Future.delayed(const Duration(milliseconds: 300));
      }
      await MeshService.startMesh();
      await Future.delayed(const Duration(milliseconds: 200));
      await MeshService.broadcastAlert(
        latitude:   latitude,
        longitude:  longitude,
        confidence: confidence,
        soundType:  soundType,
        battery:    85,
      );
      print('HomeScreen: BLE mesh broadcast started ✓');
      if (mounted) setState(() => _meshStatus = 'Broadcasting alert via BLE mesh...');
    } catch (e) {
      print('HomeScreen: Mesh failed — $e');
      if (mounted) setState(() => _meshStatus = 'Mesh unavailable: $e');
    }
  }

  // ── Status callback ───────────────────────────────────────
  void _handleStatusChanged(VadStatus status) {
    if (!mounted) return;
    setState(() {
      switch (status) {
        case VadStatus.silence:
          _systemStatus = 'AI Monitoring Active';
          _systemColor  = ResQColors.green; break;
        case VadStatus.soundDetected:
          _systemStatus = 'Sound Detected...';
          _systemColor  = ResQColors.orange; break;
        case VadStatus.distressConfirmed:
          _systemStatus = 'DISTRESS CONFIRMED';
          _systemColor  = ResQColors.red; break;
        case VadStatus.idle:
          _systemStatus = 'All Systems Ready';
          _systemColor  = ResQColors.green; break;
      }
    });
  }

  // ── Manual SOS ────────────────────────────────────────────
  void _onSOSTriggered() {
    HapticFeedback.heavyImpact();
    _holdCtrl.reset();
    setState(() { _isHolding = false; _holdProgress = 0; });
    // Use full alert flow — same as CNN detection
    _handleManualSOS();
  }

  Future<void> _handleManualSOS() async {
    final now = DateTime.now();
    _lastAlertTime = now;

    final position = await GpsService.getCurrentLocation();
    final lat = position?.latitude  ?? _lat;
    final lng = position?.longitude ?? _lng;

    if (mounted) {
      setState(() {
        _systemStatus  = 'DISTRESS CONFIRMED';
        _systemColor   = ResQColors.red;
        _smsSent       = false;
        _telegramSent  = false;
        _dashboardSent = false;
      });
    }

    // SMS + Telegram + Dashboard in one call
    final sent = await SmsService.sendSosAlert(
      latitude:   lat,
      longitude:  lng,
      confidence: 1.0,
      soundType:  'Manual SOS (button pressed)',
    );

    if (mounted) {
      setState(() {
        _smsSent       = sent;
        _telegramSent  = true;
        _dashboardSent = true;
      });
    }

    // BLE mesh broadcast
    await _startMeshBroadcast(
      latitude:   lat,
      longitude:  lng,
      confidence: 1.0,
      soundType:  'Manual SOS (button pressed)',
    );

    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ActiveEmergencyScreen(
        soundType:  'Manual SOS (button pressed)',
        confidence: 1.0,
        latitude:   lat,
        longitude:  lng,
      )));
  }

  @override
  void dispose() {
    _ringCtrl.dispose();
    _waveCtrl.dispose();
    _holdCtrl.dispose();
    _meshPulseCtrl.dispose();
    AudioService.stopListening();
    ChirpService.stopChirp();
    if (_meshActive) MeshService.stopMesh();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ResQColors.black,
      body: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        SafeArea(child: Column(children: [
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(children: [
              const SizedBox(height: 10),
              _buildTopBar(),
              const SizedBox(height: 10),
              _buildStatusCard(),
              const SizedBox(height: 18),
              _buildSOSButton(),
              const SizedBox(height: 18),
              _buildQuickActions(),
              const SizedBox(height: 10),
              _buildWaveformCard(),
              const SizedBox(height: 10),
              if (_meshActive) ...[
                _buildMeshStatusCard(),
                const SizedBox(height: 10),
              ],
              _buildDisasterToggle(),
              const SizedBox(height: 8),
            ]),
          )),
        ])),
      ]),
    );
  }

  // ── Top bar ───────────────────────────────────────────────
  Widget _buildTopBar() => Row(children: [
    Expanded(child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Good morning,',
        style: TextStyle(fontSize: 11, color: ResQColors.textHint)),
      const SizedBox(height: 2),
      const Text('Oshadee 👋',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700,
          color: ResQColors.textPrim)),
    ])),
    Container(
      width: 36, height: 36,
      decoration: BoxDecoration(
        color: ResQColors.bg2, shape: BoxShape.circle,
        border: Border.all(color: ResQColors.border)),
      child: const Center(
        child: Text('🛡️', style: TextStyle(fontSize: 16)))),
  ]);

  // ── Status card ───────────────────────────────────────────
  Widget _buildStatusCard() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: ResQColors.bg2,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: ResQColors.border)),
    child: Row(children: [
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('SYSTEM STATUS', style: TextStyle(
          fontSize: 9, color: ResQColors.textHint,
          fontWeight: FontWeight.w600, letterSpacing: 0.08)),
        const SizedBox(height: 5),
        Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 7, height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle, color: _systemColor,
              boxShadow: [BoxShadow(
                color: _systemColor.withOpacity(0.5), blurRadius: 6)])),
          const SizedBox(width: 7),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 400),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
              color: _systemColor),
            child: Text(_systemStatus)),
        ]),
      ])),
      Row(children: [
        _sIcon('📡', ResQColors.green),
        const SizedBox(width: 5),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: _meshActive
                ? ResQColors.blue.withOpacity(0.25)
                : ResQColors.blue.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _meshActive
                  ? ResQColors.blue.withOpacity(0.8)
                  : ResQColors.blue.withOpacity(0.3))),
          child: const Center(
            child: Icon(Icons.bluetooth, color: ResQColors.blue, size: 14))),
        const SizedBox(width: 5),
        _sIcon('📍', ResQColors.green),
      ]),
    ]),
  );

  Widget _sIcon(String ic, Color c) => Container(
    width: 28, height: 28,
    decoration: BoxDecoration(
      color: c.withOpacity(0.12),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: c.withOpacity(0.3))),
    child: Center(child: Text(ic, style: const TextStyle(fontSize: 12))));

  // ── SOS button ────────────────────────────────────────────
  Widget _buildSOSButton() => Column(children: [
    Text(
      _isHolding ? 'Keep holding...' : 'Hold 3 seconds to activate',
      style: const TextStyle(
        fontSize: 9, color: ResQColors.textHint, letterSpacing: 0.08)),
    const SizedBox(height: 14),
    GestureDetector(
      onLongPressStart: (_) {
        HapticFeedback.mediumImpact();
        setState(() => _isHolding = true);
        _holdCtrl.forward();
      },
      onLongPressEnd: (_) {
        if (_holdProgress < 1.0) {
          _holdCtrl.reset();
          setState(() { _isHolding = false; _holdProgress = 0; });
        }
      },
      child: SizedBox(
        width: 180, height: 180,
        child: Stack(alignment: Alignment.center, children: [
          AnimatedBuilder(
            animation: _ringCtrl,
            builder: (_, __) {
              final v = _ringCtrl.value;
              return Stack(alignment: Alignment.center, children: [
                _sosRing(138 + v * 8,  0.15 + v * 0.08),
                _sosRing(158 + v * 10, 0.08 + v * 0.05),
                _sosRing(178 + v * 12, 0.04 + v * 0.03),
              ]);
            }),
          if (_isHolding)
            SizedBox(
              width: 124, height: 124,
              child: CircularProgressIndicator(
                value: _holdProgress, strokeWidth: 2.5,
                backgroundColor: Colors.white.withOpacity(0.1),
                valueColor: const AlwaysStoppedAnimation(Colors.white))),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 116, height: 116,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.3, -0.3),
                colors: _isHolding
                    ? [const Color(0xFFFF8080), ResQColors.red]
                    : [const Color(0xFFFF6B6B), ResQColors.red]),
              boxShadow: [BoxShadow(
                color: ResQColors.red.withOpacity(
                  _isHolding ? 0.7 : 0.45),
                blurRadius: _isHolding ? 65 : 40,
                spreadRadius: _isHolding ? 14 : 6)]),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('SOS', style: TextStyle(
                fontSize: 30, fontWeight: FontWeight.w800,
                color: Colors.white, letterSpacing: 3)),
              SizedBox(height: 3),
              Text('EMERGENCY', style: TextStyle(
                fontSize: 8, fontWeight: FontWeight.w600,
                color: Colors.white70, letterSpacing: 2)),
            ])),
        ])),
    ),
    const SizedBox(height: 10),
    AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: (_disasterMode ? ResQColors.green : ResQColors.textHint)
            .withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: (_disasterMode ? ResQColors.green : ResQColors.textHint)
              .withOpacity(0.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('●', style: TextStyle(
          fontSize: 8,
          color: _disasterMode ? ResQColors.green : ResQColors.textHint)),
        const SizedBox(width: 5),
        Text(
          _disasterMode ? 'Disaster Mode Active' : 'Standby',
          style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w600,
            color: _disasterMode ? ResQColors.green : ResQColors.textHint)),
      ])),
  ]);

  Widget _sosRing(double size, double opacity) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: ResQColors.red.withOpacity(opacity), width: 1.5)));

  // ── Quick actions ─────────────────────────────────────────
  Widget _buildQuickActions() {
    final actions = [
      // 🔊 Acoustic beacon — self-reports alert when pressed
      _QA('🔊', 'Acoustic\nSignal', _chirpActive, () async {
        HapticFeedback.mediumImpact();
        setState(() => _chirpActive = !_chirpActive);
        if (_chirpActive) {
          await ChirpService.startChirp();  // callback fires → alert sent
        } else {
          await ChirpService.stopChirp();
        }
      }),
      _QA('📡', 'Relay\nMode', _meshActive && _meshRole == 'RELAY', () async {
        HapticFeedback.mediumImpact();
        if (_meshActive && _meshRole == 'RELAY') {
          MeshService.stopMesh();
          setState(() { _meshActive = false; _meshRole = ''; _meshStatus = ''; });
        } else {
          setState(() {
            _meshActive = true;
            _meshRole   = 'RELAY';
            _meshStatus = 'Relay mode — scanning...';
          });
          await MeshService.startRelayMode(
            onStatusUpdate:  (msg) => setState(() => _meshStatus = msg),
            onPacketRelayed: (p)   => setState(() {
              _meshRelayCount++;
              _meshStatus = 'Relayed: ${p.originId.substring(0, 8)}';
            }),
          );
        }
      }),
      _QA('📨', 'Send\nSMS', false, () {
        SmsService.sendManualSos(latitude: _lat, longitude: _lng);
        HapticFeedback.mediumImpact();
      }),
    ];

    return Row(children: actions.asMap().entries.map((e) {
      final i = e.key; final a = e.value;
      return Expanded(child: Padding(
        padding: EdgeInsets.only(
          left: i == 0 ? 0 : 5, right: i == 2 ? 0 : 5),
        child: GestureDetector(
          onTap: a.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: a.active
                  ? ResQColors.orange.withOpacity(0.08)
                  : ResQColors.bg2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: a.active
                    ? ResQColors.orange.withOpacity(0.5)
                    : ResQColors.border)),
            child: Column(children: [
              Text(a.icon, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 5),
              Text(a.label,
                style: const TextStyle(
                  fontSize: 9, color: Color(0xFF666666)),
                textAlign: TextAlign.center),
            ])))));
    }).toList());
  }

  // ── Waveform card ─────────────────────────────────────────
  Widget _buildWaveformCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: ResQColors.bg2,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: ResQColors.border)),
    child: Column(children: [
      Row(children: [
        const Text('AI Detection — Listening',
          style: TextStyle(fontSize: 10, color: Color(0xFF666666))),
        const Spacer(),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: (_disasterMode ? ResQColors.green : ResQColors.textHint)
                .withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: (_disasterMode ? ResQColors.green : ResQColors.textHint)
                  .withOpacity(0.3))),
          child: Text(
            _disasterMode ? '● ACTIVE' : '○ STANDBY',
            style: TextStyle(
              fontSize: 9, fontWeight: FontWeight.w600,
              color: _disasterMode
                  ? ResQColors.green : ResQColors.textHint))),
      ]),
      const SizedBox(height: 10),
      AnimatedBuilder(
        animation: _waveCtrl,
        builder: (_, __) {
          final heights = [
            6.0,10,14,18,24,20,16,12,8,14,20,28,22,16,
            10,8,12,18,24,20,14,10,8,12,16,20,14,8,
          ];
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(heights.length, (i) {
              final phase = (_waveCtrl.value * 2 * math.pi) + (i * 0.3);
              final h = _disasterMode
                  ? (heights[i] * (0.4 + 0.6 * math.sin(phase).abs()))
                      .clamp(3.0, 28.0)
                  : 3.0;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  width: 2.5, height: h,
                  decoration: BoxDecoration(
                    color: _disasterMode
                        ? HSLColor.fromAHSL(
                            1, 211.0 + i * 1.5, 0.9, 0.6).toColor()
                        : ResQColors.border,
                    borderRadius: BorderRadius.circular(1.5))));
            }));
        }),
    ]));

  // ── BLE Mesh status card ──────────────────────────────────
  Widget _buildMeshStatusCard() => AnimatedContainer(
    duration: const Duration(milliseconds: 400),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: ResQColors.blue.withOpacity(0.07),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: ResQColors.blue.withOpacity(
          _meshScanning ? 0.8 : 0.4), width: 1.5)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [

      // ── Header ──────────────────────────────────────
      Row(children: [
        AnimatedBuilder(
          animation: _meshPulseCtrl,
          builder: (_, __) => Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.lerp(
                ResQColors.blue,
                ResQColors.blue.withOpacity(0.2),
                _meshPulseCtrl.value)!,
              boxShadow: [BoxShadow(
                color: ResQColors.blue.withOpacity(0.5),
                blurRadius: 6)]))),
        const SizedBox(width: 8),
        const Text('BLE MESH NETWORK',
          style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w800,
            color: ResQColors.blue, letterSpacing: 0.5)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: ResQColors.blue.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ResQColors.blue.withOpacity(0.5))),
          child: Text(
            _meshRole.isEmpty ? 'ACTIVE' : _meshRole,
            style: const TextStyle(
              fontFamily: 'Courier New', fontSize: 11,
              fontWeight: FontWeight.w800, color: ResQColors.blue))),
      ]),

      const SizedBox(height: 12),

      // ── Channel badges ───────────────────────────────
      Row(children: [
        _channelBadge('SMS',       _smsSent),
        const SizedBox(width: 6),
        _channelBadge('Telegram',  _telegramSent),
        const SizedBox(width: 6),
        _channelBadge('Dashboard', _dashboardSent),
        const SizedBox(width: 6),
        _channelBadge('BLE Mesh',  _meshActive),
      ]),

      const SizedBox(height: 12),

      // ── Stats row ─────────────────────────────────────
      Row(children: [
        Expanded(child: _meshStat(Icons.devices,
          '$_meshDeviceCount', 'All BT')),
        Expanded(child: _meshStat(Icons.app_shortcut,
          '$_resqnetDeviceCount', 'ResQNet')),
        Expanded(child: _meshStat(Icons.swap_horiz,
          '$_meshRelayCount', 'Relayed')),
        Expanded(child: _meshStat(Icons.radar,
          _meshScanning ? 'ON' : 'OFF', 'Scanning')),
      ]),
      // ResQNet device list
      if (_resqnetDeviceCount > 0) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: ResQColors.blue.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ResQColors.blue.withOpacity(0.3))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('ResQNet Nodes Detected:',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: ResQColors.blue)),
              const SizedBox(height: 4),
              ..._nearbyDevicesList
                .where((d) => d.isResQNet)
                .map((d) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    const Icon(Icons.bluetooth_connected,
                      color: ResQColors.green, size: 13),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      d.deviceId.substring(0,d.deviceId.length < 17 ? d.deviceId.length : 17),
                      style: const TextStyle(
                        fontFamily: 'Courier New', fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFCCCCCC)))),
                    Text('${d.rssi} dBm',
                      style: const TextStyle(
                        fontSize: 10, color: ResQColors.textHint)),
                  ]))),
            ])),
      ],

      // ── Status message ────────────────────────────────
      if (_meshStatus.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(8)),
          child: Text(
            _meshStatus.length > 60
                ? '${_meshStatus.substring(0, 60)}...' : _meshStatus,
            style: const TextStyle(
              fontFamily: 'Courier New',
              fontSize: 11, fontWeight: FontWeight.w500,
              color: Color(0xFF8888BB))),
        ),
      ],

      // ── Received packet banner ────────────────────────
      if (_alertSentViaMesh) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ResQColors.green.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: ResQColors.green.withOpacity(0.5), width: 1.5)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // Title row
            Row(children: [
              const Icon(Icons.check_circle,
                color: ResQColors.green, size: 16),
              const SizedBox(width: 8),
              const Text('BLE Packet Received & Relayed',
                style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700,
                  color: ResQColors.green)),
            ]),

            if (_lastRelayOrigin.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(color: Color(0xFF1A3A1A), height: 1),
              const SizedBox(height: 8),

              // Origin device
              Row(children: [
                const Icon(Icons.smartphone,
                  color: ResQColors.textHint, size: 13),
                const SizedBox(width: 6),
                const Text('From: ',
                  style: TextStyle(
                    fontSize: 12, color: ResQColors.textHint,
                    fontWeight: FontWeight.w600)),
                Text(_lastRelayOrigin,
                  style: const TextStyle(
                    fontFamily: 'Courier New',
                    fontSize: 12, fontWeight: FontWeight.w700,
                    color: Color(0xFFCCCCCC))),
              ]),
              const SizedBox(height: 5),

              // Sound type + confidence
              Row(children: [
                const Icon(Icons.graphic_eq,
                  color: ResQColors.textHint, size: 13),
                const SizedBox(width: 6),
                Expanded(child: Text(
                  '$_lastRelaySoundType — ${(_lastRelayConfidence*100).round()}% confidence',
                  style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: Color(0xFFCCCCCC)))),
              ]),
            ],
          ])),
      ],
    ]));

  Widget _channelBadge(String label, bool sent) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: sent
            ? ResQColors.green.withOpacity(0.12)
            : ResQColors.textHint.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: sent
              ? ResQColors.green.withOpacity(0.5)
              : ResQColors.border, width: sent ? 1.5 : 1.0)),
      child: Column(children: [
        Icon(sent ? Icons.check_circle : Icons.hourglass_empty,
          color: sent ? ResQColors.green : ResQColors.textHint,
          size: sent ? 14 : 12),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(
          fontSize: 9, fontWeight: FontWeight.w700,
          color: sent ? ResQColors.green : ResQColors.textHint)),
      ])));

  Widget _meshStat(IconData icon, String value, String label) =>
    Column(children: [
      Icon(icon, color: ResQColors.blue, size: 18),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(
        fontSize: 16, fontWeight: FontWeight.w800,
        color: ResQColors.textPrim, fontFamily: 'Courier New')),
      Text(label, style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.w500,
        color: ResQColors.textHint)),
    ]);

  // ── Disaster mode toggle ──────────────────────────────────
  Widget _buildDisasterToggle() => GestureDetector(
    onTap: () async {
      HapticFeedback.mediumImpact();
      setState(() => _disasterMode = !_disasterMode);
      if (_disasterMode) {
        await AudioService.startListening(
          onDetected: _handleEmergencyTriggered,
          onStatus:   _handleStatusChanged,
        );
      } else {
        await AudioService.stopListening();
        if (_meshActive) {
          await MeshService.stopMesh();
          setState(() { _meshActive = false; _meshStatus = ''; _meshRole = ''; });
        }
        setState(() {
          _systemStatus     = 'All Systems Ready';
          _systemColor      = ResQColors.green;
          _smsSent          = false;
          _telegramSent     = false;
          _dashboardSent    = false;
          _alertSentViaMesh = false;
        });
      }
    },
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ResQColors.bg2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _disasterMode
              ? ResQColors.green.withOpacity(0.4) : ResQColors.border)),
      child: Row(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: (_disasterMode ? ResQColors.green : ResQColors.textHint)
                .withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: (_disasterMode ? ResQColors.green : ResQColors.textHint)
                  .withOpacity(0.3))),
          child: const Center(
            child: Icon(Icons.sensors, color: Colors.white, size: 18))),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 300),
            style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: _disasterMode ? ResQColors.green : ResQColors.textPrim),
            child: const Text('Disaster Mode')),
          const SizedBox(height: 2),
          Text(
            _disasterMode
                ? 'CNN monitoring + BLE mesh ready'
                : 'Tap to activate monitoring',
            style: const TextStyle(
              fontSize: 10, color: ResQColors.textHint)),
        ])),
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 40, height: 22,
          decoration: BoxDecoration(
            color: _disasterMode ? ResQColors.green : const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(11)),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 300),
            alignment: _disasterMode
                ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 18, height: 18,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Colors.white,
                boxShadow: [BoxShadow(
                  color: Colors.black26, blurRadius: 3)])))),
      ])),
  );
}

class _QA {
  final String icon, label;
  final bool active;
  final VoidCallback onTap;
  const _QA(this.icon, this.label, this.active, this.onTap);
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x06FFFFFF)
      ..strokeWidth = 0.5;
    const s = 40.0;
    for (double x = 0; x <= size.width; x += s)
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y <= size.height; y += s)
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
  }
  @override bool shouldRepaint(_GridPainter o) => false;
}