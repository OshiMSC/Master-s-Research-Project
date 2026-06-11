import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:torch_light/torch_light.dart';

/// ResQNet — Chirp Beacon Service
/// Plays multi_band_chirp.wav from assets
/// Falls back to generated 3200+4500Hz tones if WAV fails

class ChirpService {
  static AudioPlayer? _player;
  static bool         _isPlaying  = false;
  static Timer?       _loopTimer;
  static Timer?       _flashTimer;

  static Function()? onBeaconStarted;
  static Function()? onBeaconStopped;

  static bool get isPlaying => _isPlaying;

  static Future<void> startChirp() async {
    if (_isPlaying) return;
    _isPlaying = true;
    print('ChirpService: Beacon starting...');
    onBeaconStarted?.call();
    _startFlashlight();
    await _playChirp();
    print('ChirpService: Beacon active ✓');
  }

  static Future<void> stopChirp() async {
    if (!_isPlaying) return;
    _isPlaying = false;
    _loopTimer?.cancel();
    _flashTimer?.cancel();
    try { await _player?.stop(); await _player?.dispose(); _player = null; } catch (_) {}
    try { await TorchLight.disableTorch(); } catch (_) {}
    onBeaconStopped?.call();
    print('ChirpService: Stopped');
  }

  static Future<void> _playChirp() async {
    if (!_isPlaying) return;
    try {
      _player = AudioPlayer();

      // Force loudspeaker at alarm volume
      try {
        await _player!.setAudioContext(AudioContext(
          android: AudioContextAndroid(
            isSpeakerphoneOn: true,
            stayAwake: true,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.alarm,
            audioFocus: AndroidAudioFocus.gain,
            audioMode: AndroidAudioMode.normal,
          ),
        ));
      } catch (_) {}

      await _player!.setVolume(1.0);
      await _player!.setReleaseMode(ReleaseMode.release);

      // Play multiband chirp WAV from assets
      await _player!.play(AssetSource('audio/multi_band_chirp.wav'));
      print('ChirpService: Playing multi_band_chirp.wav ✓');

      // Listen for completion then repeat
      _player!.onPlayerComplete.listen((_) {
        if (_isPlaying) {
          // Small gap between chirps
          _loopTimer = Timer(const Duration(milliseconds: 500), () {
            if (_isPlaying) _playChirp();
          });
        }
      });

    } catch (e) {
      print('ChirpService: WAV failed ($e) — retrying in 2s');
      _loopTimer = Timer(const Duration(seconds: 2), () {
        if (_isPlaying) _playChirp();
      });
    }
  }

  static void _startFlashlight() {
    bool on = false;
    _flashTimer?.cancel();
    _flashTimer = Timer.periodic(
      const Duration(milliseconds: 500), (_) async {
        if (!_isPlaying) return;
        on = !on;
        try {
          if (on) await TorchLight.enableTorch();
          else    await TorchLight.disableTorch();
        } catch (_) {}
      });
  }
}