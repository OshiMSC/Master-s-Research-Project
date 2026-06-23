import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'detection_service.dart';
import 'gps_service.dart';
import 'sms_service.dart';
import 'package:logger/logger.dart'; 

typedef OnDistressDetected = void Function(DetectionResult result);
typedef OnVadStatus        = void Function(VadStatus status);

// ── Top-level function for compute() ──────────────────────────
// FIX (four-part, found in sequence via real-device debugging):
//
// PART 1: compute() runs this in a SEPARATE ISOLATE with its own
// independent copy of DetectionService's static state — confirmed
// via Flutter's own documentation: "Static and global variables are
// initialized anew in the spawned isolate, in a separate memory
// space." This meant DetectionService._interpreter was never visible
// here, so classify() always hit its RMS*2.0 fallback — confirmed by
// testing every real CNN% value seen in testing against that exact
// formula: every single one matched.
//
// PART 2 & 3 (superseded by this revision): two attempts to make the
// compute isolate load its OWN copy of the model via
// Interpreter.fromAsset() + BackgroundIsolateBinaryMessenger
// .ensureInitialized() both failed identically with "Null check
// operator used on a null value" — that call needs Flutter's
// platform-channel/asset-bundle machinery, and registering the
// isolate for it (via a RootIsolateToken, passed both as a custom
// wrapper class and then as a List<Object>, matching every real-world
// example found) still didn't resolve it.
//
// PART 4 (this revision): sidesteps the problem entirely instead of
// continuing to chase it. tflite_flutter's OWN documentation ships a
// built-in pattern for exactly this situation — sharing an ALREADY-
// LOADED interpreter's raw native memory address across isolates via
// Interpreter.fromAddress(), with NO asset loading or platform-channel
// access needed in the receiving isolate at all. The main isolate's
// already-loaded interpreter (from AudioService.initialise()) is
// reused directly, not reloaded — DetectionService.
// attachInterpreterFromAddress() reconstructs a reference to it.
Future<DetectionResult> _classifyInBackground(List<Object> args) async {
  final interpreterAddress = args[0] as int;
  final buffer = args[1] as Float32List;

  DetectionService.attachInterpreterFromAddress(interpreterAddress);
  return DetectionService.classify(buffer);
}

enum VadStatus {
  idle,
  silence,
  soundDetected,
  distressConfirmed,
}

/// ══════════════════════════════════════════════════════════════
/// AudioService — Real Microphone Recording + Software VAD
/// ══════════════════════════════════════════════════════════════
class AudioService {
  static final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  static bool _initialised = false;
  static bool _isRecording = false;

  // FIX: real-device logs showed repeated
  // "Recording error — Instance of '_RecorderRunningException'"
  // followed by "WAV file not created", specifically around the
  // moments AudioService.stopListening() was called (e.g. from
  // home_screen.dart's disaster-mode toggle, or dispose()) while
  // _recordRealAudio() was still mid-flight in its own
  // startRecorder() -> delay -> stopRecorder() sequence. Both paths
  // were touching the same FlutterSoundRecorder instance with no
  // coordination, so stopListening()'s stopRecorder() call could
  // race against _recordRealAudio()'s own start/stop pair.
  // This lock ensures only one of {a normal capture cycle, an
  // external stopListening() call} can touch the recorder's
  // start/stop transition at any given moment — the other one waits
  // for the in-flight operation to finish cleanly first, instead of
  // colliding with it.
  static Completer<void>? _recorderLock;

  static Future<void> _withRecorderLock(Future<void> Function() action) async {
    // Wait for any in-flight recorder operation to finish first.
    while (_recorderLock != null) {
      await _recorderLock!.future;
    }
    final completer = Completer<void>();
    _recorderLock = completer;
    try {
      await action();
    } finally {
      _recorderLock = null;
      completer.complete();
    }
  }

  // Configuration Constants
  static const int CHUNK_SECONDS = 3;
  static const double RMS_THRESHOLD = 0.008; // Software VAD gate

  // FIX: real-device testing (after fixing the compute-isolate bug
  // that meant real CNN inference had never actually been running)
  // showed the 2-consecutive-hits rule alone wasn't enough — two
  // weak readings just barely above threshold (e.g. 21%, 22%) could
  // confirm an alert exactly as readily as a strong pattern like
  // 95%+31%. This adds a second, independent check: not just THAT
  // two consecutive hits crossed the threshold, but HOW convincingly,
  // on average. A weak pair (avg ~21.5%) now gets filtered as a
  // near-miss; a strong pair like 95%+31% (avg ~63%) still confirms
  // correctly, since one strong reading carrying a moderate second
  // one is a meaningfully different, more concerning pattern than two
  // readings that both barely scraped past the threshold.
  static const double CONFIRMATION_MIN_AVERAGE_CONFIDENCE = 0.35;

  // Callbacks
  static OnDistressDetected? onDistressDetected;
  static OnVadStatus? onVadStatus;

  // Running Analytics
  static final Map<String, int> stats = {
    'totalChunksProcessed': 0,
    'vadTriggers': 0,
    'cnnDistressHits': 0,
  };

  // Consecutive tracking for validation filtering
  static int _consecutiveDistressHits = 0;
  // Tracks the actual confidence value of each hit in the current
  // consecutive streak — added alongside the simple counter so the
  // confirmation logic can also check HOW convincingly the streak
  // crossed the threshold, not just THAT it did twice. See the
  // CONFIRMATION_MIN_AVERAGE_CONFIDENCE gate in _loopDetection() for
  // the real-device finding that motivated this.
  static final List<double> _streakConfidences = [];
  // FIX: real-device testing showed a genuine distress streak (e.g.
  // 39% then 98%, both real hits) getting reset to zero by a single
  // QUIET chunk landing in between (RMS below gate, no CNN even ran)
  // — requiring perfectly back-to-back qualifying chunks with zero
  // tolerance for even one brief pause/breath/gap is unrealistic for
  // real human distress sounds, which are rarely perfectly continuous
  // for 6+ seconds straight. This counter gives ONE chunk of grace:
  // a single non-qualifying chunk (quiet OR classified safe) doesn't
  // immediately wipe the streak — only TWO non-qualifying chunks IN A
  // ROW do, since that's a stronger signal the event has genuinely
  // ended rather than just paused briefly.
  static int _consecutiveMisses = 0;

  // ── Initialize Service ──────────────────────────────────────
  static Future<void> initialise() async {
    if (_initialised) return;

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      print('AudioService: Microphone permission denied');
      return;
    }

    final smsStatus = await Permission.sms.request();
    if (!smsStatus.isGranted) {
      print('AudioService: SMS permission denied');
    }

    final locStatus = await Permission.location.request();
    if (!locStatus.isGranted) {
      print('AudioService: Location permission denied');
    }

    await _recorder.openRecorder();
    // ════════════════════════════════════════════════════════════
  // SILENCE INTERNAL FLUTTER_SOUND LOGGER BRACKETS HERE:
  // ════════════════════════════════════════════════════════════
  _recorder.setLogLevel(Level.nothing);

  await DetectionService.loadModel();
  _initialised = true;
  print('AudioService: Pipeline architecture initialized successfully.');
  }

  // ── Start Pipeline Loop ─────────────────────────────────────
  static Future<void> startListening({
    required OnDistressDetected onDetected,
    required OnVadStatus onStatus,
  }) async {
    if (!_initialised) await initialise();
    if (_isRecording) {
      print('AudioService: Detection pipeline is already looping.');
      return;
    }

    onDistressDetected = onDetected;
    onVadStatus = onStatus;
    _isRecording = true;
    _consecutiveDistressHits = 0;
    _streakConfidences.clear();
    _consecutiveMisses = 0;

    _updateStatus(VadStatus.silence);
    print('AudioService: Synchronous processing loop activated.');
    
    // Spawn background iteration routine safely
    scheduleMicrotask(_loopDetection);
  }

  // ── Stop Pipeline Loop ──────────────────────────────────────
  static Future<void> stopListening() async {
    if (!_isRecording) return;
    _isRecording = false;

    await _withRecorderLock(() async {
      try {
        if (_recorder.isRecording) {
          await _recorder.stopRecorder();
        }
      } catch (e) {
        print('AudioService: Error closing recorder hardware binding — $e');
      }
    });

    _updateStatus(VadStatus.idle);
    _printStats();
    print('AudioService: Synchronous processing loop terminated.');
  }

  // ── Core Sync Engine Loop ───────────────────────────────────
  static Future<void> _loopDetection() async {
    while (_isRecording) {
      final startTime = DateTime.now();
      _updateStatus(VadStatus.silence);

      // 1. Perform isolated physical capture chunk
      final buffer = await _recordRealAudio();
      if (buffer == null || buffer.isEmpty) {
        if (!_isRecording) break;
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      stats['totalChunksProcessed'] = stats['totalChunksProcessed']! + 1;

      // 2. Extract software RMS energy metrics
      final currentRms = _calculateRMS(buffer);
      print('AudioService: RMS = ${currentRms.toStringAsFixed(5)} | threshold = $RMS_THRESHOLD | samples = ${buffer.length}');

      if (currentRms > RMS_THRESHOLD) {
        print('AudioService: Sound detected! RMS=${currentRms.toString()} — running CNN...');
        _updateStatus(VadStatus.soundDetected);
        stats['vadTriggers'] = stats['vadTriggers']! + 1;

        // 3. Offload heavy spectrogram and inference parsing to heavy worker isolate
        // No RootIsolateToken or BackgroundIsolateBinaryMessenger
        // needed anymore — see _classifyInBackground above for why.
        // interpreterAddress reads the MAIN isolate's already-loaded
        // model (loaded via AudioService.initialise() at startup);
        // this read happens here on the main isolate, before the
        // compute() call, so it's always valid.
        final interpreterAddress = DetectionService.interpreterAddress;
        final DetectionResult result;
        if (interpreterAddress == null) {
          print('AudioService: model not loaded in main isolate yet — '
                'using RMS-based simulation for this cycle.');
          result = DetectionService.simulateDetection(
              probability: _calculateRMS(buffer) * 2.0);
        } else {
          result = await compute(
            _classifyInBackground,
            <Object>[interpreterAddress, buffer],
          );
        }
        print('AudioService: CNN → ${result.confidencePercent} (${result.soundType}) isDistress=${result.isDistress}');

        if (result.isDistress) {
          // A qualifying hit — reset miss counter, add to streak
          _consecutiveMisses = 0;
          _consecutiveDistressHits++;
          _streakConfidences.add(result.confidence);
          print('AudioService: High-risk anomaly tracked! Run sequence count = $_consecutiveDistressHits/2');

          if (_consecutiveDistressHits >= 2) {
            // Check HOW convincingly the streak crossed threshold,
            // on average — not just THAT it crossed twice.
            final avgConfidence =
                _streakConfidences.reduce((a, b) => a + b) / _streakConfidences.length;
            print('AudioService: Streak average confidence = '
                  '${(avgConfidence * 100).toStringAsFixed(0)}% '
                  '(gate = ${(CONFIRMATION_MIN_AVERAGE_CONFIDENCE * 100).toStringAsFixed(0)}%)');

            if (avgConfidence >= CONFIRMATION_MIN_AVERAGE_CONFIDENCE) {
              stats['cnnDistressHits'] = stats['cnnDistressHits']! + 1;
              _consecutiveDistressHits = 0;
              _streakConfidences.clear();
              _consecutiveMisses = 0;

              _updateStatus(VadStatus.distressConfirmed);
              onDistressDetected?.call(result);

              print('AudioService: Monitoring context sleeping for 60s window to avoid flooding channels...');
              await Future.delayed(const Duration(seconds: 60));
              print('AudioService: Re-activating loop cycles...');
              continue;
            } else {
              // Count reached 2 but average too weak — near-miss.
              print('AudioService: Near-miss filtered — streak crossed '
                    'threshold twice but average confidence too low. '
                    'Resetting streak.');
              _consecutiveDistressHits = 0;
              _streakConfidences.clear();
              _consecutiveMisses = 0;
            }
          }
        } else {
          // Non-qualifying chunk (safe classification or quiet).
          // FIX: don't immediately wipe the streak — give ONE chunk
          // of grace. Real distress sounds aren't perfectly
          // continuous: a person breathes, pauses between sobs, or
          // a single 3-second window catches a momentary quiet
          // between cries. A SINGLE miss increments the miss counter
          // but leaves the existing hit streak intact. Only TWO
          // misses IN A ROW fully reset, since that's a much stronger
          // signal the event has genuinely ended.
          _consecutiveMisses++;
          if (_consecutiveMisses >= 2) {
            print('AudioService: Streak reset — 2 consecutive non-qualifying chunks.');
            _consecutiveDistressHits = 0;
            _streakConfidences.clear();
            _consecutiveMisses = 0;
          } else {
            print('AudioService: Grace-period miss — streak preserved '
                  '(miss $_consecutiveMisses/2, hits still = '
                  '$_consecutiveDistressHits/2).');
          }
        }
      } else {
        // RMS below threshold — counts as a miss, same grace logic
        _consecutiveMisses++;
        if (_consecutiveMisses >= 2) {
          _consecutiveDistressHits = 0;
          _streakConfidences.clear();
          _consecutiveMisses = 0;
        } else {
          print('AudioService: Grace-period quiet — streak preserved '
                '(miss $_consecutiveMisses/2, hits still = '
                '$_consecutiveDistressHits/2).');
        }
      }

      // Dynamic timeline padding tracking overhead configurations
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final expectedMinDuration = (CHUNK_SECONDS * 1000) + 300; 
      if (elapsed < expectedMinDuration) {
        final filler = expectedMinDuration - elapsed;
        await Future.delayed(Duration(milliseconds: filler));
      }
    }
  }

  // ── Native Audio Capture Handle ─────────────────────────────
  static Future<Float32List?> _recordRealAudio() async {
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/resqnet_chunk.wav';
    bool recordedSuccessfully = false;

    try {
      await _withRecorderLock(() async {
        // 1. Clear hanging native calls from previous state frames cleanly
        if (_recorder.isRecording) {
          print('AudioService: Catch — Recorder active during setup, forcing halt...');
          await _recorder.stopRecorder();
          await Future.delayed(const Duration(milliseconds: 300));
        }

        final file = File(filePath);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {}
        }

        // Native Hardware Cushion: Give Android time to switch system states
        await Future.delayed(const Duration(milliseconds: 100));

        // If stopListening() flipped _isRecording off while we were
        // waiting for the lock above, don't start a new recording —
        // there'd be nothing to read it back out for, and starting
        // one here would just need to be torn down immediately.
        if (!_isRecording) return;

        // Record PCM16 WAV at exactly 22050Hz to match Python CNN
        // Mel-Spectrogram specs
        await _recorder.startRecorder(
          toFile: filePath,
          codec: Codec.pcm16WAV,
          sampleRate: 22050,
          numChannels: 1,
        );

        // Block execution sequence cleanly for the required duration windows
        await Future.delayed(Duration(seconds: CHUNK_SECONDS));

        await _recorder.stopRecorder();

        // Native Hardware Cushion: Let the file descriptor stream
        // finish flushing cache to flash storage
        await Future.delayed(const Duration(milliseconds: 200));

        recordedSuccessfully = true;
      });

      if (!recordedSuccessfully) {
        return null;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        print('AudioService: WAV file not created');
        return null;
      }

      final bytes = await file.readAsBytes();
      print('AudioService: WAV file size = ${bytes.length} bytes');

      final float32 = _wavBytesToFloat32(bytes);
      print('AudioService: Audio samples = ${float32.length}');

      return float32;

    } catch (e) {
      print('AudioService: Recording error — $e');
      try {
        if (_recorder.isRecording) {
          await _recorder.stopRecorder();
        }
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {}
      return null;
    }
  }

  // ── Math & Parse Conversions ────────────────────────────────
  static double _calculateRMS(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    double sumOfSquares = 0.0;
    for (int i = 0; i < samples.length; i++) {
      sumOfSquares += samples[i] * samples[i];
    }
    return sqrt(sumOfSquares / samples.length);
  }

  static Float32List _wavBytesToFloat32(Uint8List wavBytes) {
    // Skip 44 bytes standard Canonical RIFF header definitions to parse raw sub-chunk values
    const int headerOffset = 44;
    if (wavBytes.length <= headerOffset) return Float32List(0);

    final pcmData = Uint8List.sublistView(wavBytes, headerOffset);
    final int sampleCount = pcmData.length ~/ 2;
    final float32List = Float32List(sampleCount);
    final int8View = ByteData.sublistView(pcmData);

    for (int i = 0; i < sampleCount; i++) {
      // Parse multi-byte numbers systematically in signed 16-bit little-endian binary setups
      final int sample16 = int8View.getInt16(i * 2, Endian.little);
      float32List[i] = sample16 / 32768.0;
    }
    return float32List;
  }

  // ── Helpers ────────────────────────────────────────────────
  static void _updateStatus(VadStatus status) => onVadStatus?.call(status);

  static void _printStats() {
    print('\n${'='*50}');
    print('  AudioService VAD Statistics');
    print('='*50);
    stats.forEach((k, v) => print('  ${k.padRight(20)}: $v'));
    print('='*50);
  }

  static bool get isRecording => _isRecording;

  static Future<void> dispose() async {
    await stopListening();
    try {
      await _recorder.closeRecorder();
    } catch (_) {}
  }
}