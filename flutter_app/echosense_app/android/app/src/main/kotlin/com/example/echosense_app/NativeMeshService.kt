package com.example.echosense_app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * ResQNet — Native BLE Mesh Scanning + Advertising Attempt (STAGE 4)
 * ========================================================
 * SCOPE DECISION: BLE advertising has failed identically on every
 * device tested in this project so far, via flutter_ble_peripheral,
 * with PlatformException(18, UNDOCUMENTED, startAdvertisingSet, null)
 * — a real, unresolved hardware/chipset-level limitation, not a
 * Flutter-vs-native problem. Given that history, the agreed approach
 * here is: attempt native advertising once for real, using the give-
 * up-after-N-consecutive-failures pattern mesh_service.dart's
 * _bleAdvertisingUnsupported already uses — if it fails the same way
 * natively, that confirms the limitation cleanly rather than wasting
 * further effort chasing it, and scanning (which has never failed in
 * this project) still provides real value on its own:
 *   - SCANNING: detects nearby ResQNet BLE packets while the app is
 *     fully closed, and forwards any NEW packet straight to the
 *     dashboard via HTTP — mirroring mesh_service.dart's
 *     _forwardToDashboard() exactly (same JSON shape, same endpoint).
 *   - ADVERTISING: attempted via the genuine native
 *     BluetoothLeAdvertiser API (a different, more direct API surface
 *     than flutter_ble_peripheral wraps) — if onStartFailure() fires
 *     ADVERTISE_FAILURE_GIVEUP_THRESHOLD times in a row, gives up for
 *     the session, exactly like the Dart pipeline already does.
 *
 * NOT INCLUDED: true multi-hop relay (re-broadcasting a received
 * packet onward to other phones) depends on advertising working —
 * since that's unproven on this hardware, a native scanner that
 * receives a packet can forward it to the dashboard (this device
 * has connectivity), but cannot guarantee relaying it further over
 * BLE to phones that don't have connectivity. This is a narrower
 * behaviour than the Dart pipeline's full mesh hop relay, by design,
 * given the advertising uncertainty.
 *
 * PACKET FORMAT: verified byte-for-byte against the real
 * MeshPacket.toBytes()/fromBytes() in mesh_service.dart — 20 bytes,
 * all multi-byte fields big-endian (confirmed via direct Python
 * struct-packing cross-check before writing this parser, not
 * assumed): networkId(u16,0-1) originId(u16,2-3) relayId(u16,4-5)
 * seqNum(u8,6) ttl(u8,7) confidence(u8,8,0-100) latitude(f32,9-12)
 * longitude(f32,13-16) battery(u8,17) hopCount(u8,18) soundCode(u8,19).
 */
class NativeMeshService(private val context: Context) {

    companion object {
        private const val TAG = "NativeMeshService"
        private const val MANUFACTURER_ID = 0x1234
        private const val NETWORK_ID = 0xBEEF
        private const val PAYLOAD_BYTES = 20

        // Matches mesh_service.dart's ADVERTISE_FAILURE_GIVEUP_THRESHOLD
        // exactly — same reasoning: stop retrying once it's clearly not
        // going to work on this device's hardware/chipset, rather than
        // retrying forever and draining battery during a real emergency.
        private const val ADVERTISE_FAILURE_GIVEUP_THRESHOLD = 5

        // BURST SCANNING, NOT CONTINUOUS — this was a real fix, not a
        // speculative one: real-device testing showed false-positive
        // CNN detections ("Screaming at 100%" on a silent room) start
        // appearing specifically after continuous SCAN_MODE_LOW_LATENCY
        // BLE scanning was added, with audio capture otherwise
        // unchanged. The working theory: continuous low-latency BLE
        // scanning is genuinely CPU/radio-intensive, and on shared
        // hardware this can disrupt AudioRecord's capture timing
        // enough to corrupt chunks feeding the CNN. The fix: scan in
        // short bursts with real gaps in between — giving the capture
        // thread guaranteed quiet windows — mirroring
        // mesh_service.dart's own SCAN_BURST_INTERVAL_S/
        // SCAN_BURST_DURATION_S pattern, which already exists there
        // for an analogous reason (avoiding BLE radio conflicts with
        // its own advertising). SCAN_MODE_BALANCED is also used
        // instead of LOW_LATENCY — lower CPU/radio intensity per
        // Android's own documented scan-mode tradeoffs, accepting
        // somewhat slower nearby-device discovery in exchange for less
        // resource contention with audio capture.
        private const val SCAN_BURST_DURATION_MS = 4_000L
        private const val SCAN_BURST_GAP_MS = 8_000L
    }

    data class MeshPacket(
        val networkId: Int,
        val originId: Int,
        val relayId: Int,
        val seqNum: Int,
        val ttl: Int,
        val confidencePct: Int, // 0-100, matches the Dart packet's wire format
        val latitude: Float,
        val longitude: Float,
        val battery: Int,
        val hopCount: Int,
        val soundCode: Int
    ) {
        val dedupKey: String get() = "${originId}_$seqNum"

        val soundTypeFull: String get() = when (soundCode) {
            0x43 -> "CNN Distress Detection"
            0x42 -> "Acoustic Beacon"
            else -> "Manual SOS"
        }

        fun toBytes(): ByteArray {
            val buf = ByteBuffer.allocate(PAYLOAD_BYTES).order(ByteOrder.BIG_ENDIAN)
            buf.putShort(networkId.toShort())
            buf.putShort(originId.toShort())
            buf.putShort(relayId.toShort())
            buf.put(seqNum.toByte())
            buf.put(ttl.toByte())
            buf.put(confidencePct.coerceIn(0, 100).toByte())
            buf.putFloat(latitude)
            buf.putFloat(longitude)
            buf.put(battery.coerceIn(0, 100).toByte())
            buf.put(hopCount.coerceIn(0, 10).toByte())
            buf.put(soundCode.toByte())
            return buf.array()
        }

        companion object {
            // Manual big-endian parsing — Kotlin/Java has no direct
            // equivalent to Dart's ByteData convenience wrapper, but
            // ByteBuffer.order(BIG_ENDIAN) reading unsigned bytes/shorts
            // produces identical values, verified via a Python
            // struct-packing round-trip test before this was written.
            fun fromBytes(bytes: ByteArray): MeshPacket {
                require(bytes.size >= PAYLOAD_BYTES) {
                    "Short packet: ${bytes.size} < $PAYLOAD_BYTES"
                }
                val buf = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
                val networkId = buf.short.toInt() and 0xFFFF
                val originId = buf.short.toInt() and 0xFFFF
                val relayId = buf.short.toInt() and 0xFFFF
                val seqNum = buf.get().toInt() and 0xFF
                val ttl = buf.get().toInt() and 0xFF
                val confidencePct = buf.get().toInt() and 0xFF
                val latitude = buf.float
                val longitude = buf.float
                val battery = buf.get().toInt() and 0xFF
                val hopCount = buf.get().toInt() and 0xFF
                val soundCode = buf.get().toInt() and 0xFF
                return MeshPacket(
                    networkId, originId, relayId, seqNum, ttl, confidencePct,
                    latitude, longitude, battery, hopCount, soundCode
                )
            }
        }
    }

    private val seenKeys = mutableMapOf<String, Long>()
    private var consecutiveAdvertiseFailures = 0
    @Volatile var bleAdvertisingUnsupported = false
        private set

    private var bluetoothLeScanner: BluetoothLeScanner? = null
    private var bluetoothLeAdvertiser: BluetoothLeAdvertiser? = null
    private var scanCallback: ScanCallback? = null
    @Volatile private var isScanning = false
    @Volatile private var burstModeWanted = false
    private var burstScheduler: ScheduledExecutorService? = null
    private var pendingPacketCallback: ((MeshPacket) -> Unit)? = null

    // ── Permission check ────────────────────────────────────────
    private fun hasBlePermissions(): Boolean {
        val scan = ContextCompat.checkSelfPermission(
            context, Manifest.permission.BLUETOOTH_SCAN
        ) == PackageManager.PERMISSION_GRANTED
        val advertise = ContextCompat.checkSelfPermission(
            context, Manifest.permission.BLUETOOTH_ADVERTISE
        ) == PackageManager.PERMISSION_GRANTED
        val connect = ContextCompat.checkSelfPermission(
            context, Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
        if (!scan || !advertise || !connect) {
            Log.e(TAG, "Missing BLE runtime permission(s) — scan=$scan " +
                    "advertise=$advertise connect=$connect. These are normally " +
                    "granted via the Flutter UI flow (BluetoothPermissions); a " +
                    "native-only detection cannot prompt for them itself, since " +
                    "showing a permission dialog requires an Activity.")
            return false
        }
        return true
    }

    private fun getAdapter(): BluetoothAdapter? {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter
    }

    // ── Scanning ─────────────────────────────────────────────────
    /**
     * Starts BURST-mode BLE scanning for nearby ResQNet packets —
     * short scan windows with real gaps in between, NOT continuous
     * scanning. See the SCAN_BURST_* constants above for the full
     * rationale (this replaced continuous LOW_LATENCY scanning after
     * it was identified as the likely cause of real-device CNN false
     * positives). onNewPacket is invoked once per genuinely new packet
     * (deduped by originId+seqNum, mirroring mesh_service.dart's
     * _seenKeys exactly) — the caller (DistressDetectionService)
     * decides what to do with it; this class itself also independently
     * forwards every new packet to the dashboard via
     * forwardToDashboard(), since that part has no further decision
     * to make.
     */
    fun startScanning(onNewPacket: (MeshPacket) -> Unit) {
        if (burstModeWanted) {
            Log.i(TAG, "startScanning() — burst cycle already running, ignoring")
            return
        }
        if (!hasBlePermissions()) return

        pendingPacketCallback = onNewPacket
        burstModeWanted = true

        val scheduler = Executors.newSingleThreadScheduledExecutor()
        burstScheduler = scheduler

        // Run the first burst immediately, then repeat at
        // (burst + gap) intervals — each cycle: scan for
        // SCAN_BURST_DURATION_MS, then stay quiet for
        // SCAN_BURST_GAP_MS, giving AudioRecord guaranteed
        // uninterrupted capture windows in between.
        scheduler.scheduleWithFixedDelay({
            if (!burstModeWanted) return@scheduleWithFixedDelay
            startSingleBurst()
        }, 0, SCAN_BURST_DURATION_MS + SCAN_BURST_GAP_MS, TimeUnit.MILLISECONDS)

        Log.i(TAG, "Native BLE burst-scan cycle started — " +
                "${SCAN_BURST_DURATION_MS}ms scan / ${SCAN_BURST_GAP_MS}ms quiet, repeating")
    }

    private fun startSingleBurst() {
        val adapter = getAdapter()
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "Bluetooth adapter unavailable or disabled — skipping this burst")
            return
        }

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            Log.w(TAG, "bluetoothLeScanner is null — skipping this burst")
            return
        }
        bluetoothLeScanner = scanner

        // SCAN_MODE_BALANCED rather than LOW_LATENCY — see the
        // SCAN_BURST_* constants comment for why. Combined with
        // running only in short bursts (not continuously), this
        // meaningfully reduces sustained CPU/radio load compared to
        // the original continuous LOW_LATENCY approach.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val cb = pendingPacketCallback ?: return
                handleScanResult(result, cb)
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "BLE scan burst failed — errorCode=$errorCode")
            }
        }
        scanCallback = callback

        try {
            scanner.startScan(null, settings, callback)
            isScanning = true
        } catch (e: SecurityException) {
            Log.e(TAG, "startScan() SecurityException — $e")
            return
        } catch (e: Exception) {
            Log.e(TAG, "startScan() failed — $e")
            return
        }

        // Schedule this single burst's own stop after
        // SCAN_BURST_DURATION_MS — independent of the outer repeating
        // schedule, so a burst always ends on time even if the next
        // scheduled burst-start is still SCAN_BURST_GAP_MS away.
        burstScheduler?.schedule({
            stopSingleBurst()
        }, SCAN_BURST_DURATION_MS, TimeUnit.MILLISECONDS)
    }

    private fun stopSingleBurst() {
        try {
            val callback = scanCallback
            if (callback != null) {
                bluetoothLeScanner?.stopScan(callback)
            }
        } catch (e: Exception) {
            Log.w(TAG, "stopScan() threw — $e")
        }
        isScanning = false
        scanCallback = null
    }

    fun stopScanning() {
        burstModeWanted = false
        burstScheduler?.shutdownNow()
        burstScheduler = null
        stopSingleBurst()
        pendingPacketCallback = null
        Log.i(TAG, "Native BLE burst-scan cycle stopped")
    }

    private fun handleScanResult(result: ScanResult, onNewPacket: (MeshPacket) -> Unit) {
        val record = result.scanRecord ?: return
        val payload = record.getManufacturerSpecificData(MANUFACTURER_ID) ?: return
        if (payload.size < PAYLOAD_BYTES) return

        val packet = try {
            MeshPacket.fromBytes(payload)
        } catch (e: Exception) {
            Log.w(TAG, "Packet parse error — $e")
            return
        }

        if (packet.networkId != NETWORK_ID) {
            // Same manufacturer ID collision/garbage-data guard as
            // mesh_service.dart's _handlePacket() networkId check.
            return
        }

        if (seenKeys.containsKey(packet.dedupKey)) {
            return // already processed — expected and frequent, not an error
        }
        seenKeys[packet.dedupKey] = System.currentTimeMillis()

        Log.i(TAG, "NEW mesh packet — origin=${packet.originId} " +
                "relay=${packet.relayId} ttl=${packet.ttl} hop=${packet.hopCount} " +
                "type=${packet.soundTypeFull}")

        forwardToDashboard(packet)
        onNewPacket(packet)

        cleanupOldSeenKeys()
    }

    private fun cleanupOldSeenKeys() {
        val tenMinutesMs = 10 * 60 * 1000L
        val now = System.currentTimeMillis()
        seenKeys.entries.removeAll { now - it.value > tenMinutesMs }
    }

    // ── Dashboard forwarding ─────────────────────────────────────
    // Matches mesh_service.dart's _forwardToDashboard() exactly: same
    // JSON shape (including the mesh-specific fields it adds beyond
    // the basic alert shape — mesh_relay, hop_count, origin_id,
    // relay_id, ttl), same endpoint, same 5s timeout, same IP read
    // path (FlutterSharedPreferences with the flutter. key prefix).
    private fun forwardToDashboard(packet: MeshPacket) {
        val cleanIp = getDashboardIp()
        if (cleanIp.isEmpty()) {
            Log.w(TAG, "No dashboard IP — skipping mesh packet forward")
            return
        }

        val body = JSONObject().apply {
            put("latitude", packet.latitude.toDouble())
            put("longitude", packet.longitude.toDouble())
            put("confidence", packet.confidencePct / 100.0)
            put("sound_type", "${packet.soundTypeFull} [Mesh hop ${packet.hopCount}]")
            put("battery", packet.battery)
            put("timestamp", java.text.SimpleDateFormat(
                "yyyy-MM-dd HH:mm:ss", java.util.Locale.US
            ).format(java.util.Date()))
            put("mesh_relay", true)
            put("hop_count", packet.hopCount)
            put("origin_id", packet.originId)
            put("relay_id", packet.relayId)
            put("ttl", packet.ttl)
        }

        try {
            val url = URL("http://$cleanIp:5000/alert")
            val connection = url.openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/json")
                connection.connectTimeout = 5_000
                connection.readTimeout = 5_000
                connection.doOutput = true
                OutputStreamWriter(connection.outputStream).use { writer ->
                    writer.write(body.toString())
                    writer.flush()
                }
                val code = connection.responseCode
                Log.i(TAG, "Mesh packet dashboard forward — ${if (code == 200) "✓" else "failed $code"}")
            } finally {
                connection.disconnect()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Mesh packet dashboard forward failed — $e")
        }
    }

    private fun getDashboardIp(): String {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("flutter.dashboard_ip", "") ?: ""
        var ip = raw.trim().replace("%20", "").replace(" ", "")
        if (ip.isEmpty()) return ""
        if (ip.contains("://")) ip = ip.substringAfter("://")
        ip = ip.substringBefore("/")
        if (ip.contains(":")) ip = ip.substringBefore(":")
        return ip
    }

    // ── Advertising attempt ──────────────────────────────────────
    /**
     * Attempts to advertise the given packet via the native
     * BluetoothLeAdvertiser API. Per the agreed scope: try this for
     * real, and if onStartFailure() fires repeatedly, conclude the
     * hardware doesn't support it (mirroring
     * mesh_service.dart's _recordAdvertiseFailure()/
     * _bleAdvertisingUnsupported exactly) and stop attempting for the
     * rest of this service's lifetime, rather than retrying forever.
     */
    fun attemptAdvertise(packet: MeshPacket) {
        if (bleAdvertisingUnsupported) {
            Log.i(TAG, "BLE advertising already concluded unsupported this " +
                    "session — skipping attempt (scanning/dashboard-forward " +
                    "unaffected)")
            return
        }
        if (!hasBlePermissions()) return

        val adapter = getAdapter()
        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "Bluetooth adapter unavailable or disabled — cannot advertise")
            return
        }

        val advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(TAG, "bluetoothLeAdvertiser is null — device does not support " +
                    "BLE peripheral/advertising mode at all")
            recordAdvertiseFailure()
            return
        }
        bluetoothLeAdvertiser = advertiser

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .setTimeout(0)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addManufacturerData(MANUFACTURER_ID, packet.toBytes())
            .build()

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                Log.i(TAG, "Native BLE advertising started successfully — " +
                        "origin=${packet.originId}")
                consecutiveAdvertiseFailures = 0
            }

            override fun onStartFailure(errorCode: Int) {
                Log.e(TAG, "Native BLE advertising failed — errorCode=$errorCode. " +
                        "This is the same class of failure as the Dart pipeline's " +
                        "PlatformException(18, UNDOCUMENTED, startAdvertisingSet) — " +
                        "a real hardware/chipset limitation observed consistently " +
                        "across every device tested in this project so far, not a " +
                        "transient or Flutter-specific issue.")
                recordAdvertiseFailure()
            }
        }

        try {
            advertiser.startAdvertising(settings, data, callback)
        } catch (e: SecurityException) {
            Log.e(TAG, "startAdvertising() SecurityException — $e")
            recordAdvertiseFailure()
        } catch (e: Exception) {
            Log.e(TAG, "startAdvertising() failed — $e")
            recordAdvertiseFailure()
        }
    }

    fun stopAdvertising() {
        try {
            bluetoothLeAdvertiser?.stopAdvertising(object : AdvertiseCallback() {})
        } catch (e: Exception) {
            Log.w(TAG, "stopAdvertising() threw — $e")
        }
    }

    private fun recordAdvertiseFailure() {
        consecutiveAdvertiseFailures++
        if (consecutiveAdvertiseFailures >= ADVERTISE_FAILURE_GIVEUP_THRESHOLD &&
            !bleAdvertisingUnsupported
        ) {
            bleAdvertisingUnsupported = true
            Log.e(TAG, "✗ Native BLE advertising failed $consecutiveAdvertiseFailures " +
                    "times in a row — concluding this device's Bluetooth hardware " +
                    "does not support BLE advertising, confirming the same " +
                    "limitation already observed in the Dart pipeline via " +
                    "flutter_ble_peripheral. Giving up on native BLE advertising " +
                    "for this session. Scanning, dashboard-forwarding, SMS, " +
                    "Telegram, and dashboard POST all remain fully active and " +
                    "unaffected by this.")
        }
    }

    fun dispose() {
        stopScanning()
        stopAdvertising()
        seenKeys.clear()
    }
}