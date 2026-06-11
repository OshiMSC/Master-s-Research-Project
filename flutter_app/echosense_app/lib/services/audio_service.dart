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
Future<DetectionResult> _classifyInBackground(Float32List buffer) async {
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

  // Configuration Constants
  static const int CHUNK_SECONDS = 3;
  static const double RMS_THRESHOLD = 0.008; // Software VAD gate

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

    _updateStatus(VadStatus.silence);
    print('AudioService: Synchronous processing loop activated.');
    
    // Spawn background iteration routine safely
    scheduleMicrotask(_loopDetection);
  }

  // ── Stop Pipeline Loop ──────────────────────────────────────
  static Future<void> stopListening() async {
    if (!_isRecording) return;
    _isRecording = false;
    
    try {
      if (_recorder.isRecording) {
        await _recorder.stopRecorder();
      }
    } catch (e) {
      print('AudioService: Error closing recorder hardware binding — $e');
    }

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
        final result = await compute(_classifyInBackground, buffer);
        print('AudioService: CNN → ${result.confidencePercent} (${result.soundType}) isDistress=${result.isDistress}');

        if (result.isDistress) {
          _consecutiveDistressHits++;
          print('AudioService: High-risk anomaly tracked! Run sequence count = $_consecutiveDistressHits/2');

          if (_consecutiveDistressHits >= 2) {
            stats['cnnDistressHits'] = stats['cnnDistressHits']! + 1;
            _consecutiveDistressHits = 0; // Clear accumulator counter

            _updateStatus(VadStatus.distressConfirmed);
            
            // Forward verified structural anomaly to the UI contextual layer thread
            onDistressDetected?.call(result);

            // Halt current monitoring iteration thread until cool-down delay yields safely
            print('AudioService: Monitoring context sleeping for 60s window to avoid flooding channels...');
            await Future.delayed(const Duration(seconds: 60));
            print('AudioService: Re-activating loop cycles...');
            continue;
          }
        } else {
          // Break continuous stream match sequence if safe baseline frames reset
          _consecutiveDistressHits = 0;
        }
      } else {
        // Break sequence if space slips beneath noise floor thresholds
        _consecutiveDistressHits = 0;
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
    try {
      // 1. Clear hanging native calls from previous state frames cleanly
      if (_recorder.isRecording) {
        print('AudioService: Catch — Recorder active during setup, forcing halt...');
        await _recorder.stopRecorder();
        await Future.delayed(const Duration(milliseconds: 300));
      }

      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/resqnet_chunk.wav';

      final file = File(filePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }

      // Native Hardware Cushion: Give Android time to switch system states
      await Future.delayed(const Duration(milliseconds: 100));

      // Record PCM16 WAV at exactly 22050Hz to match Python CNN Mel-Spectrogram specs
      await _recorder.startRecorder(
        toFile: filePath,
        codec: Codec.pcm16WAV,
        sampleRate: 22050,
        numChannels: 1,
      );

      // Block execution sequence cleanly for the required duration windows
      await Future.delayed(Duration(seconds: CHUNK_SECONDS));

      await _recorder.stopRecorder();
      
      // Native Hardware Cushion: Let the file descriptor stream finish flushing cache to flash storage
      await Future.delayed(const Duration(milliseconds: 200));

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
        await _recorder.stopRecorder(); 
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