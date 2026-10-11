import 'dart:io';

import 'package:flutter/services.dart';

import 'app_prefs.dart';

/// Dart-side bridge to the Android [TankMonitorService] foreground service.
///
/// All background polling and notification firing is done natively in Kotlin;
/// this class only manages start / stop / configuration and streams live
/// status strings back to the Flutter UI while it is open.
class BackgroundService {
  BackgroundService._();

  static const _methodChannel =
      MethodChannel('com.tanksync/bg_service');

  static const _eventChannel =
      EventChannel('com.tanksync/bg_events');

  static Stream<Map<String, dynamic>>? _eventStream;

  // ── Start / Stop ─────────────────────────────────────────────

  /// Start (or update config of) the foreground monitor service.
  /// Safe to call multiple times — the service is idempotent.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    if (!AppPrefs.isHomeWifiMode) return; // only works on home WiFi
    try {
      await _methodChannel.invokeMethod<void>('startService', {
        'deviceIp': AppPrefs.homeIp,
        'pollIntervalSeconds': AppPrefs.bgPollIntervalSeconds,
        'notificationsEnabled': AppPrefs.notificationsEnabled,
      });
    } on PlatformException catch (e) {
      // Non-fatal — app works without background service.
      debugLog('BackgroundService.start() failed: ${e.message}');
    }
  }

  /// Stop the foreground monitor service.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _methodChannel.invokeMethod<void>('stopService');
    } on PlatformException catch (e) {
      debugLog('BackgroundService.stop() failed: ${e.message}');
    }
  }

  /// Returns true if the service is currently running.
  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _methodChannel.invokeMethod<bool>('isRunning') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Update the service configuration (IP, poll interval) without restarting.
  static Future<void> updateConfig() async {
    if (!Platform.isAndroid) return;
    try {
      await _methodChannel.invokeMethod<void>('updateConfig', {
        'deviceIp': AppPrefs.homeIp,
        'pollIntervalSeconds': AppPrefs.bgPollIntervalSeconds,
        'notificationsEnabled': AppPrefs.notificationsEnabled,
      });
    } on PlatformException catch (e) {
      debugLog('BackgroundService.updateConfig() failed: ${e.message}');
    }
  }

  // ── Live Event Stream ─────────────────────────────────────────

  /// A broadcast stream of status-update events coming from the
  /// background service while the Flutter app is in the foreground.
  /// Each event is a JSON-decoded map matching the /api/status response.
  static Stream<Map<String, dynamic>> get events {
    _eventStream ??= _eventChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => Map<String, dynamic>.from(e as Map));
    return _eventStream!;
  }

  // ── Helpers ───────────────────────────────────────────────────
  // ignore: avoid_print
  static void debugLog(String msg) => print('[BgService] $msg');
}
