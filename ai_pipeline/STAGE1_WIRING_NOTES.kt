// ============================================================
// STAGE 1 — WIRING NOTES (read this before testing)
// ============================================================
//
// This file is NOT a complete MainActivity.kt — it's the specific
// addition you need to make to YOUR existing MainActivity.kt (which
// I haven't seen yet) so Dart can start/stop the native service.
//
// 1) ADD THIS SERVICE DECLARATION TO AndroidManifest.xml
// --------------------------------------------------------------
// Place inside <application>, alongside your existing
// flutter_background_service entry (that one can stay — it's
// harmless, just unused once this native path takes over).
//
//   <service
//       android:name=".DistressDetectionService"
//       android:foregroundServiceType="microphone"
//       android:exported="false" />
//
// Your manifest already has RECORD_AUDIO, FOREGROUND_SERVICE, and
// FOREGROUND_SERVICE_MICROPHONE permissions declared — no permission
// changes needed for Stage 1.
//
//
// 2) ADD A METHOD CHANNEL TO MainActivity.kt
// --------------------------------------------------------------
// Find your existing MainActivity.kt (likely at
// android/app/src/main/kotlin/com/example/echosense_app/MainActivity.kt)
// and add a MethodChannel so Dart can call into the native service.
// If MainActivity.kt currently looks like the Flutter default
// (just `class MainActivity: FlutterActivity()`), add this:

package com.example.echosense_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.echosense_app/native_detection"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
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
}

//
// 3) MINIMAL DART SIDE — for testing Stage 1 ONLY
// --------------------------------------------------------------
// This is NOT meant to replace BackgroundAudioService.dart yet —
// it's a throwaway test harness so you can verify the native
// service survives backgrounding before any more Dart integration
// work happens. Paste this as a temporary test file, or just run
// these three calls from a debug button on HomeScreen temporarily.
//
//   import 'package:flutter/services.dart';
//
//   const _nativeChannel = MethodChannel(
//       'com.example.echosense_app/native_detection');
//
//   Future<void> startNativeDetectionTest() async {
//     final ok = await _nativeChannel.invokeMethod('startNativeDetection');
//     print('Native detection start requested: $ok');
//   }
//
//   Future<void> stopNativeDetectionTest() async {
//     await _nativeChannel.invokeMethod('stopNativeDetection');
//     print('Native detection stop requested');
//   }
//
//
// 4) HOW TO ACTUALLY TEST STAGE 1
// --------------------------------------------------------------
// a. Add the manifest <service> entry above.
// b. Merge the MethodChannel code into your real MainActivity.kt
//    (send it to me and I'll merge it precisely if you're not sure
//    how — don't want to guess at your existing class structure).
// c. Call startNativeDetectionTest() from a button (or just from
//    initState() temporarily) to trigger it.
// d. Watch `adb logcat | grep DistressDetectionService` (or just
//    your normal Flutter run console — Android Log.i() calls also
//    surface there) for:
//      "AudioRecord capture started"
//      "Native capture chunk — samples=... rms=..."
// e. THE ACTUAL TEST: lock the screen or switch to another app
//    entirely for 2-3 minutes, then unlock and check logs again.
//    If "Native capture chunk" lines kept appearing the WHOLE time
//    the screen was off/app was backgrounded, Stage 1 is validated
//    and we move to Stage 2 (wiring in the real CNN). If the lines
//    stopped, that tells us exactly where the foreground-service
//    setup itself needs more work, before any model/alert logic is
//    worth adding on top.
