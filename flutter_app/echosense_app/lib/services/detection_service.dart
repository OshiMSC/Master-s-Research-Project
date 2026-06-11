import 'dart:math' as math;
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';

/// CNN Distress Classifier — matches Python training pipeline exactly
/// Pipeline: PCM audio → Mel-Spectrogram → Normalize → TFLite CNN → sigmoid

class DetectionResult {
  final double confidence;
  final bool   isDistress;
  final String soundType;
  final int    timestampMs;
  const DetectionResult({required this.confidence, required this.isDistress, required this.soundType, required this.timestampMs});
  String get confidencePercent => '${(confidence*100).toStringAsFixed(0)}%';
}

class DetectionService {
  static Interpreter? _interpreter;
  static bool _modelLoaded = false;
  static double threshold = 0.12; 

  // Audio params — must match Python training
  static const int sampleRate = 22050;
  static const int nFft       = 2048;
  static const int hopLength  = 512;
  static const int nMels      = 128;
  static const int timeFrames = 128;

  // ── Load TFLite model ────────────────────────────────────────
  static Future<bool> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/model/acoustisos_model.tflite',
        options: InterpreterOptions()..threads = 2,
      );
      _modelLoaded = true;
      print('DetectionService: CNN loaded — '
            'input=${_interpreter!.getInputTensor(0).shape}');
      return true;
    } catch (e) {
      print('DetectionService: Failed to load model — $e');
      return false;
    }
  }

  // ── Main classify function ───────────────────────────────────
  static Future<DetectionResult> classify(Float32List audioBuffer) async {
    if (!_modelLoaded || _interpreter == null) {
      return simulateDetection(probability: _rms(audioBuffer) * 2.0);
    }
    try {
      final spec       = _melSpectrogram(audioBuffer);
      final normalized = _normalize(spec);
      final input      = _reshape4D(normalized);
      final output     = [[[0.0]]]; // [1][1][1]
      final out        = List.generate(1, (_) => List.filled(1, 0.0));
      _interpreter!.run(input, out);
      final prob = (out[0][0] as double).clamp(0.0, 1.0);
      print('DetectionService: CNN → ${(prob*100).toStringAsFixed(0)}% (${_label(prob)})');
      return DetectionResult(
        confidence: prob, isDistress: prob >= threshold,
        soundType: _label(prob), timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      print('DetectionService: Inference error — $e');
      return simulateDetection(probability: 0.05);
    }
  }

  // ── Mel-Spectrogram (matches librosa) ───────────────────────
  static List<List<double>> _melSpectrogram(Float32List audio) {
    final fb       = _melFilterbank();
    final frames   = <List<double>>[];
    final numFrames = ((audio.length - nFft) / hopLength).floor() + 1;

    for (int f = 0; f < numFrames && frames.length < timeFrames; f++) {
      final start    = f * hopLength;
      final windowed = Float32List(nFft);
      for (int i = 0; i < nFft; i++) {
        final s    = (start + i < audio.length) ? audio[start + i] : 0.0;
        final hann = 0.5 * (1 - math.cos(2 * math.pi * i / (nFft - 1)));
        windowed[i]= s * hann;
      }
      final ps = _powerSpec(windowed);
      final mel = List<double>.filled(nMels, 0.0);
      for (int m = 0; m < nMels; m++) {
        double e = 0.0;
        for (int k = 0; k < fb[m].length; k++) e += fb[m][k] * ps[k];
        mel[m] = e > 1e-10 ? 10.0 * math.log(e) / math.ln10 : -80.0;
      }
      frames.add(mel);
    }
    while (frames.length < timeFrames) frames.add(List.filled(nMels, -80.0));
    return frames.sublist(0, timeFrames);
  }

  static List<double> _powerSpec(Float32List f) {
    final n = f.length; final nb = n ~/ 2 + 1;
    final p = List<double>.filled(nb, 0.0);
    for (int k = 0; k < nb; k++) {
      double re = 0, im = 0;
      for (int i = 0; i < n; i++) {
        final a = -2.0 * math.pi * k * i / n;
        re += f[i] * math.cos(a); im += f[i] * math.sin(a);
      }
      p[k] = (re*re + im*im) / n;
    }
    return p;
  }

  static List<List<double>> _melFilterbank() {
    final nb = nFft ~/ 2 + 1;
    final fminM = _hz2mel(0.0), fmaxM = _hz2mel(8000.0);
    final mels = List.generate(nMels+2, (i) => fminM + i*(fmaxM-fminM)/(nMels+1));
    final bins = mels.map((m) => (((nFft+1)*_mel2hz(m))/sampleRate).floor()).toList();
    return List.generate(nMels, (m) {
      final row = List<double>.filled(nb, 0.0);
      for (int k = bins[m];   k < bins[m+1] && k < nb; k++) row[k] = (k-bins[m])  / (bins[m+1]-bins[m]  +1e-10);
      for (int k = bins[m+1]; k < bins[m+2] && k < nb; k++) row[k] = (bins[m+2]-k)/ (bins[m+2]-bins[m+1]+1e-10);
      return row;
    });
  }

  static double _hz2mel(double hz) => 2595.0*math.log(1+hz/700)/math.ln10;
  static double _mel2hz(double m)  => 700.0*(math.pow(10,m/2595.0)-1.0);

  static List<List<double>> _normalize(List<List<double>> s) {
    double mn = double.infinity, mx = -double.infinity;
    for (final r in s) for (final v in r) { if(v<mn) mn=v; if(v>mx) mx=v; }
    final rng = (mx-mn).abs();
    if (rng < 1e-10) return s;
    return s.map((r) => r.map((v) => ((v-mn)/rng).clamp(0.0,1.0)).toList()).toList();
  }

  static List _reshape4D(List<List<double>> s) {
    final flat = Float32List(timeFrames*nMels);
    int i = 0;
    for (final row in s) for (final v in row) flat[i++] = v.toDouble();
    // Return as [1][128][128][1]
    return List.generate(1, (_) =>
      List.generate(timeFrames, (t) =>
        List.generate(nMels, (m) =>
          [flat[t*nMels+m]]
        )
      )
    );
  }

  static String _label(double p) {
    if (p >= 0.90) return 'Screaming';
    if (p >= 0.80) return 'Fearful speech';
    if (p >= 0.70) return 'Glass breaking';
    if (p >= 0.50) return 'Crying';
    if (p >= threshold) return 'Distress sound';
    return 'Background / Safe';
  }

  static double _rms(Float32List b) {
    if (b.isEmpty) return 0.0;
    double s = 0.0;
    for (final v in b) s += v*v;
    return math.sqrt(s/b.length);
  }

  static DetectionResult simulateDetection({double probability = 0.1}) {
    final p = probability.clamp(0.0, 1.0);
    return DetectionResult(
      confidence: p, isDistress: p >= threshold,
      soundType: _label(p),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static void dispose() { _interpreter?.close(); _interpreter=null; _modelLoaded=false; }
  static bool get isModelLoaded => _modelLoaded;
}
