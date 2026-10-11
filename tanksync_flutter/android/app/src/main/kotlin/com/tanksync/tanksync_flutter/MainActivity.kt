package com.tanksync.tanksync_flutter

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "TankSyncWifi"
        private const val CHANNEL     = "com.tanksync/device_wifi"
        private const val BG_CHANNEL  = "com.tanksync/bg_service"
        private const val BG_EVENTS   = "com.tanksync/bg_events"
        private const val DEVICE_HOST = "192.168.4.1"
        private const val KEEP_ALIVE_INTERVAL_MS = 8_000L
        private const val RECONNECT_DELAY_MS     = 2_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var connectivityManager: ConnectivityManager? = null
    private var wifiManager: WifiManager? = null
    private var boundNetwork: Network? = null
    private var activeCallback: ConnectivityManager.NetworkCallback? = null
    private var targetSsid: String? = null

    // ── Save the password so we can auto-reconnect after onLost() ──
    private var savedPassword: String? = null

    // ── Keep-alive: re-binds every KEEP_ALIVE_INTERVAL_MS ──────────
    private val keepAliveRunnable = object : Runnable {
        override fun run() {
            val net = boundNetwork
            if (net != null) {
                connectivityManager?.bindProcessToNetwork(net)
                Log.d(TAG, "keep-alive: rebound process to $targetSsid")
            }
            mainHandler.postDelayed(this, KEEP_ALIVE_INTERVAL_MS)
        }
    }

    private fun startKeepAlive() {
        mainHandler.removeCallbacks(keepAliveRunnable)
        mainHandler.postDelayed(keepAliveRunnable, KEEP_ALIVE_INTERVAL_MS)
    }

    private fun stopKeepAlive() {
        mainHandler.removeCallbacks(keepAliveRunnable)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCurrentSsid" -> result.success(getCurrentSsid())

                    "forceWifiRoute" -> {
                        val ok = forceWifiRoute()
                        result.success(ok)
                    }

                    "releaseWifiRoute" -> {
                        stopKeepAlive()
                        releaseNetworkCallback()
                        bindNetwork(null)
                        boundNetwork = null
                        targetSsid = null
                        Log.d(TAG, "Released device wifi route")
                        result.success(true)
                    }

                    // Flutter calls this every ~5 s to refresh the binding.
                    "keepAlive" -> {
                        val net = boundNetwork
                        if (net != null) {
                            connectivityManager?.bindProcessToNetwork(net)
                            Log.d(TAG, "keepAlive (Flutter-triggered)")
                        }
                        result.success(net != null)
                    }

                    "connect" -> {
                        val ssid     = call.argument<String>("ssid")
                        val password = call.argument<String>("password")
                        if (ssid.isNullOrBlank() || password.isNullOrBlank()) {
                            result.error("bad_args", "ssid and password required", null)
                            return@setMethodCallHandler
                        }
                        targetSsid    = ssid
                        savedPassword = password
                        Thread {
                            val ok = connectToAp(ssid, password)
                            mainHandler.post { result.success(ok) }
                        }.start()
                    }

                    "httpGet" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val body = httpGet(path)
                                mainHandler.post { result.success(body) }
                            } catch (e: Exception) {
                                Log.w(TAG, "httpGet $path failed", e)
                                mainHandler.post {
                                    result.error("http_error", e.message, null)
                                }
                            }
                        }.start()
                    }

                    "httpPost" -> {
                        val path = call.argument<String>("path")
                        val body = call.argument<String>("body") ?: ""
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val code = httpPost(path, body)
                                mainHandler.post { result.success(code) }
                            } catch (e: Exception) {
                                Log.w(TAG, "httpPost $path failed", e)
                                mainHandler.post {
                                    result.error("http_error", e.message, null)
                                }
                            }
                        }.start()
                    }

                    else -> result.notImplemented()
                }
            }

        // ── Background service channel ─────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BG_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val ip       = call.argument<String>("deviceIp") ?: ""
                        val interval = call.argument<Int>("pollIntervalSeconds") ?: 30
                        val notifOn  = call.argument<Boolean>("notificationsEnabled") ?: true
                        val intent   = Intent(this, TankMonitorService::class.java).apply {
                            putExtra(TankMonitorService.EXTRA_DEVICE_IP,     ip)
                            putExtra(TankMonitorService.EXTRA_POLL_INTERVAL, interval)
                            putExtra(TankMonitorService.EXTRA_NOTIF_ENABLED, notifOn)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }

                    "stopService" -> {
                        stopService(Intent(this, TankMonitorService::class.java))
                        result.success(null)
                    }

                    "isRunning" -> result.success(TankMonitorService.isRunning)

                    "updateConfig" -> {
                        val ip       = call.argument<String>("deviceIp") ?: ""
                        val interval = call.argument<Int>("pollIntervalSeconds") ?: 30
                        val notifOn  = call.argument<Boolean>("notificationsEnabled") ?: true
                        val intent   = Intent(this, TankMonitorService::class.java).apply {
                            action = TankMonitorService.ACTION_UPDATE_CONFIG
                            putExtra(TankMonitorService.EXTRA_DEVICE_IP,     ip)
                            putExtra(TankMonitorService.EXTRA_POLL_INTERVAL, interval)
                            putExtra(TankMonitorService.EXTRA_NOTIF_ENABLED, notifOn)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // ── EventChannel: stream live status to Flutter while app is open ────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, BG_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                @Volatile private var eventSink: EventChannel.EventSink? = null
                private var streamThread: Thread? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    streamThread = Thread({
                        var lastSent: String? = null
                        while (!Thread.currentThread().isInterrupted) {
                            try {
                                val json = TankMonitorService.lastStatusJson
                                // Only push when data actually changed
                                if (json != null && json != lastSent) {
                                    lastSent = json
                                    // Parse JSON into a Map so Flutter receives a Dart map
                                    val map = parseJsonToMap(json)
                                    mainHandler.post { eventSink?.success(map) }
                                }
                                Thread.sleep(2_000)
                            } catch (_: InterruptedException) { break }
                              catch (e: Exception) {
                                Log.w("BgEvents", "Stream error: ${e.message}")
                            }
                        }
                    }, "BgEvents-streamer").also { it.isDaemon = true }
                    streamThread?.start()
                    Log.d("BgEvents", "Listener attached")
                }

                override fun onCancel(arguments: Any?) {
                    streamThread?.interrupt()
                    streamThread = null
                    eventSink = null
                    Log.d("BgEvents", "Listener detached")
                }
            })
    }

    /** Parse a JSON string into a nested Map<String, Any?> suitable for an EventChannel. */
    private fun parseJsonToMap(jsonStr: String): Map<String, Any?> {
        return try {
            val obj = org.json.JSONObject(jsonStr)
            jsonObjectToMap(obj)
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun jsonObjectToMap(obj: org.json.JSONObject): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            map[key] = when (val v = obj.get(key)) {
                is org.json.JSONObject -> jsonObjectToMap(v)
                is org.json.JSONArray  -> jsonArrayToList(v)
                org.json.JSONObject.NULL -> null
                else -> v
            }
        }
        return map
    }

    private fun jsonArrayToList(arr: org.json.JSONArray): List<Any?> {
        val list = mutableListOf<Any?>()
        for (i in 0 until arr.length()) {
            list.add(when (val v = arr.get(i)) {
                is org.json.JSONObject -> jsonObjectToMap(v)
                is org.json.JSONArray  -> jsonArrayToList(v)
                org.json.JSONObject.NULL -> null
                else -> v
            })
        }
        return list
    }

    // ── SSID helpers ──────────────────────────────────────────────
    @Suppress("DEPRECATION")
    private fun getCurrentSsid(): String? {
        val info = wifiManager?.connectionInfo ?: return null
        val ssid = info.ssid ?: return null
        if (ssid == "<unknown ssid>" || ssid == "0x") return null
        return ssid.replace("\"", "").trim()
    }

    private fun findWifiNetwork(): Network? {
        val cm = connectivityManager ?: return null
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return network
        }
        return null
    }

    private fun resolveDeviceNetwork(): Network? {
        boundNetwork?.let { return it }
        val expected = targetSsid ?: return null
        if (getCurrentSsid() != expected) return null
        return findWifiNetwork()
    }

    // ── Network binding ───────────────────────────────────────────
    @Suppress("DEPRECATION")
    private fun bindNetwork(network: Network?) {
        val cm = connectivityManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            cm.bindProcessToNetwork(network)
        } else {
            ConnectivityManager.setProcessDefaultNetwork(network)
        }
    }

    private fun forceWifiRoute(): Boolean {
        val network = resolveDeviceNetwork() ?: return false
        bindNetwork(network)
        return true
    }

    private fun releaseNetworkCallback() {
        val cm = connectivityManager ?: return
        activeCallback?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: IllegalArgumentException) { }
        }
        activeCallback = null
    }

    // ── Core connect logic ────────────────────────────────────────
    private fun connectToAp(ssid: String, password: String): Boolean {
        targetSsid    = ssid
        savedPassword = password

        if (getCurrentSsid() == ssid) {
            boundNetwork = findWifiNetwork()
            bindNetwork(boundNetwork)
            startKeepAlive()
            return true
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false

        releaseNetworkCallback()
        boundNetwork = null

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val cm      = connectivityManager ?: return false
        val latch   = CountDownLatch(1)
        var success = false

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.i(TAG, "onAvailable: connected to $ssid")
                boundNetwork = network
                bindNetwork(network)
                success = true
                startKeepAlive()
                latch.countDown()
            }

            override fun onUnavailable() {
                Log.w(TAG, "onUnavailable: $ssid")
                latch.countDown()
            }

            override fun onLost(network: Network) {
                Log.w(TAG, "onLost: $ssid — scheduling reconnect")
                if (boundNetwork == network) {
                    boundNetwork = null
                    bindNetwork(null)
                    stopKeepAlive()
                    // ── Auto-reconnect after a short pause ─────────────
                    val savedSsid = targetSsid
                    val savedPass = savedPassword
                    if (!savedSsid.isNullOrBlank() && !savedPass.isNullOrBlank()) {
                        mainHandler.postDelayed({
                            Thread {
                                Log.i(TAG, "Auto-reconnecting to $savedSsid…")
                                connectToAp(savedSsid, savedPass)
                            }.start()
                        }, RECONNECT_DELAY_MS)
                    }
                }
            }
        }

        activeCallback = callback
        mainHandler.post { cm.requestNetwork(request, callback, 25_000) }

        try {
            latch.await(27, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            return false
        }

        if (!success) releaseNetworkCallback()
        return success
    }

    // ── HTTP helpers ──────────────────────────────────────────────
    private fun httpGet(path: String): String {
        val network = resolveDeviceNetwork()
            ?: throw IllegalStateException("Not connected to ${targetSsid ?: "device AP"}")
        bindNetwork(network)

        val url  = URL("http://$DEVICE_HOST$path")
        val conn = network.openConnection(url) as HttpURLConnection
        conn.requestMethod  = "GET"
        conn.connectTimeout = 5000
        conn.readTimeout    = 5000
        conn.useCaches      = false

        val code   = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val body   = stream.bufferedReader(StandardCharsets.UTF_8).use(BufferedReader::readText)
        conn.disconnect()

        if (code !in 200..299) throw IllegalStateException("HTTP $code: $body")
        return body
    }

    private fun httpPost(path: String, jsonBody: String): Int {
        val network = resolveDeviceNetwork()
            ?: throw IllegalStateException("Not connected to ${targetSsid ?: "device AP"}")
        bindNetwork(network)

        val url  = URL("http://$DEVICE_HOST$path")
        val conn = network.openConnection(url) as HttpURLConnection
        conn.requestMethod  = "POST"
        conn.connectTimeout = 5000
        conn.readTimeout    = 5000
        conn.doOutput       = true
        conn.doInput        = true
        conn.useCaches      = false
        conn.setRequestProperty("Content-Type", "application/json")
        conn.setRequestProperty("Accept", "application/json")

        val bytes = jsonBody.toByteArray(StandardCharsets.UTF_8)
        conn.setFixedLengthStreamingMode(bytes.size)

        Log.d(TAG, "POST $path body=[$jsonBody] bytes=${bytes.size}")

        conn.outputStream.use {
            it.write(bytes)
            it.flush()
        }

        val code = conn.responseCode
        if (code !in 200..299) {
            val errBody = try {
                conn.errorStream?.bufferedReader(StandardCharsets.UTF_8)?.readText() ?: ""
            } catch (_: Exception) { "" }
            println("ESP32 HTTP POST $path failed ($code): $errBody")
            Log.w(TAG, "httpPost $path failed ($code): $errBody")
        }
        conn.disconnect()
        return code
    }

    override fun onDestroy() {
        stopKeepAlive()
        releaseNetworkCallback()
        bindNetwork(null)
        super.onDestroy()
    }
}
