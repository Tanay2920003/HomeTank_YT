package com.tanksync.tanksync_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log

/**
 * Receives [android.intent.action.BOOT_COMPLETED] and restarts the
 * [TankMonitorService] if the user had Home WiFi mode enabled before reboot.
 *
 * Declared in AndroidManifest.xml with RECEIVE_BOOT_COMPLETED permission.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG        = "TankBootReceiver"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val KEY_MODE   = "flutter.connection_mode"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs: SharedPreferences =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val mode = prefs.getString(KEY_MODE, "direct") ?: "direct"

        if (mode == "home_wifi") {
            Log.i(TAG, "Boot completed — restarting TankMonitorService (home_wifi mode)")
            val serviceIntent = Intent(context, TankMonitorService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } else {
            Log.d(TAG, "Boot completed — skipping service restart (mode=$mode)")
        }
    }
}
