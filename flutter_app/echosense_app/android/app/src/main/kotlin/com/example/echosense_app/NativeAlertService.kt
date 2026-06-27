package com.example.echosense_app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Looper
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * ResQNet — Native Alert-Sending Service (STAGE 3)
 * ========================================================
 * On a confirmed distress detection from the native Kotlin pipeline
 * (DistressDetectionService + NativeDetectionService), this class
 * sends the actual emergency alert — SMS, dashboard HTTP POST, and
 * Telegram — entirely independent of whether the Flutter engine is
 * alive, the same way the rest of the native pipeline already is.
 *
 * Every wire format here was copied directly from the real,
 * currently-working sms_service.dart, not approximated, so a native
 * detection produces an alert indistinguishable from a Dart-pipeline
 * alert on the receiving end (same SMS text, same dashboard JSON
 * shape, same Telegram Markdown formatting):
 *   - SMS sending mirrors MainActivity.kt's existing "sendSms"
 *     MethodChannel handler exactly (same SmsManager acquisition
 *     pattern for API 31+ vs below, same divideMessage()/
 *     sendMultipartTextMessage() handling for long messages) — just
 *     called directly instead of through a MethodChannel, since
 *     there's no Flutter engine to channel through here.
 *   - Dashboard POST matches _sendToDashboard() in sms_service.dart:
 *     same JSON keys, same http://<ip>:5000/alert endpoint, same
 *     5s timeout.
 *   - Telegram POST matches _sendTelegram() in sms_service.dart:
 *     same bot token/chat ID, same Markdown text format, same
 *     10s timeout.
 *
 * LOCATION: fetched natively via Android's plain LocationManager —
 * first tries getLastKnownLocation() across both GPS and network
 * providers (instant, no waiting), and if neither has anything,
 * actively requests a fresh fix via requestLocationUpdates() bounded
 * to LOCATION_REQUEST_TIMEOUT_SECONDS before giving up. This was
 * upgraded from an immediate last-known-only approach after real
 * testing showed every alert reporting "No GPS" — relying solely on
 * getLastKnownLocation() assumes some other app recently requested a
 * fix, which isn't a safe assumption to make for an emergency app
 * that needs to work reliably regardless of what else is running.
 * Uses plain LocationManager rather than Google Play Services'
 * FusedLocationProviderClient — deliberately, to avoid pulling in an
 * extra Play Services dependency into a native-only code path whose
 * whole point is minimal, independent operation. If even the bounded
 * fresh-fix request times out (e.g. deep indoors with no satellite
 * visibility and no network-based fix available either), this still
 * falls back to (0.0, 0.0) — a real, documented limitation for that
 * specific case, since there is no way to synthesize a location that
 * genuinely cannot be acquired.
 *
 * IP SANITIZATION: dashboard_ip is sanitized here too, mirroring
 * sms_service.dart's _sanitizeIp() exactly — defense in depth, given
 * the documented historical bug where a stored IP containing a port
 * suffix silently corrupted the constructed URL. The native read
 * shouldn't have to trust that the value already in SharedPreferences
 * is clean, the same reasoning sms_service.dart itself already
 * applies on both read and write.
 */
class NativeAlertService(private val context: Context) {

    companion object {
        private const val TAG = "NativeAlertService"

        // Same hardcoded credentials as sms_service.dart — copied
        // directly, not re-derived, so both pipelines hit the same
        // bot/chat.
        private const val TELEGRAM_BOT_TOKEN =
            "8835166426:AAGgI_j20eSBK0Tv2koxTF17f29-1iN4MUs"
        private const val TELEGRAM_CHAT_ID = "8418739667"

        private const val FALLBACK_PHONE = "+64225012439"

        // Flutter's shared_preferences plugin stores its data in a
        // SharedPreferences file literally named
        // "FlutterSharedPreferences", with every key automatically
        // prefixed "flutter." — confirmed via the plugin's own
        // documented behaviour, not assumed. Getting this wrong would
        // silently return an empty string here, no error, which is
        // exactly the kind of failure that's hard to debug later.
        private const val PREFS_FILE_NAME = "FlutterSharedPreferences"
        private const val PREFS_KEY_PREFIX = "flutter."
        private const val DASHBOARD_IP_KEY = "dashboard_ip"

        // Bound on how long to wait for a FRESH GPS/network fix when
        // no last-known location exists at all. Long enough to give a
        // real fix a genuine chance (GPS cold-start can take several
        // seconds), short enough not to delay an emergency alert
        // excessively if the device truly cannot get a fix right now
        // (e.g. deep indoors with no last-known history).
        private const val LOCATION_REQUEST_TIMEOUT_SECONDS = 8L

        // How old a proactively cached location is allowed to be
        // before we fall through to a fresh fetch at alert time.
        private const val CACHED_LOCATION_MAX_AGE_MS = 10 * 60 * 1000L  // 10 minutes
    }

    // ── Proactive location cache ────────────────────────────────────
    // Root cause of 0.0,0.0: on Android 10+ a foreground service with
    // only foregroundServiceType="microphone" cannot access location
    // at the cold moment sendAlert() is called — getLastKnownLocation()
    // silently returns null and the fresh-fix request times out.
    //
    // Fix: start continuous location tracking as soon as Disaster Mode
    // activates (called from DistressDetectionService.onCreate()). The
    // first update arrives within seconds on any device that has a
    // recent or active GPS/network fix, and all subsequent updates keep
    // the cache fresh. At alert time we use the cached value, which is
    // always available (no cold-start race).
    private val cachedLocation = java.util.concurrent.atomic.AtomicReference<android.location.Location?>(null)
    private var activeLocationManager: android.location.LocationManager? = null
    private var activeLocationListener: android.location.LocationListener? = null

    data class AlertResult(
        val smsSent: Boolean,
        val dashboardSent: Boolean,
        val telegramSent: Boolean
    )

    /**
     * Sends the full alert (SMS + dashboard + Telegram), mirroring
     * sendSosAlert() in sms_service.dart. Each channel is attempted
     * independently — one failing doesn't block the others, matching
     * the Dart version's behaviour exactly (it already treats SMS,
     * Telegram, and dashboard as independent try/catch blocks).
     *
     * Location is fetched internally via getLastKnownLocation()
     * rather than required as a parameter, so callers (e.g.
     * DistressDetectionService) don't need their own location logic —
     * this class owns the full alert lifecycle end to end.
     */
    fun sendAlert(
        confidence: Double,
        soundType: String,
        batteryLevel: Int
    ): AlertResult {
        val (latitude, longitude) = getLastKnownLocation()
        val mapsLink =
            "https://www.google.com/maps/search/?api=1&query=$latitude,$longitude"
        val confPct = (confidence * 100).toInt().toString()
        val time = formatTime(Date())

        val message = "ResQNet EMERGENCY ALERT\n\n" +
                "Distress detected: $soundType ($confPct% confidence)\n" +
                "Location: $mapsLink\n" +
                "Time: $time\n" +
                "Battery: $batteryLevel%\n\n" +
                "Sent automatically by ResQNet.\n" +
                "Please contact emergency services immediately."

        val recipients = getContactPhoneNumbers()
        val smsSent = if (recipients.isEmpty()) {
            Log.w(TAG, "No contacts found in database — using fallback number")
            sendNativeSms(message, listOf(FALLBACK_PHONE))
        } else {
            Log.i(TAG, "Sending native SMS to ${recipients.size} contacts")
            sendNativeSms(message, recipients)
        }

        val telegramSent = sendTelegram(
            soundType = soundType,
            confPct = confPct,
            mapsLink = mapsLink,
            time = time
        )

        val dashboardSent = sendToDashboard(
            latitude = latitude,
            longitude = longitude,
            confidence = confidence,
            soundType = soundType,
            battery = batteryLevel,
            timestamp = time
        )

        return AlertResult(smsSent, dashboardSent, telegramSent)
    }

    // ── Proactive location tracking (called from DistressDetectionService) ──

    /**
     * Starts continuous location updates as soon as Disaster Mode
     * activates. Pre-warms the cache immediately from last-known,
     * then registers a listener for ongoing updates so the cache
     * stays fresh throughout the monitoring session.
     *
     * Called from DistressDetectionService.onCreate() — before any
     * detection even starts — so by the time an alert fires there is
     * already a recent fix available without any cold-start wait.
     *
     * MANIFEST NOTE: for this to work in background on Android 10+,
     * AndroidManifest.xml must declare:
     *   1. <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
     *   2. The DistressDetectionService entry must include:
     *      android:foregroundServiceType="microphone|location"
     * Without those, getLastKnownLocation() returns null silently.
     */
    fun startLocationTracking() {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) != PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_COARSE_LOCATION
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "Location permission not granted — proactive tracking skipped. " +
                    "GPS will fall back to (0.0,0.0) if no last-known fix is available.")
            return
        }

        try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE)
                    as android.location.LocationManager
            activeLocationManager = lm

            // Pre-warm: grab any existing last-known fix immediately
            for (provider in listOf(
                android.location.LocationManager.GPS_PROVIDER,
                android.location.LocationManager.NETWORK_PROVIDER
            )) {
                try {
                    @Suppress("MissingPermission")
                    val loc = lm.getLastKnownLocation(provider)
                    if (loc != null) {
                        val current = cachedLocation.get()
                        if (current == null || loc.time > current.time) {
                            cachedLocation.set(loc)
                            Log.i(TAG, "Pre-warmed location from $provider: " +
                                    "${loc.latitude}, ${loc.longitude} " +
                                    "(accuracy=${loc.accuracy}m)")
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Pre-warm from $provider skipped — $e")
                }
            }

            // Register listener for ongoing updates
            val listener = object : android.location.LocationListener {
                override fun onLocationChanged(location: android.location.Location) {
                    cachedLocation.set(location)
                    Log.i(TAG, "Location cache updated: " +
                            "${location.latitude}, ${location.longitude} " +
                            "(accuracy=${location.accuracy}m " +
                            "provider=${location.provider})")
                }
                @Suppress("DEPRECATION")
                override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
                override fun onProviderEnabled(p: String) {}
                override fun onProviderDisabled(p: String) {
                    Log.w(TAG, "Location provider disabled: $p")
                }
            }
            activeLocationListener = listener

            // Register on both providers — network is faster indoors,
            // GPS is more accurate outdoors. Update every 30s or 10m
            // change — enough to keep the cache fresh without draining
            // battery during a potentially long Disaster Mode session.
            for (provider in listOf(
                android.location.LocationManager.NETWORK_PROVIDER,
                android.location.LocationManager.GPS_PROVIDER
            )) {
                try {
                    if (lm.isProviderEnabled(provider)) {
                        @Suppress("MissingPermission")
                        lm.requestLocationUpdates(
                            provider,
                            30_000L,  // min time: 30 seconds
                            10f,      // min distance: 10 metres
                            listener,
                            android.os.Looper.getMainLooper()
                        )
                        Log.i(TAG, "Proactive location tracking started on $provider")
                    } else {
                        Log.w(TAG, "Provider $provider is disabled on this device")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to register on $provider — $e")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "startLocationTracking() failed — $e")
        }
    }

    /** Removes the location listener registered by startLocationTracking(). */
    fun stopLocationTracking() {
        try {
            activeLocationListener?.let {
                activeLocationManager?.removeUpdates(it)
                Log.i(TAG, "Proactive location tracking stopped")
            }
        } catch (e: Exception) {
            Log.w(TAG, "stopLocationTracking() cleanup error — $e")
        } finally {
            activeLocationListener = null
            activeLocationManager = null
        }
    }

    // ── Last-known location via plain Android LocationManager ──────
    // Tries both GPS and network providers (a device may have a
    // recent fix on only one of them, especially indoors), and picks
    // whichever is more recent. Falls back to (0.0, 0.0) if neither
    // provider has any last-known fix at all — a real, documented
    // limitation rather than a silent wrong answer, since there's no
    // way to invent a location that was never recorded.
    private fun getLastKnownLocation(): Pair<Double, Double> {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) != PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_COARSE_LOCATION
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "No location permission granted — sending alert with " +
                    "(0.0, 0.0). This permission is normally requested via the " +
                    "Flutter UI layer (geolocator); a native-only detection has " +
                    "no way to prompt for it itself, since showing a permission " +
                    "dialog requires an Activity.")
            return Pair(0.0, 0.0)
        }

        // ── Step 1: use proactively cached location if fresh enough ──
        cachedLocation.get()?.let { cached ->
            val ageMs = System.currentTimeMillis() - cached.time
            if (ageMs < CACHED_LOCATION_MAX_AGE_MS) {
                Log.i(TAG, "Using proactively cached location: " +
                        "${cached.latitude}, ${cached.longitude} " +
                        "(age=${ageMs / 1000}s accuracy=${cached.accuracy}m)")
                return Pair(cached.latitude, cached.longitude)
            } else {
                Log.w(TAG, "Cached location is stale (${ageMs / 1000}s old) — " +
                        "falling through to fresh fetch")
            }
        }

        return try {
            // ── Step 2: cold last-known fetch ─────────────────────────
            val locationManager =
                context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

            var best: Location? = null
            for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                try {
                    val candidate = locationManager.getLastKnownLocation(provider)
                    if (candidate != null &&
                        (best == null || candidate.time > best!!.time)
                    ) {
                        best = candidate
                    }
                } catch (e: SecurityException) {
                    Log.w(TAG, "Permission denied reading provider $provider — $e")
                } catch (e: IllegalArgumentException) {
                    Log.w(TAG, "Provider $provider not available on this device — $e")
                }
            }

            if (best != null) {
                Log.i(TAG, "Using cold last-known location: ${best.latitude}, ${best.longitude} " +
                        "(age=${(System.currentTimeMillis() - best.time) / 1000}s)")
                Pair(best.latitude, best.longitude)
            } else {
                // ── Step 3: request a fresh fix with bounded timeout ──
                Log.w(TAG, "No last-known location available — " +
                        "requesting fresh fix (bounded to " +
                        "${LOCATION_REQUEST_TIMEOUT_SECONDS}s)")
                requestFreshLocation(locationManager) ?: run {
                    Log.w(TAG, "Fresh location request also timed out — " +
                            "sending alert with (0.0, 0.0). " +
                            "Check AndroidManifest foregroundServiceType includes 'location'.")
                    Pair(0.0, 0.0)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Location fetch failed — $e — sending alert with (0.0, 0.0)")
            Pair(0.0, 0.0)
        }
    }

    /**
     * Actively requests a fresh location fix, bounded by
     * LOCATION_REQUEST_TIMEOUT_SECONDS, for the case where
     * getLastKnownLocation() has nothing at all to return (e.g. a
     * freshly-booted device, or one where no app has requested
     * location recently). Uses the older requestLocationUpdates() +
     * LocationListener API rather than the newer API-30+
     * getCurrentLocation(), since requestLocationUpdates() works
     * across a wider minSdk range and this project's existing
     * geolocator-based Dart pipeline already relies on similarly
     * broad compatibility.
     *
     * Uses a CountDownLatch to bridge the asynchronous
     * LocationListener callback into a synchronous return value,
     * since this is called from sendAlert(), which already runs on
     * its own background thread (DistressDetectionService's
     * DistressAlertThread) rather than the main thread — blocking
     * here briefly is acceptable and expected, not a UI-freezing risk.
     */
    private fun requestFreshLocation(locationManager: LocationManager): Pair<Double, Double>? {
        val resultRef = AtomicReference<Location?>(null)
        val latch = CountDownLatch(1)

        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                resultRef.set(location)
                latch.countDown()
            }
            @Suppress("DEPRECATION")
            override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
        }

        try {
            // Request from both providers — whichever responds first
            // wins; the GPS_PROVIDER request is removed as soon as
            // either fires, so this doesn't end up registered twice
            // indefinitely.
            val mainLooper = Looper.getMainLooper()
            for (provider in listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)) {
                try {
                    locationManager.requestLocationUpdates(provider, 0L, 0f, listener, mainLooper)
                } catch (e: IllegalArgumentException) {
                    Log.w(TAG, "Provider $provider unavailable for fresh fix request — $e")
                } catch (e: SecurityException) {
                    Log.w(TAG, "Permission denied requesting fresh fix from $provider — $e")
                }
            }

            val arrived = latch.await(LOCATION_REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            val location = resultRef.get()

            return if (arrived && location != null) {
                Log.i(TAG, "Fresh location fix acquired: ${location.latitude}, ${location.longitude}")
                Pair(location.latitude, location.longitude)
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "requestFreshLocation() failed — $e")
            return null
        } finally {
            try {
                locationManager.removeUpdates(listener)
            } catch (e: Exception) {
                Log.w(TAG, "removeUpdates() threw during cleanup — $e")
            }
        }
    }

    // ── Read emergency contacts directly from the real SQLite DB ──
    // sqflite stores resqnet.db at the standard Android app database
    // path (getDatabasesPath()/resqnet.db in Dart resolves to
    // /data/data/<package>/databases/resqnet.db) — readable directly
    // with plain Android SQLiteDatabase, no Flutter dependency,
    // confirmed against the real schema in database_service.dart.
    private fun getContactPhoneNumbers(): List<String> {
        val phones = mutableListOf<String>()
        var db: SQLiteDatabase? = null
        try {
            val dbPath = context.getDatabasePath("resqnet.db").path
            db = SQLiteDatabase.openDatabase(
                dbPath, null, SQLiteDatabase.OPEN_READONLY
            )
            val cursor = db.query(
                "contacts", arrayOf("phone"),
                null, null, null, null, null
            )
            cursor.use {
                while (it.moveToNext()) {
                    val phone = it.getString(it.getColumnIndexOrThrow("phone"))
                    if (phone.isNotBlank()) phones.add(phone.trim())
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read contacts from resqnet.db — $e")
        } finally {
            db?.close()
        }
        return phones
    }

    // ── Native SMS via SmsManager ──────────────────────────────────
    // Mirrors MainActivity.kt's existing "sendSms" handler exactly —
    // same permission check, same SmsManager acquisition, same
    // divideMessage()/sendMultipartTextMessage() handling for long
    // text — just called directly rather than through a MethodChannel.
    private fun sendNativeSms(message: String, recipients: List<String>): Boolean {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.SEND_SMS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "SEND_SMS permission not granted — cannot send native SMS. " +
                    "This permission is normally requested via MainActivity.kt's " +
                    "existing flow; if the app has never been opened and granted " +
                    "it once, a native-only detection has no way to prompt for it " +
                    "itself, since showing a permission dialog requires an Activity.")
            return false
        }

        return try {
            val smsManager = getSmsManager()
            var sentCount = 0

            for (phone in recipients) {
                val cleanPhone = phone.trim()
                if (cleanPhone.isEmpty()) continue

                val parts = smsManager.divideMessage(message)
                if (parts.size == 1) {
                    smsManager.sendTextMessage(cleanPhone, null, message, null, null)
                } else {
                    smsManager.sendMultipartTextMessage(
                        cleanPhone, null, parts, null, null
                    )
                }
                sentCount++
                Log.i(TAG, "SMS sent to $cleanPhone")
            }

            Log.i(TAG, "Native SMS result = SMS sent to $sentCount contacts")
            sentCount > 0
        } catch (e: Exception) {
            Log.e(TAG, "Native SMS failed — ${e.message}")
            false
        }
    }

    private fun getSmsManager(): SmsManager {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
                ?: SmsManager.getDefault()
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
    }

    // ── Telegram Bot ────────────────────────────────────────────────
    // Matches _sendTelegram() in sms_service.dart exactly: same
    // Markdown text layout, same endpoint, same 10s timeout.
    private fun sendTelegram(
        soundType: String,
        confPct: String,
        mapsLink: String,
        time: String
    ): Boolean {
        val text = "*ResQNet EMERGENCY ALERT*\n\n" +
                "*$soundType* ($confPct% confidence)\n" +
                "[View Location on Maps]($mapsLink)\n" +
                "$time\n\n" +
                "_Sent automatically by ResQNet._\n" +
                "_Please contact emergency services immediately._"

        val body = JSONObject().apply {
            put("chat_id", TELEGRAM_CHAT_ID)
            put("text", text)
            put("parse_mode", "Markdown")
        }

        val url = "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
        return try {
            val code = httpPostJson(url, body, timeoutMs = 10_000)
            if (code == 200) {
                Log.i(TAG, "Telegram alert sent ✓")
                true
            } else {
                Log.w(TAG, "Telegram failed — $code")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Telegram error — $e")
            false
        }
    }

    // ── Dashboard HTTP POST ──────────────────────────────────────────
    // Matches _sendToDashboard() in sms_service.dart exactly: same
    // JSON keys, same http://<ip>:5000/alert endpoint, same 5s timeout.
    private fun sendToDashboard(
        latitude: Double,
        longitude: Double,
        confidence: Double,
        soundType: String,
        battery: Int,
        timestamp: String
    ): Boolean {
        val cleanIp = sanitizeIp(getDashboardIpFromPrefs())
        if (cleanIp.isEmpty()) {
            Log.w(TAG, "No dashboard IP — skipping")
            return false
        }

        Log.i(TAG, "Posting to dashboard $cleanIp")

        val body = JSONObject().apply {
            put("latitude", latitude)
            put("longitude", longitude)
            put("confidence", confidence)
            put("sound_type", soundType)
            put("battery", battery)
            put("timestamp", timestamp)
        }

        val url = "http://$cleanIp:5000/alert"
        return try {
            val code = httpPostJson(url, body, timeoutMs = 5_000)
            if (code == 200 || code == 201) {
                Log.i(TAG, "Dashboard received alert ✓")
                true
            } else {
                Log.w(TAG, "Dashboard returned $code")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Dashboard post failed — $e")
            false
        }
    }

    // ── Shared plain HTTP POST helper ───────────────────────────────
    private fun httpPostJson(urlString: String, body: JSONObject, timeoutMs: Int): Int {
        val url = URL(urlString)
        val connection = url.openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.doOutput = true

            OutputStreamWriter(connection.outputStream).use { writer ->
                writer.write(body.toString())
                writer.flush()
            }

            connection.responseCode
        } finally {
            connection.disconnect()
        }
    }

    // ── Dashboard IP — read from Flutter's SharedPreferences file ──
    private fun getDashboardIpFromPrefs(): String {
        val prefs = context.getSharedPreferences(PREFS_FILE_NAME, Context.MODE_PRIVATE)
        return prefs.getString(PREFS_KEY_PREFIX + DASHBOARD_IP_KEY, "") ?: ""
    }

    // Mirrors _sanitizeIp() in sms_service.dart exactly — defense in
    // depth against the documented historical port-suffix bug, even
    // though the value should already be clean by the time it's
    // written, per that fix.
    private fun sanitizeIp(raw: String): String {
        var ip = raw.trim().replace("%20", "").replace(" ", "")
        if (ip.isEmpty()) return ""
        if (ip.contains("://")) {
            ip = ip.substringAfter("://")
        }
        ip = ip.substringBefore("/")
        if (ip.contains(":")) {
            ip = ip.substringBefore(":")
        }
        return ip
    }

    // ── Time formatter — matches _formatTime() in sms_service.dart ──
    private fun formatTime(date: Date): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
        return fmt.format(date)
    }
}