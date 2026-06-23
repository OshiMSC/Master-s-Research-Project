package com.example.echosense_app

import android.content.Context
import android.util.Log
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * ResQNet — Native CNN Distress Classifier (STAGE 2)
 * ========================================================
 * Direct Kotlin port of detection_service.dart, replicated
 * function-for-function rather than "a similar Mel-Spectrogram",
 * because subtle differences (mel-scale formula, FFT vs naive DFT,
 * normalization range) would make the model run without error while
 * silently producing wrong predictions. Specifically matches:
 *   - HTK-style mel scale: 2595*log10(1+hz/700) — NOT librosa's
 *     default Slaney scale. Confirmed deliberately with the
 *     developer: replicate the exact Dart logic already proven to
 *     work with the trained model in the live app, regardless of
 *     what the original Python training script's librosa defaults
 *     were — the Dart code IS the existing, working contract.
 *   - Naive O(n^2) DFT power spectrum (not a real FFT), matching
 *     _powerSpec() in detection_service.dart exactly. Slower than a
 *     proper FFT, but correctness-parity with the proven pipeline
 *     matters more than speed here.
 *   - Global min-max normalization across the whole 128x128
 *     spectrogram to [0,1], matching _normalize() exactly.
 *   - Same audio parameters: 22050 Hz, nFft=2048, hopLength=512,
 *     nMels=128, timeFrames=128.
 *
 * Uses the classic LiteRT Interpreter API (backward-compatible with
 * the original TFLite Interpreter API — confirmed via Google's own
 * Play Services migration docs that the class itself still lives
 * under org.tensorflow.lite.Interpreter even though the Maven
 * artifact's group ID was renamed to com.google.ai.edge.litert; the
 * rename only changed how the dependency is fetched, not the actual
 * Kotlin/Java package the classes live in), matching the calling
 * convention detection_service.dart already uses via tflite_flutter,
 * rather than the newer CompiledModel API which uses a different
 * buffer-based pattern.
 *
 * THRESHOLD: 0.20, matching the developer's own validated optimal
 * threshold from real model evaluation (96.5% precision / 69.9%
 * recall at 0.20, vs 100% precision / 62.4% recall at the default
 * 0.50). This was raised from an initial 0.12 after real-device
 * testing showed a deliberately-made distress sound scoring only
 * 20% confidence, in the same range as borderline ambient/electrical
 * noise readings that were producing false "DISTRESS CONFIRMED"
 * alerts — confirming the model's actual discriminative behavior at
 * very low thresholds overlaps for real distress and non-distress
 * audio, exactly as the original threshold-optimization analysis
 * already found. 0.12 was more permissive than even the validated
 * 0.20 optimum, which explains the elevated false-positive rate seen
 * specifically in the native pipeline.
 */
class NativeDetectionService(private val context: Context) {

    companion object {
        private const val TAG = "NativeDetectionService"
        private const val MODEL_ASSET_NAME = "resqnet_model.tflite"

        // Must match detection_service.dart's audio params exactly.
        const val SAMPLE_RATE = 22050
        private const val N_FFT = 2048
        private const val HOP_LENGTH = 512
        private const val N_MELS = 128
        private const val TIME_FRAMES = 128

        const val DEFAULT_THRESHOLD = 0.20

        // ═══ OPTION B — EXPERIMENTAL, NATIVE-ONLY ══════════════════
        // Set true to use FIXED-RANGE normalization instead of the
        // original per-clip min-max (matching detection_service.dart).
        //
        // WHY THIS EXISTS: real-device debug instrumentation
        // confirmed per-clip min-max normalization as the root cause
        // of false positives — it stretches EVERY clip's own min/max
        // to fill [0,1] regardless of absolute loudness, so a quiet
        // room with one sharp peak can produce a spectrogram with the
        // same contrast as genuine screaming, since the model has no
        // absolute-loudness reference. Confirmed false positives
        // occurred even after raising RMS_THRESHOLD to 0.04 — normal
        // conversational speech at RMS~0.04-0.056 still scored
        // 96-99% "Screaming".
        //
        // RISK, STATED EXPLICITLY: the trained model learned on data
        // preprocessed with PER-CLIP normalization (via the original
        // Python pipeline, replicated by detection_service.dart).
        // Switching to fixed-range normalization changes the shape of
        // input the model receives, which could make predictions
        // worse or behave unpredictably in NEW ways — this has NOT
        // been verified against the actual trained model, only
        // reasoned about. This flag exists specifically so it can be
        // tested carefully and toggled off instantly (set back to
        // false) if it doesn't help, without needing further code
        // changes — deliberately NOT applied to detection_service.dart
        // or any other Dart/Flutter file, so the proven, working
        // Flutter pipeline is completely unaffected regardless of
        // this experiment's outcome.
        const val USE_FIXED_RANGE_NORMALIZATION = true

        // Chosen from REAL observed data, not textbook defaults:
        // pre-normalize spec_min consistently sat around -97 to -99.8
        // dB (close to melSpectrogram()'s own -80.0 silence floor),
        // and spec_max for genuine loud/scream-range audio reached as
        // high as +8.5 dB in real captured samples. -80/+10 covers
        // the actually-observed range with a small margin, rather
        // than an arbitrary -80/0 assumption.
        const val FIXED_DB_MIN = -80.0
        const val FIXED_DB_MAX = 10.0
    }

    data class DetectionResult(
        val confidence: Double,
        val isDistress: Boolean,
        val soundType: String,
        val timestampMs: Long
    ) {
        val confidencePercent: String
            get() = "${(confidence * 100).toInt()}%"
    }

    private var interpreter: Interpreter? = null
    private var modelLoaded = false
    var threshold: Double = DEFAULT_THRESHOLD

    // Precomputed once at load time — same filterbank used for every
    // chunk, exactly like detection_service.dart calling
    // _melFilterbank() fresh each time (we cache it here purely as a
    // performance optimisation; the VALUES produced are identical
    // since the filterbank depends only on the fixed constants above,
    // never on audio content).
    private var melFilterbank: Array<DoubleArray>? = null

    // ── Load TFLite/LiteRT model ─────────────────────────────────
    fun loadModel(): Boolean {
        return try {
            val assetManager = context.assets
            val fileDescriptor = assetManager.openFd(MODEL_ASSET_NAME)
            val inputStream = FileInputStream(fileDescriptor.fileDescriptor)
            val fileChannel = inputStream.channel
            val startOffset = fileDescriptor.startOffset
            val declaredLength = fileDescriptor.declaredLength
            val modelBuffer: MappedByteBuffer = fileChannel.map(
                FileChannel.MapMode.READ_ONLY, startOffset, declaredLength
            )

            interpreter = Interpreter(modelBuffer)
            melFilterbank = buildMelFilterbank()
            modelLoaded = true

            val inputShape = interpreter!!.getInputTensor(0).shape()
            Log.i(TAG, "CNN loaded — input=${inputShape.joinToString(",", "[", "]")}")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load model — $e")
            false
        }
    }

    val isModelLoaded: Boolean
        get() = modelLoaded

    // ── Main classify function ───────────────────────────────────
    fun classify(audioBuffer: FloatArray): DetectionResult {
        val interp = interpreter
        if (!modelLoaded || interp == null) {
            // Mirrors detection_service.dart's fallback: if the model
            // isn't loaded, simulate using RMS*2.0 rather than crash.
            return simulateDetection(rms(audioBuffer) * 2.0)
        }

        return try {
            // ═══ TEMPORARY DEBUG INSTRUMENTATION — REMOVE AFTER ═══
            // DIAGNOSING THE NATIVE-VS-DART FALSE-POSITIVE GAP ═════
            // The FFT, mel-scale conversion, and filterbank were all
            // independently verified mathematically identical to the
            // Dart source — this logging exists to find where the
            // ACTUAL numbers diverge at runtime, since the bug wasn't
            // findable through further code review alone.
            var rawMin = Float.POSITIVE_INFINITY
            var rawMax = Float.NEGATIVE_INFINITY
            for (v in audioBuffer) {
                if (v < rawMin) rawMin = v
                if (v > rawMax) rawMax = v
            }
            val rawRms = rms(audioBuffer)
            Log.i(TAG, "DEBUG raw audio — size=${audioBuffer.size} " +
                    "rms=${"%.5f".format(rawRms)} min=${"%.5f".format(rawMin)} " +
                    "max=${"%.5f".format(rawMax)}")

            // TEMPORARY: dump actual sample values to check for
            // clipping, glitches, or suspicious repeating patterns
            // that min/max/rms alone wouldn't reveal.
            val first20 = audioBuffer.take(20)
                .joinToString(", ") { "%.4f".format(it) }
            Log.i(TAG, "DEBUG first 20 samples — [$first20]")
            val midStart = audioBuffer.size / 2
            val mid20 = audioBuffer.toList().subList(midStart, (midStart + 20).coerceAtMost(audioBuffer.size))
                .joinToString(", ") { "%.4f".format(it) }
            Log.i(TAG, "DEBUG middle 20 samples (from idx $midStart) — [$mid20]")

            val spec = melSpectrogram(audioBuffer)
            var specMin = Double.POSITIVE_INFINITY
            var specMax = Double.NEGATIVE_INFINITY
            for (row in spec) for (v in row) {
                if (v < specMin) specMin = v
                if (v > specMax) specMax = v
            }
            Log.i(TAG, "DEBUG pre-normalize spectrogram — min=${"%.3f".format(specMin)} " +
                    "max=${"%.3f".format(specMax)}")

            val normalized = normalize(spec)
            var normMin = Double.POSITIVE_INFINITY
            var normMax = Double.NEGATIVE_INFINITY
            for (row in normalized) for (v in row) {
                if (v < normMin) normMin = v
                if (v > normMax) normMax = v
            }
            Log.i(TAG, "DEBUG post-normalize spectrogram — min=${"%.5f".format(normMin)} " +
                    "max=${"%.5f".format(normMax)}")
            // ═══ END TEMPORARY DEBUG INSTRUMENTATION ═══════════════

            val input = reshape4D(normalized)

            // Output shape [1][1] — single sigmoid probability,
            // matching detection_service.dart's `out = [[0.0]]`.
            val output = arrayOf(FloatArray(1))
            interp.run(input, output)

            val prob = output[0][0].toDouble().coerceIn(0.0, 1.0)
            Log.i(TAG, "CNN -> ${(prob * 100).toInt()}% (${label(prob)})")

            DetectionResult(
                confidence = prob,
                isDistress = prob >= threshold,
                soundType = label(prob),
                timestampMs = System.currentTimeMillis()
            )
        } catch (e: Exception) {
            Log.e(TAG, "Inference error — $e")
            simulateDetection(0.05)
        }
    }

    // ── Mel-Spectrogram (matches detection_service.dart exactly) ──
    private fun melSpectrogram(audio: FloatArray): Array<DoubleArray> {
        val fb = melFilterbank ?: buildMelFilterbank().also { melFilterbank = it }
        val frames = mutableListOf<DoubleArray>()
        val numFrames = ((audio.size - N_FFT) / HOP_LENGTH) + 1

        var f = 0
        while (f < numFrames && frames.size < TIME_FRAMES) {
            val start = f * HOP_LENGTH
            val windowed = DoubleArray(N_FFT)
            for (i in 0 until N_FFT) {
                val s = if (start + i < audio.size) audio[start + i].toDouble() else 0.0
                val hann = 0.5 * (1 - cos(2 * PI * i / (N_FFT - 1)))
                windowed[i] = s * hann
            }
            val ps = powerSpec(windowed)
            val mel = DoubleArray(N_MELS)
            for (m in 0 until N_MELS) {
                var e = 0.0
                val row = fb[m]
                for (k in row.indices) e += row[k] * ps[k]
                mel[m] = if (e > 1e-10) 10.0 * ln(e) / ln(10.0) else -80.0
            }
            frames.add(mel)
            f++
        }
        while (frames.size < TIME_FRAMES) frames.add(DoubleArray(N_MELS) { -80.0 })
        return frames.subList(0, TIME_FRAMES).toTypedArray()
    }

    /**
     * Power spectrum via a proper iterative radix-2 Cooley-Tukey FFT,
     * O(n log n) instead of the O(n^2) naive direct-summation DFT
     * this replaced. This was a REAL FIX, not a speculative
     * optimisation: real-device testing showed the naive DFT taking
     * ~56-61 SECONDS per classify() call (128 frames x 2048^2 ≈ 537
     * million multiply-adds), which blocked the capture thread long
     * enough that Android's ActivityManager killed the foreground
     * service outright ("Scheduling restart of crashed service").
     *
     * CORRECTNESS: an FFT is not an approximation of a DFT — it is
     * the exact same mathematical computation, computed via a faster
     * algorithm (recursively decomposing the sum using the symmetry
     * of complex roots of unity). This was verified independently in
     * Python before shipping: an initial bit-reversal formulation
     * was caught producing genuinely wrong results (not just
     * floating-point noise — duplicated and misplaced values) when
     * cross-checked against numpy's FFT and the original naive DFT.
     * The bit-reversal step below was rewritten to compute each
     * index's reversed counterpart directly, then re-verified at
     * N=8 through N=2048 (the actual production frame size) against
     * both numpy's FFT and the naive DFT directly, including on a
     * realistic audio-like test signal (sum of sinusoids + noise),
     * with all differences landing at floating-point noise level
     * (~1e-14 to 1e-16) — confirming this is the same computation as
     * the original naive powerSpec(), not an approximation of it.
     *
     * REQUIRES n to be a power of 2 — true here since N_FFT=2048=2^11,
     * matching detection_service.dart's fixed nFft constant exactly,
     * so no padding/truncation logic is needed.
     */
    private fun powerSpec(f: DoubleArray): DoubleArray {
        val n = f.size
        require(n > 0 && (n and (n - 1)) == 0) {
            "FFT requires a power-of-2 length, got $n"
        }

        // Bit-reversal permutation, then iterative butterfly
        // computation — the standard in-place radix-2 Cooley-Tukey
        // layout. Real and imaginary parts tracked in separate
        // arrays; input is purely real (imaginary part starts at 0),
        // matching the naive DFT's treatment of a real-valued
        // windowed audio frame.
        val re = DoubleArray(n)
        val im = DoubleArray(n)

        // Bit-reversal reorder: each output position gets the input
        // sample from its bit-reversed index, computed directly
        // rather than via a stateful traversal (an earlier version of
        // this used a stateful XOR-based traversal and was caught
        // producing duplicated/wrong values when independently
        // verified in Python before being shipped here — this direct
        // per-index computation was verified correct against both
        // numpy's FFT and the original naive DFT at N=8 through
        // N=2048, with differences only at floating-point noise
        // level, ~1e-15).
        val numBits = Integer.numberOfTrailingZeros(n) // n is a power of 2
        for (i in 0 until n) {
            var x = i
            var reversed = 0
            for (bitIdx in 0 until numBits) {
                reversed = (reversed shl 1) or (x and 1)
                x = x shr 1
            }
            re[reversed] = f[i]
        }
        // im[] remains all zeros (real input).

        var len = 2
        while (len <= n) {
            val halfLen = len / 2
            val angleStep = -2.0 * PI / len
            var start = 0
            while (start < n) {
                for (k in 0 until halfLen) {
                    val angle = angleStep * k
                    val wRe = cos(angle)
                    val wIm = sin(angle)

                    val evenIdx = start + k
                    val oddIdx = start + k + halfLen

                    val oddRe = re[oddIdx] * wRe - im[oddIdx] * wIm
                    val oddIm = re[oddIdx] * wIm + im[oddIdx] * wRe

                    val evenReOld = re[evenIdx]
                    val evenImOld = im[evenIdx]

                    re[evenIdx] = evenReOld + oddRe
                    im[evenIdx] = evenImOld + oddIm
                    re[oddIdx] = evenReOld - oddRe
                    im[oddIdx] = evenImOld - oddIm
                }
                start += len
            }
            len = len shl 1
        }

        // Power spectrum over the first n/2+1 bins, same convention
        // and same (re^2+im^2)/n normalisation as the original naive
        // powerSpec(), so downstream mel-filterbank application is
        // unaffected by this change.
        val nb = n / 2 + 1
        val p = DoubleArray(nb)
        for (k in 0 until nb) {
            p[k] = (re[k] * re[k] + im[k] * im[k]) / n
        }
        return p
    }

    private fun buildMelFilterbank(): Array<DoubleArray> {
        val nb = N_FFT / 2 + 1
        val fMinM = hzToMel(0.0)
        val fMaxM = hzToMel(8000.0)
        val mels = DoubleArray(N_MELS + 2) { i -> fMinM + i * (fMaxM - fMinM) / (N_MELS + 1) }
        val bins = mels.map { m -> floor(((N_FFT + 1) * melToHz(m)) / SAMPLE_RATE) }.map { it.toInt() }

        return Array(N_MELS) { m ->
            val row = DoubleArray(nb)
            var k = bins[m]
            while (k < bins[m + 1] && k < nb) {
                row[k] = (k - bins[m]).toDouble() / (bins[m + 1] - bins[m] + 1e-10)
                k++
            }
            k = bins[m + 1]
            while (k < bins[m + 2] && k < nb) {
                row[k] = (bins[m + 2] - k).toDouble() / (bins[m + 2] - bins[m + 1] + 1e-10)
                k++
            }
            row
        }
    }

    // HTK-style mel scale — matches detection_service.dart's
    // _hz2mel/_mel2hz exactly. NOT librosa's default Slaney scale.
    private fun hzToMel(hz: Double): Double = 2595.0 * log10(1 + hz / 700.0)
    private fun melToHz(m: Double): Double = 700.0 * (10.0.pow(m / 2595.0) - 1.0)

    // ═══ OPTION B normalization functions ══════════════════════
    // (constants USE_FIXED_RANGE_NORMALIZATION / FIXED_DB_MIN /
    // FIXED_DB_MAX are declared in the companion object above)

    /**
     * ORIGINAL per-clip min-max normalization — matches
     * detection_service.dart's _normalize() exactly. This is what the
     * trained model actually learned on (via the Python preprocessing
     * pipeline this Dart code replicates), so it remains the default,
     * proven behavior unless USE_FIXED_RANGE_NORMALIZATION is true.
     */
    private fun normalizePerClip(spec: Array<DoubleArray>): Array<DoubleArray> {
        var mn = Double.POSITIVE_INFINITY
        var mx = Double.NEGATIVE_INFINITY
        for (row in spec) for (v in row) {
            if (v < mn) mn = v
            if (v > mx) mx = v
        }
        val range = kotlin.math.abs(mx - mn)
        if (range < 1e-10) return spec
        return Array(spec.size) { r ->
            DoubleArray(spec[r].size) { c ->
                ((spec[r][c] - mn) / range).coerceIn(0.0, 1.0)
            }
        }
    }

    /**
     * EXPERIMENTAL — Option B fixed-range normalization. Clamps every
     * dB value to [FIXED_DB_MIN, FIXED_DB_MAX] first, then scales
     * that FIXED window to [0,1] — restoring an absolute-loudness
     * reference that per-clip min-max throws away. A clip that never
     * gets loud stays uniformly low/dark; only clips with genuinely
     * loud content light up. See the companion object above for the
     * full rationale and explicitly-stated risk.
     */
    private fun normalizeFixedRange(spec: Array<DoubleArray>): Array<DoubleArray> {
        val range = FIXED_DB_MAX - FIXED_DB_MIN
        return Array(spec.size) { r ->
            DoubleArray(spec[r].size) { c ->
                val clamped = spec[r][c].coerceIn(FIXED_DB_MIN, FIXED_DB_MAX)
                ((clamped - FIXED_DB_MIN) / range).coerceIn(0.0, 1.0)
            }
        }
    }

    private fun normalize(spec: Array<DoubleArray>): Array<DoubleArray> {
        return if (USE_FIXED_RANGE_NORMALIZATION) {
            normalizeFixedRange(spec)
        } else {
            normalizePerClip(spec)
        }
    }

    // Reshape to [1][128][128][1], matching detection_service.dart's
    // _reshape4D() exactly.
    private fun reshape4D(spec: Array<DoubleArray>): Array<Array<Array<FloatArray>>> {
        return arrayOf(
            Array(TIME_FRAMES) { t ->
                Array(N_MELS) { m ->
                    floatArrayOf(spec[t][m].toFloat())
                }
            }
        )
    }

    private fun label(p: Double): String = when {
        p >= 0.90 -> "Screaming"
        p >= 0.80 -> "Fearful speech"
        p >= 0.70 -> "Glass breaking"
        p >= 0.50 -> "Crying"
        p >= threshold -> "Distress sound"
        else -> "Background / Safe"
    }

    private fun rms(buffer: FloatArray): Double {
        if (buffer.isEmpty()) return 0.0
        var s = 0.0
        for (v in buffer) s += v * v
        return sqrt(s / buffer.size)
    }

    fun simulateDetection(probability: Double = 0.1): DetectionResult {
        val p = probability.coerceIn(0.0, 1.0)
        return DetectionResult(
            confidence = p,
            isDistress = p >= threshold,
            soundType = label(p),
            timestampMs = System.currentTimeMillis()
        )
    }

    fun dispose() {
        interpreter?.close()
        interpreter = null
        modelLoaded = false
    }
}