import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'detection_service.dart';
import 'gps_service.dart';
import 'sms_service.dart';
import 'mesh_service.dart';

/// ResQNet — Background Audio Monitoring Service
/// ===============================================
/// WHY THIS FILE EXISTS:
/// The existing AudioService (audio_service.dart) only runs while
/// HomeScreen's widget tree is alive — i.e. only while the app is
/// open and in the foreground. The moment the app is backgrounded or
/// the screen locks, Android suspends Dart execution (typically
/// within ~60 seconds for microphone access, sometimes sooner
/// depending on OEM battery optimization). For a disaster victim who
/// may be unconscious, trapped, or simply has their phone in a
/// pocket with the screen off, that means detection silently stops
/// working at precisely the moment it matters most.
///
/// This file configures flutter_background_service to run an actual
/// Android foreground service (persistent notification, required by
/// Android — this is not optional or hideable, and is in fact a
/// reasonable, expected thing for a safety app to show: "ResQNet is
/// listening for distress sounds"). The detection loop inside
/// onStart() below runs in a SEPARATE BACKGROUND ISOLATE from the UI,
/// which is why it cannot directly call AudioService's static
/// methods or share object references with HomeScreen — instead it
/// reimplements the same capture/RMS-gate/CNN/confirm pipeline
/// (intentionally kept as close as possible to AudioService's logic
/// for consistency) and calls the SAME alert-sending services
/// (SmsService, MeshService) directly from within the background
/// isolate — meaning an alert can fire and actually go out even if
/// the app's UI was never reopened after being backgrounded.
///
/// KNOWN LIMITATIONS (be upfront about these — see also the
/// project's documented limitations section):
///  1. UNTESTED: flutter_sound's recorder has only been validated
///     running in the main UI isolate so far in this project. Some
///     audio plugins behave differently when initialized from a
///     background isolate. THIS IS THE FIRST THING TO VERIFY on a
///     real device before trusting this in a demo.
///  2. OEM battery optimization (Xiaomi/MIUI, Samsung, OnePlus, etc.)
///     can still kill foreground services more aggressively than
///     stock Android, regardless of correct foregroundServiceType
///     usage — this is a well-documented, OS-vendor-level behavior,
///     not something app code can fully control. The user may need
///     to manually exempt ResQNet from battery optimization in
///     Settings for reliable long-duration background operation.
///  3. iOS is NOT supported by this approach at all — Android's
///     foreground service model has no real iOS equivalent; iOS only
///     allows brief periodic background fetches (15+ min intervals,
///     ~15-30s alive), which is not viable for continuous audio
///     monitoring. This is an Android-only capability by design.

const int _kNotificationId = 9888;
const String _kNotificationChannelId = 'resqnet_background_channel';

class BackgroundAudioService {
  static const int CHUNK_SECONDS   = 3;
  static const double RMS_THRESHOLD = 0.008;

  /// Call once at app startup (e.g. in main(), alongside
  /// WidgetsFlutterBinding.ensureInitialized()) to register the
  /// service. This does NOT start it yet — call start() separately,
  /// e.g. when the user enables Disaster Mode.
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    final notificationsPlugin = FlutterLocalNotificationsPlugin();
    const channel = AndroidNotificationChannel(
      _kNotificationChannelId,
      'ResQNet Background Monitoring',
      description: 'Keeps distress detection running when the app is minimised',
      importance: Importance.low, // low = no sound/vibration spam, just a visible icon
    );
    await notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,       // explicit start() call required — see start() below
        isForegroundMode: true, // REQUIRED for continued mic access — this is what
                                 // keeps Android from suspending the isolate after ~60s
        notificationChannelId: _kNotificationChannelId,
        initialNotificationTitle: 'ResQNet — Monitoring for distress',
        initialNotificationContent: 'Listening in the background',
        foregroundServiceNotificationId: _kNotificationId,
        autoStartOnBoot: false,
      ),
      iosConfiguration: IosConfiguration(
        // iOS background audio monitoring is not supported by this
        // approach (see class doc above) — configured minimally so
        // the package doesn't throw on iOS builds, not because
        // background detection actually works there.
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  /// Starts the background foreground service. Call this when the
  /// user enables Disaster Mode (mirrors AudioService.startListening
  /// being called from HomeScreen today).
  static Future<void> start() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (isRunning) {
      print('BackgroundAudioService: already running');
      return;
    }
    await service.startService();
    print('BackgroundAudioService: start() requested');
  }

  /// Stops the background service entirely (e.g. user disables
  /// Disaster Mode, or logs out).
  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  static Future<bool> isRunning() async {
    return FlutterBackgroundService().isRunning();
  }
}

/// iOS background fetch entry point — see class doc: this is a
/// best-effort stub, not a working continuous-monitoring solution on
/// iOS. Returning true tells the plugin the brief background window
/// completed without error.
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

/// ═══════════════════════════════════════════════════════════════
/// THE ACTUAL BACKGROUND ISOLATE ENTRY POINT
/// ═══════════════════════════════════════════════════════════════
/// Everything below this point runs in a SEPARATE ISOLATE from the
/// app's UI. It cannot see HomeScreen's state, cannot call
/// AudioService's static fields directly (different isolate = no
/// shared memory), and cannot use BuildContext. It communicates with
/// the UI isolate (if one happens to be open) only via
/// service.invoke()/service.on() message-passing — see the
/// 'distress_detected' event sent below, which HomeScreen can
/// optionally listen for to update its display.
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    print('BackgroundAudioService: stopService received');
    service.stopSelf();
  });

  print('BackgroundAudioService: onStart() — background isolate alive');

  // Load the CNN model fresh in THIS isolate — the foreground
  // AudioService's loaded interpreter lives in a different isolate
  // and can't be reused here.
  final modelLoaded = await DetectionService.loadModel();
  if (!modelLoaded) {
    print('BackgroundAudioService: CNN model failed to load — stopping');
    service.stopSelf();
    return;
  }

  final recorder = FlutterSoundRecorder();
  try {
    await recorder.openRecorder();
  } catch (e) {
    print('BackgroundAudioService: recorder.openRecorder() failed — $e');
    print('BackgroundAudioService: this may indicate flutter_sound does '
          'not support initialization from a background isolate on this '
          'device — see known limitations in background_audio_service.dart');
    service.stopSelf();
    return;
  }

  int consecutiveDistressHits = 0;
  bool running = true;
  service.on('stopService').listen((event) => running = false);

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'ResQNet — Monitoring active',
      content: 'Listening for distress sounds in the background',
    );
  }

  while (running) {
    try {
      final buffer = await _recordChunk(recorder);
      if (buffer == null || buffer.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final rms = _calculateRMS(buffer);

      if (rms > BackgroundAudioService.RMS_THRESHOLD) {
        print('BackgroundAudioService: sound detected (RMS=$rms) — running CNN');
        final result = await DetectionService.classify(buffer);
        print('BackgroundAudioService: CNN -> ${result.confidencePercent} '
              '(${result.soundType}) isDistress=${result.isDistress}');

        if (result.isDistress) {
          consecutiveDistressHits++;
          if (consecutiveDistressHits >= 2) {
            consecutiveDistressHits = 0;
            print('BackgroundAudioService: DISTRESS CONFIRMED — sending alert');

            // Tell the UI, IF one happens to be listening — this is a
            // bonus, not a requirement. The alert below fires
            // regardless of whether anyone receives this event.
            service.invoke('distress_detected', {
              'soundType':  result.soundType,
              'confidence': result.confidence,
            });

            await _sendBackgroundAlert(result.soundType, result.confidence);

            if (service is AndroidServiceInstance) {
              service.setForegroundNotificationInfo(
                title: 'ResQNet — ALERT SENT',
                content: '${result.soundType} detected — emergency alert sent',
              );
            }

            // Same 60s cool-down as the foreground AudioService, to
            // avoid flooding SMS/dashboard/mesh channels with repeat
            // alerts for the same ongoing event.
            print('BackgroundAudioService: cooling down for 60s...');
            await Future.delayed(const Duration(seconds: 60));
            if (service is AndroidServiceInstance) {
              service.setForegroundNotificationInfo(
                title: 'ResQNet — Monitoring active',
                content: 'Listening for distress sounds in the background',
              );
            }
            continue;
          }
        } else {
          consecutiveDistressHits = 0;
        }
      } else {
        consecutiveDistressHits = 0;
      }
    } catch (e) {
      print('BackgroundAudioService: loop error — $e');
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  try {
    await recorder.closeRecorder();
  } catch (_) {}
  print('BackgroundAudioService: loop ended, service stopping');
}

/// Sends the alert via the same channels HomeScreen uses for a
/// foreground CNN detection — SMS/Telegram/Dashboard, then BLE mesh.
/// Deliberately mirrors _handleEmergencyTriggered's alert-sending
/// steps in home_screen.dart (minus anything UI-specific like
/// Navigator/setState) so behavior is consistent regardless of
/// whether detection happened in the foreground or background.
Future<void> _sendBackgroundAlert(String soundType, double confidence) async {
  try {
    final position = await GpsService.getCurrentLocation();
    final lat = position?.latitude  ?? 0.0;
    final lng = position?.longitude ?? 0.0;

    final sent = await SmsService.sendSosAlert(
      latitude:   lat,
      longitude:  lng,
      confidence: confidence,
      soundType:  '$soundType (detected in background)',
    );
    print('BackgroundAudioService: SMS/Telegram/Dashboard sent=$sent');

    await MeshService.broadcastAlert(
      latitude:   lat,
      longitude:  lng,
      confidence: confidence,
      soundType:  '$soundType (detected in background)',
      battery:    85,
    );
    print('BackgroundAudioService: mesh broadcast started');
  } catch (e) {
    print('BackgroundAudioService: alert sending error — $e');
  }
}

Future<Float32List?> _recordChunk(FlutterSoundRecorder recorder) async {
  try {
    if (recorder.isRecording) {
      await recorder.stopRecorder();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/resqnet_bg_chunk.wav';
    final file = File(filePath);
    if (await file.exists()) {
      try { await file.delete(); } catch (_) {}
    }

    await Future.delayed(const Duration(milliseconds: 100));

    await recorder.startRecorder(
      toFile: filePath,
      codec: Codec.pcm16WAV,
      sampleRate: 22050,
      numChannels: 1,
    );

    await Future.delayed(const Duration(seconds: BackgroundAudioService.CHUNK_SECONDS));
    await recorder.stopRecorder();
    await Future.delayed(const Duration(milliseconds: 200));

    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    return _wavBytesToFloat32(bytes);
  } catch (e) {
    print('BackgroundAudioService: _recordChunk error — $e');
    try { await recorder.stopRecorder(); } catch (_) {}
    return null;
  }
}

double _calculateRMS(Float32List samples) {
  if (samples.isEmpty) return 0.0;
  double sumOfSquares = 0.0;
  for (int i = 0; i < samples.length; i++) {
    sumOfSquares += samples[i] * samples[i];
  }
  return sqrt(sumOfSquares / samples.length);
}

Float32List _wavBytesToFloat32(Uint8List wavBytes) {
  const int headerOffset = 44;
  if (wavBytes.length <= headerOffset) return Float32List(0);
  final pcmData = Uint8List.sublistView(wavBytes, headerOffset);
  final int sampleCount = pcmData.length ~/ 2;
  final float32List = Float32List(sampleCount);
  final byteData = ByteData.sublistView(pcmData);
  for (int i = 0; i < sampleCount; i++) {
    final sample16 = byteData.getInt16(i * 2, Endian.little);
    float32List[i] = sample16 / 32768.0;
  }
  return float32List;
}
