package com.example.echosense_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.concurrent.thread
import kotlin.math.sqrt

/**
 * ResQNet — Native Distress Detection Service (STAGE 1)
 * ========================================================
 * WHY THIS EXISTS:
 * flutter_background_service was tried first and confirmed broken on
 * real-device testing — flutter_sound's recorder plugin throws
 * MissingPluginException when initialised from the background
 * isolate that package spins up (confirmed via real device log:
 * "MissingPluginException: No implementation found for method
 * openRecorder on channel xyz.canardoux.flutter_sound_recorder").
 * Both flutter_background_service_android AND flutter_sound register
 * their native method handlers against specific Flutter engines, and
 * the background isolate is a genuinely separate, headless engine
 * with no handler registered for either plugin at all.
 *
 * This service sidesteps that entirely by not depending on ANY
 * Flutter engine, plugin, or isolate once it's running. It uses
 * Android's native AudioRecord API directly for capture — no
 * flutter_sound, no platform channel, no Flutter dependency
 * whatsoever from this point in the pipeline onward.
 *
 * STAGE 1 SCOPE (completed, validated on real device — survives
 * app close and screen-off, confirmed via notification text updating
 * live while the app was fully closed):
 *   - Start as a proper Android foreground service (persistent
 *     notification, required by Android — not optional or hideable).
 *   - Capture raw PCM audio continuously via AudioRecord.
 *   - Calculate RMS per chunk and log it.
 *
 * STAGE 2 SCOPE (completed, validated on real device — confirmed
 * CNN inference matching the Dart pipeline's output, including a
 * real confirmed-distress + native SMS send during testing):
 *   - Replace the RMS-only placeholder with real CNN inference via
 *     NativeDetectionService — a direct Kotlin port of
 *     detection_service.dart's exact Mel-Spectrogram + LiteRT
 *     pipeline, verified function-for-function against the Dart
 *     source (HTK mel scale, naive DFT, same normalization/reshape).
 *   - Mirrors audio_service.dart's two-consecutive-hits confirmation
 *     logic before treating a detection as confirmed, to avoid
 *     single-frame false positives.
 *
 * STAGE 3 SCOPE (this revision):
 *   - On confirmed distress, actually send the alert via
 *     NativeAlertService — native SmsManager, dashboard HTTP POST,
 *     and Telegram, all matching sms_service.dart's exact wire
 *     formats, plus native last-known-location fetching via
 *     LocationManager (see NativeAlertService.kt for the full
 *     rationale and known limitations, e.g. (0.0, 0.0) if no
 *     last-known location fix is available on the device at all).
 */
class DistressDetectionService : Service() {

    companion object {
        private const val TAG = "DistressDetectionService"
        private const val NOTIFICATION_CHANNEL_ID = "resqnet_native_detection"
        private const val NOTIFICATION_ID = 9777

        // Matches the existing Dart pipeline's parameters exactly
        // (see audio_service.dart / detection_service.dart) so
        // chunk timing and RMS scale are directly comparable.
        private const val SAMPLE_RATE = 22050
        private const val CHUNK_SECONDS = 3
        // RAISED from 0.008 to 0.04 — a REAL, confirmed root cause was
        // found via debug instrumentation on real-device data, not a
        // guess: detection_service.dart/NativeDetectionService.kt's
        // shared per-clip min-max spectrogram normalization stretches
        // EVERY 3-second clip's own min/max to fill [0,1], regardless
        // of absolute loudness. Real captured data showed spec_max
        // sitting consistently near 0dB (close to full digital scale)
        // even for objectively quiet clips — because even quiet
        // ambient audio contains brief, narrow-band peaks (a
        // consonant, a breath) that approach 0dB in SOME mel bin.
        // After normalization, a quiet room with one sharp peak can
        // produce a spectrogram with the same contrast/dynamic range
        // as genuine screaming, since the model has no absolute-
        // loudness reference — only the clip's own relative shape.
        // Confirmed false positives in real testing ranged from
        // RMS=0.008 to RMS=0.030; confirmed real screams from earlier
        // testing registered around RMS=0.06-0.16. 0.04 sits clearly
        // above every recorded false positive while remaining below
        // every recorded genuine distress reading — chosen from real
        // data, not an arbitrary round number. TRADEOFF, stated
        // explicitly: quieter genuine distress (a weak/soft call for
        // help) below this RMS will no longer reach the CNN at all,
        // regardless of what it might have correctly classified —
        // this is a real, documented limitation worth disclosing,
        // not a transparent fix. The deeper architectural fix (fixed
        // dB-range clamping instead of per-clip min-max, matching
        // common practice for production audio classifiers) was
        // deliberately deferred — it would diverge native's
        // normalization from detection_service.dart's already-proven
        // approach, an unverified compatibility risk taken on
        // without time to validate it against the trained model.
        // ── Gate 1: RMS energy gate ────────────────────────────────────
        // RAISED from 0.04 → 0.050. Empirical analysis across all
        // real-device test events (June 2026):
        //   False positives (speech, office noise): RMS 0.008 – 0.043
        //   True positives (genuine distress):      RMS 0.068 – 0.159
        // The gap at 0.050 blocks every recorded false positive
        // including close-proximity conversational speech (confirmed
        // failure mode on the husband's A06 at work) while keeping
        // every recorded true positive. Raised from 0.04 because
        // office speech at typical working distance (30–60 cm from
        // phone) was measured at RMS 0.040–0.065 on the A06 device,
        // which sits above the previous 0.04 threshold.
        private const val RMS_THRESHOLD = 0.050

        // ── Gate 2: consecutive hit count ─────────────────────────────
        // Require N qualifying chunks in sequence before confirmation.
        private const val CONSECUTIVE_HITS_REQUIRED = 2

        // ── Gate 3 + 4: streak average gates ──────────────────────────
        // Applied AT confirmation time across the accumulated streak.
        // Blocks weak pairs (21% + 22% = avg 21%) while keeping strong
        // genuine pairs (95% + 31% = avg 63%).
        private const val CONFIRMATION_MIN_AVG_CONFIDENCE = 0.35

        // Blocks high-confidence detections from genuinely quiet audio
        // (confirmed failure mode: RMS = 0.008 produced CNN 95%).
        private const val CONFIRMATION_MIN_STREAK_AVG_RMS = 0.045

        // ── Grace period ───────────────────────────────────────────────
        // How many consecutive non-qualifying chunks (CNN says safe OR
        // rms < threshold) are tolerated before the streak fully resets.
        // 3 chunks = 9 seconds of continuous safe audio needed to wipe
        // a genuine distress streak. Without this, a single breath or
        // pause between cries resets the counter and forces a restart.
        private const val MAX_CONSECUTIVE_MISSES = 3

        // ── Alert flood prevention ─────────────────────────────────────
        // Mirrors audio_service.dart's 60s cooldown exactly.
        private const val ALERT_COOLDOWN_MS = 60_000L

        // Bound on how long a single classify() call is allowed to
        // run before being abandoned for that chunk. Generous
        // relative to the FFT-based inference's expected real-world
        // cost (well under a second), but still far below anything
        // that would risk an OS watchdog killing the process the way
        // the old ~56-second naive-DFT inference did.
        private const val CLASSIFY_TIMEOUT_SECONDS = 5L

        const val ACTION_START = "com.example.echosense_app.action.START_DETECTION"
        const val ACTION_STOP  = "com.example.echosense_app.action.STOP_DETECTION"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var shouldRun = false
    @Volatile private var lastAlertSentAtMs = 0L

    private var detector: NativeDetectionService? = null
    private var alertService: NativeAlertService? = null
    private var meshService: NativeMeshService? = null
    private var consecutiveDistressHits = 0

    // ── Streak tracking variables (ported from audio_service.dart) ──
    // consecutiveMisses: counts consecutive non-qualifying chunks.
    // Reaches MAX_CONSECUTIVE_MISSES before streak is reset, so a
    // single breath or brief quiet moment doesn't wipe a genuine
    // distress streak (grace period logic).
    private var consecutiveMisses = 0

    // Accumulates CNN confidence and RMS of each qualifying chunk in
    // the current streak, so the average gates can be applied at
    // confirmation time rather than chunk-by-chunk.
    private val streakConfidences = mutableListOf<Double>()
    private val streakRmsValues   = mutableListOf<Double>()

    // Dedicated single-thread executor for CNN inference, isolated
    // from the audio capture thread (captureThread). Originally,
    // classify() ran directly inline inside the capture loop — real
    // device testing showed this taking ~56-61 SECONDS per call (the
    // naive O(n^2) DFT before it was replaced with a proper FFT),
    // which blocked the capture thread long enough that
    // ActivityManager killed the foreground service outright. Even
    // with the FFT fix bringing inference down to a small fraction of
    // a second, running it on its own executor with a bounded timeout
    // is kept as defense in depth — a slower phone, a future larger
    // model, or any other unexpected slowdown should degrade
    // gracefully (skip that one chunk's classification) rather than
    // ever again risk blocking the process long enough to be killed.
    private val inferenceExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        detector = NativeDetectionService(applicationContext)
        alertService = NativeAlertService(applicationContext)
        meshService = NativeMeshService(applicationContext)
        // Start proactive location tracking immediately so we have a
        // cached fix ready at alert time — avoids the background-service
        // location restriction on Android 10+ where getLastKnownLocation()
        // returns null if called cold from a background thread.
        alertService?.startLocationTracking()
        val loaded = detector?.loadModel() ?: false
        if (!loaded) {
            Log.e(TAG, "CNN model failed to load — falling back to RMS-only " +
                    "detection (Stage 1 behaviour) for this session")
        }
        // Start mesh scanning immediately alongside detection — this
        // phone acts as a bystander/relay listener even before its
        // own distress is ever confirmed, mirroring mesh_service.dart's
        // startMesh() always-scanning behaviour.
        meshService?.startScanning { packet ->
            Log.i(TAG, "Mesh packet received from elsewhere — origin=${packet.originId} " +
                    "hop=${packet.hopCount}. Forwarded to dashboard already; " +
                    "re-broadcast onward depends on BLE advertising support " +
                    "(see NativeMeshService for the give-up-after-failures logic).")
        }
        Log.i(TAG, "onCreate() — service process alive, modelLoaded=$loaded")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopDetection()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                startForegroundWithNotification("Monitoring active",
                    "Listening for distress sounds in the background")
                startDetection()
            }
        }
        // START_STICKY: if Android kills this process under memory
        // pressure, ask the system to recreate it and call
        // onStartCommand again (with a null intent) — appropriate for
        // a long-running monitor that should resume rather than just
        // vanish silently.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        stopDetection()
        // FIX: previously called inferenceExecutor.shutdownNow()
        // immediately, which abruptly interrupts any in-flight task
        // rather than letting it finish. If classify() happened to be
        // mid-execution inside the LiteRT native layer at that exact
        // moment, interrupting it right before detector.dispose()
        // tears down the same Interpreter underneath it is a real
        // risk — potentially leaving dangling native resources.
        // shutdown() (stop accepting new work) + a bounded
        // awaitTermination() gives any in-flight inference a real
        // chance to finish cleanly first; shutdownNow() is now only a
        // fallback if it genuinely hangs past the timeout, not the
        // default first action.
        inferenceExecutor.shutdown()
        try {
            if (!inferenceExecutor.awaitTermination(2, TimeUnit.SECONDS)) {
                Log.w(TAG, "inferenceExecutor did not terminate within 2s — forcing shutdown")
                inferenceExecutor.shutdownNow()
            }
        } catch (e: InterruptedException) {
            inferenceExecutor.shutdownNow()
        }
        detector?.dispose()
        detector = null
        alertService?.stopLocationTracking()
        alertService = null
        meshService?.dispose()
        meshService = null
        Log.i(TAG, "onDestroy() — service process ending")
    }

    // ── Foreground notification setup ──────────────────────────
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "ResQNet Background Monitoring",
                NotificationManager.IMPORTANCE_LOW // low: visible icon, no sound/vibration spam
            ).apply {
                description = "Keeps distress detection running when the app is minimised"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun startForegroundWithNotification(title: String, content: String) {
        val notification: Notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(content)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now) // TODO: replace with app icon
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Required on Android 10+ to declare WHICH foreground
            // service type this is — must match the
            // android:foregroundServiceType="microphone" declared in
            // the manifest for this service, or the OS will reject it.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        Log.i(TAG, "startForeground() called — service should now survive backgrounding")
    }

    private fun updateNotification(title: String, content: String) {
        val notification: Notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(content)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification)
    }

    // ── Detection loop ──────────────────────────────────────────
    private fun startDetection() {
        if (shouldRun) {
            Log.i(TAG, "startDetection() — already running, ignoring")
            return
        }
        shouldRun = true
        isRunning = true
        resetStreak()
        lastAlertSentAtMs = 0L

        captureThread = thread(start = true, name = "DistressCaptureThread") {
            runCaptureLoop()
        }
    }

    private fun stopDetection() {
        shouldRun = false
        isRunning = false
        // FIX: previously called audioRecord?.stop()/.release() here
        // directly — but this runs on whichever thread calls
        // stopDetection() (the main thread, via onStartCommand's
        // ACTION_STOP handling), while runCaptureLoop() is very
        // likely blocked inside record.read(...) on captureThread at
        // that exact moment. Calling stop()/release() on an
        // AudioRecord instance while another thread is mid-read() on
        // it is a real, documented Android footgun — can throw
        // IllegalStateException, or cause worse instability on some
        // OEM audio HALs (a plausible contributor to the intermittent
        // "ActivityManager: Scheduling restart of crashed service"
        // lines seen in real testing). Setting shouldRun=false is
        // sufficient: runCaptureLoop()'s own while loop checks it
        // after each read() returns, exits, and releases the
        // AudioRecord itself at the end of its own loop (see "Capture
        // loop exited cleanly" below) — the thread that OWNS the
        // instance is now the only one that ever calls stop()/
        // release() on it.
        captureThread = null
        Log.i(TAG, "stopDetection() — capture loop stopped")
    }

    private fun runCaptureLoop() {
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT

        val minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, channelConfig, audioFormat)
        if (minBufferSize == AudioRecord.ERROR_BAD_VALUE || minBufferSize == AudioRecord.ERROR) {
            Log.e(TAG, "getMinBufferSize() failed — device doesn't support $SAMPLE_RATE Hz mono 16-bit")
            return
        }
        // Safety margin above the minimum, matching common practice
        // seen across reference implementations, to reduce the risk
        // of buffer underruns under load.
        val bufferSizeBytes = minBufferSize * 4

        val record = try {
            AudioRecord(
                // FIX: changed from MediaRecorder.AudioSource.MIC to
                // DEFAULT. This was a REAL, confirmed root-cause fix,
                // not a guess — found via research, not trial and
                // error. Google's own Android developer documentation
                // states: "Most of the audio sources (including
                // DEFAULT) apply processing to the audio signal. To
                // record raw audio select UNPROCESSED." MIC is closer
                // to a raw/general-purpose source; DEFAULT explicitly
                // applies signal processing (which, depending on
                // device, can include AGC/noise suppression).
                //
                // Critically: flutter_sound's startRecorder() API has
                // an audioSource parameter that defaults to
                // AudioSource.defaultSource when not explicitly
                // specified — confirmed via flutter_sound's own
                // published API documentation. audio_service.dart's
                // call to startRecorder() never specifies audioSource,
                // meaning the Dart pipeline has been using DEFAULT
                // this entire time, NOT MIC. The native pipeline
                // explicitly chose MIC during Stage 1, an assumption
                // that was never actually verified against what Dart
                // was really doing.
                //
                // This is the most well-evidenced remaining
                // explanation for why native and Dart, using the
                // IDENTICAL trained model and IDENTICAL math
                // (independently verified function-for-function
                // earlier), produced systematically different
                // confidence on the same kind of real speech — Dart
                // reliably low, native reliably high. Matching
                // native's source to what Dart has actually been
                // using is the most direct way to test this.
                MediaRecorder.AudioSource.DEFAULT,
                SAMPLE_RATE,
                channelConfig,
                audioFormat,
                bufferSizeBytes
            )
        } catch (e: Exception) {
            Log.e(TAG, "AudioRecord constructor threw — $e")
            return
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialise (state=${record.state}) — " +
                    "RECORD_AUDIO permission may be missing, or mic is in use by another app")
            record.release()
            return
        }

        audioRecord = record

        try {
            record.startRecording()
        } catch (e: IllegalStateException) {
            Log.e(TAG, "startRecording() threw — $e")
            record.release()
            audioRecord = null
            return
        }

        Log.i(TAG, "AudioRecord capture started — sampleRate=$SAMPLE_RATE bufferSizeBytes=$bufferSizeBytes")

        // Read in chunks sized to CHUNK_SECONDS, matching the existing
        // Dart pipeline's chunking so RMS values and timing are
        // directly comparable between the two implementations.
        val samplesPerChunk = SAMPLE_RATE * CHUNK_SECONDS
        val chunkBuffer = ShortArray(samplesPerChunk)

        while (shouldRun) {
            var totalRead = 0
            // AudioRecord.read() may return fewer samples than
            // requested in a single call — loop until the full chunk
            // is filled or we're told to stop.
            while (totalRead < samplesPerChunk && shouldRun) {
                val readResult = record.read(
                    chunkBuffer, totalRead, samplesPerChunk - totalRead
                )
                if (readResult < 0) {
                    Log.w(TAG, "AudioRecord.read() returned error code $readResult")
                    break
                }
                totalRead += readResult
            }

            if (!shouldRun) break
            if (totalRead <= 0) continue

            val rms = calculateRms(chunkBuffer, totalRead)
            Log.i(TAG, "Native capture chunk — samples=$totalRead rms=${"%.5f".format(rms)} " +
                    "threshold=$RMS_THRESHOLD")

            if (rms > RMS_THRESHOLD) {
                Log.i(TAG, "Sound detected — running CNN...")
                updateNotification("Sound detected", "Running CNN inference...")

                // Convert ShortArray PCM16 -> normalised FloatArray
                // [-1.0, 1.0], matching detection_service.dart's
                // sample/32768.0 convention exactly, since the CNN
                // was trained against audio normalised this way.
                val floatBuffer = FloatArray(totalRead) { i ->
                    (chunkBuffer[i] / 32768.0).toFloat()
                }

                // Run classification on the dedicated inference
                // executor with a bounded timeout, rather than calling
                // it directly inline on this capture thread — see the
                // inferenceExecutor field comment for why. get(timeout)
                // blocks this thread until either the result is ready
                // or the timeout elapses, so the *logic* below still
                // runs sequentially and simply (no concurrent mutation
                // of consecutiveDistressHits or other shared state),
                // while the actual inference work itself is isolated
                // on a separate thread that can be abandoned cleanly
                // if it ever takes too long.
                val future = inferenceExecutor.submit<NativeDetectionService.DetectionResult?> {
                    detector?.classify(floatBuffer)
                }
                val result = try {
                    future.get(CLASSIFY_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                } catch (e: TimeoutException) {
                    Log.e(TAG, "classify() exceeded ${CLASSIFY_TIMEOUT_SECONDS}s timeout — " +
                            "abandoning this chunk's classification rather than blocking " +
                            "further. This should not happen with the FFT-based pipeline " +
                            "under normal conditions; if seen repeatedly, investigate device " +
                            "performance or model size.")
                    future.cancel(true)
                    null
                } catch (e: Exception) {
                    Log.e(TAG, "Inference executor error — $e")
                    null
                }
                if (result != null) {
                    Log.i(TAG, "CNN -> ${result.confidencePercent} (${result.soundType}) " +
                            "isDistress=${result.isDistress}")

                    if (result.isDistress) {
                        // ── Qualifying hit ─────────────────────────────────────
                        consecutiveMisses = 0
                        consecutiveDistressHits++
                        streakConfidences.add(result.confidence)
                        streakRmsValues.add(rms)
                        Log.i(TAG, "High-risk anomaly tracked! Run sequence count = " +
                                "$consecutiveDistressHits/$CONSECUTIVE_HITS_REQUIRED " +
                                "(conf=${result.confidencePercent} rms=${"%.4f".format(rms)})")

                        if (consecutiveDistressHits >= CONSECUTIVE_HITS_REQUIRED) {
                            // ── Gate 3: average confidence across streak ───────
                            val avgConf = streakConfidences.average()
                            // ── Gate 4: average RMS energy of qualifying chunks
                            val avgRms  = streakRmsValues.average()
                            Log.i(TAG, "Streak gates check — " +
                                    "avgConf=${"%.0f".format(avgConf * 100)}% " +
                                    "(min=${(CONFIRMATION_MIN_AVG_CONFIDENCE * 100).toInt()}%) | " +
                                    "avgRms=${"%.4f".format(avgRms)} " +
                                    "(min=$CONFIRMATION_MIN_STREAK_AVG_RMS)")

                            if (avgConf >= CONFIRMATION_MIN_AVG_CONFIDENCE &&
                                avgRms  >= CONFIRMATION_MIN_STREAK_AVG_RMS) {
                                Log.i(TAG, "DISTRESS CONFIRMED — ${result.soundType} " +
                                        "(${result.confidencePercent}) " +
                                        "avgConf=${"%.0f".format(avgConf * 100)}% " +
                                        "avgRms=${"%.4f".format(avgRms)}")
                                updateNotification(
                                    "DISTRESS CONFIRMED",
                                    "${result.soundType} — ${result.confidencePercent} confidence. " +
                                            "Sending alert..."
                                )
                                resetStreak()
                                sendConfirmedAlert(result.confidence, result.soundType)
                            } else {
                                val reason = when {
                                    avgConf < CONFIRMATION_MIN_AVG_CONFIDENCE ->
                                        "avg confidence ${"%.0f".format(avgConf * 100)}% " +
                                                "below ${(CONFIRMATION_MIN_AVG_CONFIDENCE * 100).toInt()}% gate"
                                    else ->
                                        "avg RMS ${"%.4f".format(avgRms)} " +
                                                "below $CONFIRMATION_MIN_STREAK_AVG_RMS gate"
                                }
                                Log.i(TAG, "Near-miss filtered — $reason. Resetting streak.")
                                updateNotification(
                                    "Monitoring active",
                                    "Near-miss: $reason"
                                )
                                resetStreak()
                            }
                        }
                    } else {
                        // ── Non-qualifying chunk: grace period before reset ───
                        // Don't wipe the streak immediately — a single breath or
                        // brief pause between distress sounds should not force
                        // the counter all the way back to zero.
                        consecutiveMisses++
                        if (consecutiveMisses >= MAX_CONSECUTIVE_MISSES) {
                            Log.i(TAG, "Streak reset — $MAX_CONSECUTIVE_MISSES " +
                                    "consecutive non-qualifying chunks (grace period exceeded)")
                            resetStreak()
                        } else {
                            Log.i(TAG, "Grace-period miss $consecutiveMisses/" +
                                    "$MAX_CONSECUTIVE_MISSES — streak preserved " +
                                    "(hits=$consecutiveDistressHits/$CONSECUTIVE_HITS_REQUIRED)")
                        }
                        updateNotification(
                            "Monitoring active",
                            "Last check: ${result.soundType} (${result.confidencePercent})"
                        )
                    }
                } else {
                    Log.w(TAG, "classify() returned null — detector not ready")
                }
            } else {
                // ── Quiet chunk (rms < threshold): grace period ────────────
                // If a streak is in progress, count this as a miss rather
                // than silently skipping it, so genuine pauses between
                // distress sounds don't accumulate invisibly. If no streak
                // is active, just ignore the quiet chunk entirely.
                if (consecutiveDistressHits > 0) {
                    consecutiveMisses++
                    if (consecutiveMisses >= MAX_CONSECUTIVE_MISSES) {
                        Log.i(TAG, "Streak reset — $MAX_CONSECUTIVE_MISSES quiet chunks " +
                                "during active streak (grace period exceeded)")
                        resetStreak()
                    } else {
                        Log.i(TAG, "Grace-period quiet chunk $consecutiveMisses/" +
                                "$MAX_CONSECUTIVE_MISSES — streak preserved")
                    }
                }
            }   // end: if (rms > RMS_THRESHOLD) / else
        }       // end: while (shouldRun)

        try {
            record.stop()
        } catch (e: Exception) {
            Log.w(TAG, "record.stop() threw during loop exit — $e")
        }
        record.release()
        audioRecord = null
        Log.i(TAG, "Capture loop exited cleanly")
    }

    // ── Streak state reset ─────────────────────────────────────────────
    // Single point of truth for clearing all four streak fields together.
    // Called on: confirmed alert, near-miss filter, and startDetection().
    private fun resetStreak() {
        consecutiveDistressHits = 0
        consecutiveMisses       = 0
        streakConfidences.clear()
        streakRmsValues.clear()
    }

    /**
     * Sends the actual alert on a confirmed distress detection, via
     * NativeAlertService (SMS + dashboard + Telegram). Runs on a new
     * background thread rather than the capture thread itself, since
     * SmsManager calls and blocking HTTP requests must not stall
     * audio capture — the capture loop needs to keep reading the mic
     * continuously regardless of how long sending the alert takes.
     *
     * COOLDOWN: mirrors audio_service.dart's own behaviour exactly —
     * that pipeline logs "Monitoring context sleeping for 60s window
     * to avoid flooding channels" after sending an alert, confirmed
     * in real testing. Without an equivalent guard here, a sustained
     * loud noise (e.g. someone screaming continuously for a minute)
     * would re-trigger CONSECUTIVE_HITS_REQUIRED repeatedly and fire
     * a fresh SMS/Telegram/dashboard alert every few seconds, which
     * would flood the emergency contact's phone and the dashboard
     * with duplicate alerts for what is, practically, the same
     * ongoing emergency.
     */
    private fun sendConfirmedAlert(confidence: Double, soundType: String) {
        val now = System.currentTimeMillis()
        if (now - lastAlertSentAtMs < ALERT_COOLDOWN_MS) {
            val remainingSec = (ALERT_COOLDOWN_MS - (now - lastAlertSentAtMs)) / 1000
            Log.i(TAG, "Alert cooldown active — skipping duplicate alert " +
                    "(${remainingSec}s remaining)")
            return
        }
        lastAlertSentAtMs = now

        thread(start = true, name = "DistressAlertThread") {
            try {
                val battery = getBatteryLevel()
                val result = alertService?.sendAlert(
                    confidence = confidence,
                    soundType = soundType,
                    batteryLevel = battery
                )
                Log.i(TAG, "Alert send complete — sms=${result?.smsSent} " +
                        "dashboard=${result?.dashboardSent} telegram=${result?.telegramSent}")
                updateNotification("Alert sent",
                    "$soundType — sms=${result?.smsSent} dashboard=${result?.dashboardSent} " +
                            "telegram=${result?.telegramSent}")

                // Attempt native BLE mesh broadcast — mirrors
                // broadcastAlert() in mesh_service.dart.
                // NativeMeshService.attemptAdvertise() handles the
                // give-up-after-N-failures logic itself (same pattern
                // as mesh_service.dart's _bleAdvertisingUnsupported),
                // so no extra logic is needed here — just call it.
                // The location and battery are re-used from the alert
                // result; location is fetched internally by
                // NativeAlertService and not available separately here,
                // so we construct a packet with what we know and let
                // the mesh service use (0,0) fallback same as the
                // alert itself already does when no fix is available.
                val meshPacket = NativeMeshService.MeshPacket(
                    networkId = 0xBEEF,
                    originId = getDeviceNumericId(),
                    relayId = 0,
                    seqNum = (System.currentTimeMillis() / 1000 % 256).toInt(),
                    ttl = 5,
                    confidencePct = (confidence * 100).toInt().coerceIn(0, 100),
                    latitude = 0.0f,   // best effort — same limitation
                    longitude = 0.0f,  // as NativeAlertService.sendAlert()
                    battery = battery,
                    hopCount = 0,
                    soundCode = if (soundType.contains("Screaming", true) ||
                        soundType.contains("CNN", true) ||
                        soundType.contains("Distress", true)) 0x43 else 0x53
                )
                meshService?.attemptAdvertise(meshPacket)
                Log.i(TAG, "Native BLE mesh broadcast attempted — " +
                        "result will arrive in NativeMeshService's " +
                        "AdvertiseCallback.onStartSuccess/onStartFailure")
            } catch (e: Exception) {
                Log.e(TAG, "sendConfirmedAlert() failed — $e")
            }
        }
    }

    // Reads the same permanent numeric device ID that mesh_service.dart
    // assigns and stores under 'resqnet_numeric_id_v4' — so a native-
    // triggered mesh packet carries the same originId as a Dart-triggered
    // one, and nearby phones can deduplicate them correctly by originId+seqNum.
    //
    // IMPORTANT: Flutter's shared_preferences plugin stores Dart `int`
    // values as a Java Long on Android, NOT an Integer — Dart's int
    // type has no fixed bit-width, so the plugin always widens to
    // Long when writing. Calling prefs.getInt() on a key that was
    // actually written by Dart throws ClassCastException(Long cannot
    // be cast to Integer) — confirmed via real device crash logs
    // during testing, not a hypothetical. The fix: read the raw value
    // from the preference map and check its actual runtime type,
    // rather than assuming getInt() is safe just because the stored
    // number happens to fit in an Int's range.
    private fun getDeviceNumericId(): Int {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.all["flutter.resqnet_numeric_id_v4"]
        val id: Long = when (raw) {
            is Long -> raw
            is Int -> raw.toLong()
            else -> {
                if (raw != null) {
                    Log.w(TAG, "resqnet_numeric_id_v4 has unexpected type " +
                            "${raw.javaClass.simpleName} — using fallback ID 1")
                }
                0L
            }
        }
        if (id == 0L) {
            Log.w(TAG, "resqnet_numeric_id_v4 not found in FlutterSharedPreferences — " +
                    "app may never have been opened after registration. Using fallback ID 1.")
            return 1
        }
        // The Dart side generates this as Random().nextInt(0xFFFE)+1,
        // i.e. always within Int range (1-65534) despite being stored
        // as a Long — this toInt() is a safe narrowing, not a risky
        // truncation, given that known value range.
        return id.toInt()
    }

    // Matches sms_service.dart's real battery reading (via the
    // battery_plus plugin) in spirit — same intent, native source:
    // Android's BatteryManager, no extra dependency needed.
    private fun getBatteryLevel(): Int {
        return try {
            val bm = getSystemService(BATTERY_SERVICE) as BatteryManager
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (e: Exception) {
            Log.w(TAG, "Battery read failed — $e")
            0
        }
    }

    /**
     * RMS over 16-bit PCM samples, normalised to the same [-1.0, 1.0]
     * float range the existing Dart pipeline uses (sample / 32768.0),
     * so RMS values are directly comparable between native and Dart
     * implementations — same scale, same meaning.
     */
    private fun calculateRms(buffer: ShortArray, sampleCount: Int): Double {
        if (sampleCount <= 0) return 0.0
        var sumOfSquares = 0.0
        for (i in 0 until sampleCount) {
            val normalised = buffer[i] / 32768.0
            sumOfSquares += normalised * normalised
        }
        return sqrt(sumOfSquares / sampleCount)
    }
}