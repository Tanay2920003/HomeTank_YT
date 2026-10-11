import 'package:shared_preferences/shared_preferences.dart';
import 'device_config.dart';

/// Thin wrapper around SharedPreferences.
/// Call [AppPrefs.init] from main() before runApp().
class AppPrefs {
  AppPrefs._();

  static const _kOnboarding         = 'onboarding_done';
  static const _kPrivacyConsent     = 'privacy_consent';
  static const _kMode               = 'connection_mode'; // 'direct' | 'home_wifi'
  static const _kHomeIp             = 'home_ip';
  static const _kHomeWifiSsid       = 'home_wifi_ssid';
  static const _kHomeWifiPass       = 'home_wifi_pass';
  static const _kApPassword         = 'ap_password';
  static const _kNotificationsEnabled = 'notifications_enabled';
  static const _kBgPollInterval     = 'bg_poll_interval_seconds';

  static late SharedPreferences _p;

  static Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    // Purge any accidental direct hotspot IP stored as Home Wi-Fi IP
    if ((_p.getString(_kHomeIp) ?? '').startsWith('192.168.4.')) {
      await _p.remove(_kHomeIp);
    }
  }

  // ── Onboarding ───────────────────────────────────────────────
  static bool get onboardingDone => _p.getBool(_kOnboarding) ?? false;
  static Future<void> setOnboardingDone(bool v) => _p.setBool(_kOnboarding, v);

  // ── Privacy Consent ──────────────────────────────────────────
  static bool get privacyConsent => _p.getBool(_kPrivacyConsent) ?? false;
  static Future<void> setPrivacyConsent(bool v) => _p.setBool(_kPrivacyConsent, v);

  // ── Connection mode ──────────────────────────────────────────
  static String get connectionMode => _p.getString(_kMode) ?? 'direct';
  static Future<void> setConnectionMode(String v) => _p.setString(_kMode, v);
  static bool get isDirectMode   => connectionMode == 'direct';
  static bool get isHomeWifiMode => connectionMode == 'home_wifi';

  // ── Home WiFi / LAN IP ───────────────────────────────────────
  static String get homeIp {
    final ip = _p.getString(_kHomeIp) ?? '';
    if (ip.startsWith('192.168.4.')) return '';
    return ip;
  }
  static Future<void> setHomeIp(String v) async {
    final trimmed = v.trim();
    if (trimmed.startsWith('192.168.4.')) return; // Direct AP IP cannot be saved as Home Wi-Fi LAN IP
    await _p.setString(_kHomeIp, trimmed);
  }

  static String get homeWifiSsid => _p.getString(_kHomeWifiSsid) ?? '';
  static Future<void> setHomeWifiSsid(String v) => _p.setString(_kHomeWifiSsid, v);

  static String get homeWifiPass => _p.getString(_kHomeWifiPass) ?? '';
  static Future<void> setHomeWifiPass(String v) => _p.setString(_kHomeWifiPass, v);

  // ── AP password (kept in sync with device) ───────────────────
  static String get apPassword => _p.getString(_kApPassword) ?? deviceApPassword;
  static Future<void> setApPassword(String v) => _p.setString(_kApPassword, v);

  // ── Background notifications ─────────────────────────────────
  static bool get notificationsEnabled => _p.getBool(_kNotificationsEnabled) ?? true;
  static Future<void> setNotificationsEnabled(bool v) => _p.setBool(_kNotificationsEnabled, v);

  /// Background poll interval in seconds (15 / 30 / 60). Default 30.
  static int get bgPollIntervalSeconds => _p.getInt(_kBgPollInterval) ?? 30;
  static Future<void> setBgPollIntervalSeconds(int v) => _p.setInt(_kBgPollInterval, v);

  // ── Computed base URL ────────────────────────────────────────
  static String get baseUrl {
    if (isHomeWifiMode) {
      final ip = homeIp;
      if (ip.isNotEmpty) return 'http://$ip';
      return '';
    }
    return espBaseUrl;
  }

  // ── Complete App Reset (for Factory Reset) ───────────────────
  static Future<void> clearAll() async {
    await _p.clear();
    await setApPassword(deviceApPassword); // Restore default 'hometank@123'
    await setOnboardingDone(false);
    await setConnectionMode('direct');
    await setNotificationsEnabled(true);
    await setBgPollIntervalSeconds(30);
  }
}
