package com.example.echosense_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.resqnet.sms/send"
    private val NATIVE_DETECTION_CHANNEL = "com.example.echosense_app/native_detection"
    private val SMS_PERMISSION_CODE = 101

    // Classic Bluetooth fallback beacon — second, independent broadcast
    // channel used when BLE peripheral advertising is unreliable on the
    // device's hardware.
    private lateinit var classicBeacon: ClassicBeaconHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        classicBeacon = ClassicBeaconHandler(this)
        classicBeacon.attach(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                // ── Send SMS silently ───────────────────────────
                "sendSms" -> {
                    val message    = call.argument<String>("message") ?: ""
                    val recipients = call.argument<List<String>>("recipients")
                                     ?: emptyList()

                    if (message.isEmpty() || recipients.isEmpty()) {
                        result.error("INVALID_ARGS",
                            "Message and recipients required", null)
                        return@setMethodCallHandler
                    }

                    // Check permission first
                    if (ContextCompat.checkSelfPermission(
                            this, Manifest.permission.SEND_SMS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        // Request permission
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.SEND_SMS),
                            SMS_PERMISSION_CODE
                        )
                        result.error("PERMISSION_DENIED",
                            "SMS permission not granted", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val smsManager = getSmsManager()
                        var sentCount  = 0

                        for (phone in recipients) {
                            val cleanPhone = phone.trim()
                            if (cleanPhone.isEmpty()) continue

                            // Split long messages into parts automatically
                            val parts = smsManager.divideMessage(message)

                            if (parts.size == 1) {
                                // Short message — send directly
                                smsManager.sendTextMessage(
                                    cleanPhone,
                                    null,
                                    message,
                                    null,  // no sent intent
                                    null   // no delivery intent
                                )
                            } else {
                                // Long message — send as multipart
                                smsManager.sendMultipartTextMessage(
                                    cleanPhone,
                                    null,
                                    parts,
                                    null,
                                    null
                                )
                            }

                            sentCount++
                            android.util.Log.d(
                                "ResQNet",
                                "SMS sent to $cleanPhone"
                            )
                        }

                        result.success("SMS sent to $sentCount contacts")

                    } catch (e: Exception) {
                        android.util.Log.e("ResQNet", "SMS failed: ${e.message}")
                        result.error("SMS_FAILED", e.message, null)
                    }
                }

                // ── Check SMS permission ────────────────────────
                "checkPermission" -> {
                    val granted = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.SEND_SMS
                    ) == PackageManager.PERMISSION_GRANTED
                    result.success(granted)
                }

                // ── Request SMS permission ──────────────────────
                "requestPermission" -> {
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(Manifest.permission.SEND_SMS),
                        SMS_PERMISSION_CODE
                    )
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // ── Native distress detection ──────────────────────────
        // Separate channel from the SMS one above — keeps this
        // native pipeline fully independent from the existing,
        // working SMS logic. Starts/stops DistressDetectionService,
        // the AudioRecord-based foreground service that captures
        // audio without depending on the Flutter engine (built to
        // sidestep the confirmed flutter_sound cross-isolate failure
        // from the flutter_background_service attempt — see
        // background_audio_service.dart's doc comment for that
        // history).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NATIVE_DETECTION_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startNativeDetection" -> {
                    val intent = Intent(this, DistressDetectionService::class.java)
                    intent.action = DistressDetectionService.ACTION_START
                    startService(intent)
                    result.success(true)
                }
                "stopNativeDetection" -> {
                    val intent = Intent(this, DistressDetectionService::class.java)
                    intent.action = DistressDetectionService.ACTION_STOP
                    startService(intent)
                    result.success(true)
                }
                "isNativeDetectionRunning" -> {
                    result.success(DistressDetectionService.isRunning)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── Get SmsManager (handles API level differences) ──────────
    private fun getSmsManager(): SmsManager {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ — use getDefault() from context
            getSystemService(SmsManager::class.java)
                ?: SmsManager.getDefault()
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
    }

    // ── Forward the discoverable-mode dialog result ──────────────
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        classicBeacon.onActivityResult(requestCode, resultCode)
    }

    override fun onDestroy() {
        classicBeacon.dispose()
        super.onDestroy()
    }
}