package com.tanksync.tanksync_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android Foreground Service that continuously monitors the HomeTank
 * device over the local home WiFi network.
 *
 * Key design notes:
 *  - Poll loop runs on a [ScheduledExecutorService] background thread —
 *    NOT on the main thread, so network I/O is always allowed.
 *  - A partial [PowerManager.WakeLock] keeps the CPU alive during polls
 *    when the screen is off.
 *  - All state tracking is done inside the background thread; only
 *    notification posting crosses to Android APIs (which are thread-safe).
 *  - Works only when connection_mode == "home_wifi"; skips polling otherwise.
 */
class TankMonitorService : Service() {

    // ── Constants ──────────────────────────────────────────────────────────

    companion object {
        private const val TAG = "TankMonitor"

        // Notification channel IDs
        const val CHANNEL_MONITOR = "tanksync_monitor"   // silent persistent bar
        const val CHANNEL_ALERTS  = "tanksync_alerts"    // heads-up event alerts

        // Foreground notification ID (must be > 0)
        private const val NOTIF_ID_FOREGROUND = 1

        // Event notification IDs
        private const val NOTIF_ID_TANK_FULL      = 100
        private const val NOTIF_ID_TANK_LOW       = 101
        private const val NOTIF_ID_PUMP_ON        = 102
        private const val NOTIF_ID_PUMP_OFF       = 103
        private const val NOTIF_ID_SAFETY_TRIP    = 104
        private const val NOTIF_ID_SAFETY_CLEAR   = 105
        private const val NOTIF_ID_DEVICE_OFFLINE = 106
        private const val NOTIF_ID_DEVICE_ONLINE  = 107
        private const val NOTIF_ID_TOP_OFFLINE    = 108
        private const val NOTIF_ID_LONG_RUN       = 109

        // SharedPreferences keys — must match Flutter AppPrefs key names with "flutter." prefix
        private const val PREFS_NAME        = "FlutterSharedPreferences"
        private const val KEY_DEVICE_IP     = "flutter.home_ip"
        private const val KEY_POLL_INTERVAL = "flutter.bg_poll_interval_seconds"
        private const val KEY_NOTIF_ENABLED = "flutter.notifications_enabled"
        private const val KEY_MODE          = "flutter.connection_mode"

        // Intent extras
        const val ACTION_UPDATE_CONFIG = "com.tanksync.UPDATE_CONFIG"
        const val EXTRA_DEVICE_IP      = "device_ip"
        const val EXTRA_POLL_INTERVAL  = "poll_interval"
        const val EXTRA_NOTIF_ENABLED  = "notifications_enabled"

        // Thresholds
        private const val TANK_FULL_PCT = 95.0
        private const val TANK_LOW_PCT  = 15.0
        private const val LONG_RUN_SEC  = 1500   // 25 min

        /** Checked by MainActivity to answer isRunning MethodChannel call. */
        @Volatile var isRunning = false
            private set

        /**
         * Holds the last raw JSON received — MainActivity can forward this to
         * the Flutter EventChannel stream while the app is in the foreground.
         */
        @Volatile var lastStatusJson: String? = null
            private set
    }

    // ── Runtime state (all accessed from the executor background thread) ───

    private lateinit var notifManager: NotificationManager
    private var wakeLock: PowerManager.WakeLock? = null

    /** Single-thread executor — ALL network calls happen here, never on main thread. */
    private lateinit var executor: ScheduledExecutorService
    private var scheduledFuture: ScheduledFuture<*>? = null

    @Volatile private var deviceIp: String = ""
    @Volatile private var pollIntervalMs: Long = 30_000L
    @Volatile private var notificationsEnabled: Boolean = true

    // Edge-detection state (only written from executor thread)
    private var prevPumpOn: Boolean? = null
    private var prevTopOnline: Boolean? = null
    private var prevSafetyTripped: Boolean? = null
    private var prevWater: Double? = null
    private var prevOnline: Boolean? = null
    private var consecutiveFailures = 0
    private var longRunNotifiedForCurrentCycle = false

    // ── Service lifecycle ──────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        executor = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "TankMonitor-poller").also { it.isDaemon = false }
        }
        createNotificationChannels()
        acquireWakeLock()
        loadConfigFromPrefs()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Apply config from the intent (may override prefs values)
        intent?.let { applyIntentConfig(it) }

        if (!isRunning) {
            isRunning = true
            // Post foreground notification immediately so Android doesn't ANR
            postForeground("Starting…")
            schedulePolling()
            Log.i(TAG, "Service started — ip=$deviceIp interval=${pollIntervalMs/1000}s")
        } else if (intent?.action == ACTION_UPDATE_CONFIG) {
            // Hot-update: reschedule with new interval
            Log.i(TAG, "Config updated — ip=$deviceIp interval=${pollIntervalMs/1000}s")
            schedulePolling()
        }

        // Restart with last intent if killed by OS
        return START_REDELIVER_INTENT
    }

    override fun onDestroy() {
        isRunning = false
        scheduledFuture?.cancel(false)
        executor.shutdown()
        releaseWakeLock()
        Log.i(TAG, "Service destroyed")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Poll scheduling ────────────────────────────────────────────────────

    private fun schedulePolling() {
        scheduledFuture?.cancel(false)
        scheduledFuture = executor.scheduleWithFixedDelay(
            ::poll,
            0L,                  // start immediately
            pollIntervalMs,
            TimeUnit.MILLISECONDS
        )
    }

    // ── Main poll function (runs on executor background thread) ───────────

    private fun poll() {
        val ip = deviceIp
        if (ip.isBlank()) {
            updateForegroundText("No device IP — check Settings → WiFi")
            return
        }

        // Guard: only poll in home_wifi mode
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val mode  = prefs.getString(KEY_MODE, "direct") ?: "direct"
        if (mode != "home_wifi") {
            updateForegroundText("Direct mode — background polling paused")
            return
        }

        try {
            val rawJson = httpGetRaw("http://$ip/api/status")
            val json    = JSONObject(rawJson)
            lastStatusJson = rawJson   // expose to EventChannel

            consecutiveFailures = 0
            val wasOffline = prevOnline == false
            prevOnline = true

            if (wasOffline) {
                fireNotification(NOTIF_ID_DEVICE_ONLINE,
                    "📡 HomeTank Online",
                    "Device is back online at $ip.")
            }

            processStatus(json)

        } catch (e: Exception) {
            consecutiveFailures++
            Log.w(TAG, "Poll #$consecutiveFailures failed: ${e.javaClass.simpleName}: ${e.message}")

            if (consecutiveFailures >= 3 && prevOnline != false) {
                prevOnline = false
                fireNotification(NOTIF_ID_DEVICE_OFFLINE,
                    "📡 HomeTank Offline",
                    "Device not responding at $ip. Check power & WiFi.")
            }

            val desc = if (consecutiveFailures >= 3)
                "⚠️ Device offline — retrying…"
            else
                "Connecting… (attempt $consecutiveFailures)"
            updateForegroundText(desc)
        }
    }

    // ── State change detection + notification firing ───────────────────────

    private fun processStatus(json: JSONObject) {
        val tank   = json.optJSONObject("tank")
        val safety = json.optJSONObject("safety")

        val water = (tank?.optDouble("pct") ?: json.optDouble("water", 0.0))
            .coerceIn(0.0, 100.0)
        val pumpOn        = json.optBoolean("relay", false) || json.optBoolean("pump", false)
        val topOnline     = json.optBoolean("online", true)
        val safetyTripped = safety?.optBoolean("tripped", false) ?: false
        val safetyAlert   = safety?.optString("alert", "") ?: ""
        val pumpRunSec    = safety?.optInt("pump_run_sec", 0) ?: 0
        val autoMode      = json.optBoolean("auto_mode", true)

        // ── Safety ──────────────────────────────────────────────────────
        if (safetyTripped && prevSafetyTripped != true) {
            val reason = if (safetyAlert.isNotBlank()) safetyAlert
                         else "Daily cycle or run-time limit reached."
            fireNotification(NOTIF_ID_SAFETY_TRIP,
                "⚠️ Safety Tripped",
                "$reason Pump is blocked.")
        } else if (!safetyTripped && prevSafetyTripped == true) {
            fireNotification(NOTIF_ID_SAFETY_CLEAR,
                "✅ Safety Cleared",
                "Safety interlock reset. Normal operation resumed.")
        }
        prevSafetyTripped = safetyTripped

        // ── Pump ────────────────────────────────────────────────────────
        if (pumpOn && prevPumpOn != true) {
            val who = if (autoMode) "auto mode" else "manual command"
            fireNotification(NOTIF_ID_PUMP_ON,
                "💧 Pump Started",
                "Pump turned ON via $who. Tank at ${water.toInt()}%.")
            longRunNotifiedForCurrentCycle = false
        } else if (!pumpOn && prevPumpOn == true) {
            fireNotification(NOTIF_ID_PUMP_OFF,
                "✅ Pump Stopped",
                "Pump turned OFF. Tank at ${water.toInt()}%.")
            longRunNotifiedForCurrentCycle = false
        }
        prevPumpOn = pumpOn

        // ── Long pump run ───────────────────────────────────────────────
        if (pumpOn && pumpRunSec >= LONG_RUN_SEC && !longRunNotifiedForCurrentCycle) {
            longRunNotifiedForCurrentCycle = true
            fireNotification(NOTIF_ID_LONG_RUN,
                "⚠️ Long Pump Run",
                "Pump running for ${pumpRunSec / 60} min. Check if tank is full.")
        }

        // ── Water level ─────────────────────────────────────────────────
        val prevW = prevWater
        if (water >= TANK_FULL_PCT && (prevW == null || prevW < TANK_FULL_PCT)) {
            fireNotification(NOTIF_ID_TANK_FULL,
                "🟢 Tank Full",
                "Water level reached ${water.toInt()}%.")
        } else if (water <= TANK_LOW_PCT && (prevW == null || prevW > TANK_LOW_PCT)) {
            fireNotification(NOTIF_ID_TANK_LOW,
                "🔴 Tank Low",
                "Water level is only ${water.toInt()}%. Consider running the pump.")
        }
        prevWater = water

        // ── Top sensor ──────────────────────────────────────────────────
        if (!topOnline && prevTopOnline != false) {
            fireNotification(NOTIF_ID_TOP_OFFLINE,
                "📡 Top Sensor Offline",
                "LoRa top sensor not responding. Manual mode may be required.")
        } else if (topOnline && prevTopOnline == false) {
            fireNotification(NOTIF_ID_TOP_OFFLINE,
                "📡 Top Sensor Online",
                "LoRa top sensor recovered.")
        }
        prevTopOnline = topOnline

        // ── Update persistent foreground notification ────────────────────
        val pumpStr  = if (pumpOn) "ON 💧" else "OFF"
        val safeStr  = if (safetyTripped) " ⚠️Safety" else ""
        val topStr   = if (!topOnline) " 📡TopOff" else ""
        updateForegroundText("Tank ${water.toInt()}% • Pump $pumpStr$safeStr$topStr")
    }

    // ── Foreground notification helpers ────────────────────────────────────

    private fun postForeground(statusText: String) {
        val notif = buildForegroundNotification(statusText)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID_FOREGROUND, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID_FOREGROUND, notif)
        }
    }

    private fun updateForegroundText(statusText: String) {
        notifManager.notify(NOTIF_ID_FOREGROUND, buildForegroundNotification(statusText))
    }

    private fun buildForegroundNotification(statusText: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_MONITOR)
                .setContentTitle("HomeTank Monitoring")
                .setContentText(statusText)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(openIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("HomeTank Monitoring")
                .setContentText(statusText)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(openIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }
    }

    // ── Alert notification helper ──────────────────────────────────────────

    private fun fireNotification(id: Int, title: String, body: String) {
        if (!notificationsEnabled) return

        val openIntent = PendingIntent.getActivity(
            this, id,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ALERTS)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentIntent(openIntent)
                .setAutoCancel(true)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentIntent(openIntent)
                .setAutoCancel(true)
                .build()
        }

        notifManager.notify(id, notif)
        Log.i(TAG, "🔔 [$id] $title")
    }

    // ── Notification channels ──────────────────────────────────────────────

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val monitorChan = NotificationChannel(
            CHANNEL_MONITOR,
            "HomeTank Monitoring",
            NotificationManager.IMPORTANCE_LOW         // silent, no sound
        ).apply {
            description = "Persistent status bar indicator showing live tank state."
            setShowBadge(false)
        }

        val alertChan = NotificationChannel(
            CHANNEL_ALERTS,
            "HomeTank Alerts",
            NotificationManager.IMPORTANCE_HIGH        // heads-up + sound
        ).apply {
            description = "Pump events, tank full/low, safety trips, device offline."
        }

        notifManager.createNotificationChannels(listOf(monitorChan, alertChan))
    }

    // ── Config helpers ─────────────────────────────────────────────────────

    private fun loadConfigFromPrefs() {
        val prefs: SharedPreferences =
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        deviceIp = prefs.getString(KEY_DEVICE_IP, "") ?: ""
        val intervalSec = prefs.getInt(KEY_POLL_INTERVAL, 30)
        pollIntervalMs  = intervalSec.toLong().coerceAtLeast(10) * 1_000L
        notificationsEnabled = prefs.getBoolean(KEY_NOTIF_ENABLED, true)
        Log.d(TAG, "Loaded config: ip=$deviceIp interval=${pollIntervalMs/1000}s notif=$notificationsEnabled")
    }

    private fun applyIntentConfig(intent: Intent) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        var changed = false

        val ip = intent.getStringExtra(EXTRA_DEVICE_IP)
        if (!ip.isNullOrBlank()) {
            deviceIp = ip
            editor.putString(KEY_DEVICE_IP, ip)
            changed = true
        }

        val interval = intent.getIntExtra(EXTRA_POLL_INTERVAL, -1)
        if (interval > 0) {
            pollIntervalMs = interval.toLong().coerceAtLeast(10) * 1_000L
            editor.putInt(KEY_POLL_INTERVAL, interval)
            changed = true
        }

        if (intent.hasExtra(EXTRA_NOTIF_ENABLED)) {
            val notif = intent.getBooleanExtra(EXTRA_NOTIF_ENABLED, true)
            notificationsEnabled = notif
            editor.putBoolean(KEY_NOTIF_ENABLED, notif)
            changed = true
        }

        if (changed) editor.apply()
    }

    // ── Wake lock ──────────────────────────────────────────────────────────

    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "HomeTank:MonitorWakeLock"
            ).also { it.acquire(12 * 60 * 60 * 1000L) }  // max 12 h auto-release
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock acquire failed: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock release failed: ${e.message}")
        }
        wakeLock = null
    }

    // ── HTTP (runs on executor background thread — never on main thread) ───

    /**
     * Performs a simple HTTP GET and returns the raw response body string.
     * Throws on any non-200 response or network error.
     */
    private fun httpGetRaw(urlStr: String): String {
        val url  = URL(urlStr)
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod  = "GET"
        conn.connectTimeout = 6_000
        conn.readTimeout    = 6_000
        conn.useCaches      = false
        conn.setRequestProperty("Accept", "application/json")

        return try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code from $urlStr")
            }
            conn.inputStream
                .bufferedReader(StandardCharsets.UTF_8)
                .use(BufferedReader::readText)
        } finally {
            conn.disconnect()
        }
    }
}
