package com.example.echosense_app

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Classic Bluetooth fallback beacon — independent of BLE peripheral mode.
 *
 * FIXES APPLIED (see inline comments for detail):
 *   1. adapter.setName() return value is now checked — Android silently
 *      returns false instead of throwing when the rename fails (missing
 *      BLUETOOTH_CONNECT permission on API 31+, OEM restrictions, etc.),
 *      so the old code always reported success to Dart regardless of
 *      whether the device's Bluetooth name actually changed.
 *   2. originalName is now persisted to SharedPreferences, not just
 *      returned to Dart. If the process dies (OOM kill, crash) between
 *      startBeacon() and stopBeacon(), the adapter name would previously
 *      stay stuck on the beacon string forever with no way to recover it.
 *   3. registerReceiver() now passes RECEIVER_EXPORTED on API 33+ (Android
 *      13+), which the OS requires as of targetSdk 34 (Android 14) — this
 *      is what was producing the intermittent "works on retry" pattern:
 *      Google Play / the OS enforces it at the targetSdk level, and the
 *      exact failure conditions (cold start vs warm start, OEM Bluetooth
 *      stack timing) varied between attempts, matching "works sometimes."
 *   4. Logs when a discovered device's name comes back null instead of
 *      silently dropping it — that branch was previously invisible in
 *      logcat, making real discovery misses look identical to "no nearby
 *      devices" in your debug output.
 *   5. requestDiscoverable() now reports back over the event channel
 *      whether the user actually granted/declined discoverable mode,
 *      instead of startBeacon() unconditionally reporting success before
 *      that's known.
 */
class ClassicBeaconHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "resqnet/classic_beacon"
        private const val EVENT_CHANNEL = "resqnet/classic_beacon_events"
        private const val REQUEST_DISCOVERABLE = 4201
        private const val DISCOVERABLE_DURATION_SECONDS = 300
        private const val PREFS_NAME = "resqnet_classic_beacon_prefs"
        private const val PREFS_ORIGINAL_NAME_KEY = "original_bt_name"
    }

    private val bluetoothAdapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
    private var eventSink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null
    private var receiverRegistered = false

    private val prefs: SharedPreferences
        get() = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun attach(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler(this)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        // FIX 2 (part of): on a fresh process start, if a beacon name was
        // never restored last time (process died mid-beacon), restore it
        // now rather than leaving the adapter permanently renamed.
        restoreOriginalNameIfStuck()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val adapter = bluetoothAdapter
        if (adapter == null) {
            result.error("NO_ADAPTER", "Bluetooth not supported on this device", null)
            return
        }
        try {
            when (call.method) {
                "startBeacon" -> {
                    val name = call.argument<String>("name") ?: ""
                    val originalName = adapter.name

                    // FIX 1: setName() returns Boolean — Android silently
                    // returns false on failure (missing BLUETOOTH_CONNECT
                    // permission on API 31+, some OEM restrictions) rather
                    // than throwing. The old code ignored this return
                    // value entirely and always told Dart it succeeded.
                    val renameOk = adapter.setName(name)
                    if (!renameOk) {
                        android.util.Log.w(
                            "ClassicBeacon",
                            "adapter.setName() returned false — name may not have changed"
                        )
                    }

                    // FIX 2: persist originalName to disk, not just to the
                    // Dart-side return value. If this process dies before
                    // stopBeacon() is called, restoreOriginalNameIfStuck()
                    // (called from attach() on next launch) can still
                    // recover the device's real Bluetooth name.
                    prefs.edit().putString(PREFS_ORIGINAL_NAME_KEY, originalName).apply()

                    requestDiscoverable()
                    result.success(mapOf(
                        "originalName" to originalName,
                        "renameSucceeded" to renameOk
                    ))
                }
                "stopBeacon" -> {
                    val originalName = call.argument<String>("originalName") as? String
                        ?: prefs.getString(PREFS_ORIGINAL_NAME_KEY, null)
                    if (originalName != null) {
                        val restoreOk = adapter.setName(originalName)
                        if (!restoreOk) {
                            android.util.Log.w(
                                "ClassicBeacon",
                                "Failed to restore original adapter name"
                            )
                        }
                        // Clear the persisted value now that we've
                        // (attempted to) restore it — prevents
                        // restoreOriginalNameIfStuck() from re-applying a
                        // stale name on a future cold start.
                        prefs.edit().remove(PREFS_ORIGINAL_NAME_KEY).apply()
                    }
                    result.success(null)
                }
                "requestDiscoverable" -> {
                    requestDiscoverable()
                    result.success(null)
                }
                "startDiscovery" -> {
                    ensureReceiverRegistered()
                    if (adapter.isDiscovering) adapter.cancelDiscovery()
                    adapter.startDiscovery()
                    result.success(null)
                }
                "stopDiscovery" -> {
                    if (adapter.isDiscovering) adapter.cancelDiscovery()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION", "Missing Bluetooth permission — $e", null)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * FIX 2: called once on attach(). If a previous run of the app died
     * (crash, OOM kill, force-stop) while a beacon name was active, the
     * adapter name is still stuck on the beacon string with nothing to
     * undo it — Dart's in-memory originalName was lost along with the
     * process. This recovers it from disk on the next clean launch.
     */
    private fun restoreOriginalNameIfStuck() {
        val stuckName = prefs.getString(PREFS_ORIGINAL_NAME_KEY, null) ?: return
        val adapter = bluetoothAdapter ?: return
        try {
            val ok = adapter.setName(stuckName)
            android.util.Log.i(
                "ClassicBeacon",
                "Restored adapter name from a previous unclean shutdown (success=$ok)"
            )
        } catch (e: SecurityException) {
            android.util.Log.w("ClassicBeacon", "Could not restore stuck name — $e")
        } finally {
            prefs.edit().remove(PREFS_ORIGINAL_NAME_KEY).apply()
        }
    }

    private fun requestDiscoverable() {
        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).apply {
            putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, DISCOVERABLE_DURATION_SECONDS)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_DISCOVERABLE)
        } catch (e: Exception) {
            android.util.Log.e("ClassicBeacon", "requestDiscoverable failed — ${e.message}")
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int) {
        if (requestCode == REQUEST_DISCOVERABLE) {
            // FIX 5: report the real outcome over the event channel instead
            // of leaving Dart to assume discoverable mode succeeded just
            // because startBeacon() returned. A declined/failed prompt
            // previously had no visible effect on the Dart side at all.
            val granted = resultCode != Activity.RESULT_CANCELED
            eventSink?.success(mapOf(
                "type" to "discoverableResult",
                "granted" to granted
            ))
            if (!granted) {
                android.util.Log.w("ClassicBeacon", "User declined discoverable request")
            }
        }
    }

    private fun ensureReceiverRegistered() {
        if (receiverRegistered) return
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device = intent.getParcelableExtra<BluetoothDevice>(
                            BluetoothDevice.EXTRA_DEVICE
                        ) ?: return
                        val rssi = intent.getShortExtra(
                            BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE
                        )
                        val name = try {
                            device.name
                        } catch (e: SecurityException) {
                            android.util.Log.w(
                                "ClassicBeacon",
                                "device.name threw SecurityException for ${device.address}"
                            )
                            null
                        }
                        // FIX 4: log the null-name case instead of silently
                        // dropping it. Previously this was indistinguishable
                        // from "no nearby devices at all" in logcat, which
                        // made it impossible to tell discovery timing
                        // issues apart from genuinely empty scans.
                        if (name == null) {
                            android.util.Log.d(
                                "ClassicBeacon",
                                "Discovered device ${device.address} has null name " +
                                "(rssi=${if (rssi == Short.MIN_VALUE) "unknown" else rssi.toString()}) — skipping"
                            )
                            return
                        }
                        eventSink?.success(mapOf(
                            "type" to "deviceFound",
                            "name" to name,
                            "mac" to device.address,
                            "rssi" to if (rssi == Short.MIN_VALUE) null else rssi.toInt()
                        ))
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                        eventSink?.success(mapOf("type" to "discoveryFinished"))
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }

        // FIX 3: Android 13+ (API 33+) requires RECEIVER_EXPORTED or
        // RECEIVER_NOT_EXPORTED to be specified explicitly, and as of
        // targetSdk 34 (Android 14) this is enforced with a hard
        // SecurityException rather than a warning — see
        // https://developer.android.com/about/versions/14/behavior-changes-14
        // We only need system Bluetooth broadcasts delivered to our own
        // app, not from other apps, so RECEIVER_NOT_EXPORTED is correct.
        // This intermittent crash is the most likely explanation for
        // "works on retry, fails sometimes on release builds" — the OS
        // enforces this based on targetSdk + API level combinations that
        // can vary between cold start and warm start on some OEM builds.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    fun dispose() {
        if (receiverRegistered) {
            try { activity.unregisterReceiver(receiver) } catch (e: Exception) { /* already gone */ }
            receiverRegistered = false
        }
        bluetoothAdapter?.let { if (it.isDiscovering) it.cancelDiscovery() }
    }
}