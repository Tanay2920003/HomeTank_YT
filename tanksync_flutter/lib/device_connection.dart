import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_prefs.dart';
import 'background_service.dart';
import 'device_config.dart';

class DeviceConnection {
  static const _channel = MethodChannel('com.tanksync/device_wifi');

  // ── Permissions ──────────────────────────────────────────────
  static Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final location = await Permission.locationWhenInUse.request();
    if (!location.isGranted) return false;
    await Permission.nearbyWifiDevices.request();
    return true;
  }

  // ── SSID helpers ─────────────────────────────────────────────
  static Future<String?> currentSsid() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getCurrentSsid');
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> isOnDeviceAp() async {
    final ssid = await currentSsid();
    return ssid == deviceApSsid;
  }

  // ── WiFi route binding ───────────────────────────────────────
  static Future<void> forceLocalWifiRoute() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('forceWifiRoute');
    } on PlatformException {
      // HTTP layer will surface connectivity problems.
    }
  }

  static Future<void> releaseWifiRoute() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('releaseWifiRoute');
    } on PlatformException {
      // Ignore
    }
  }

  /// Called by the keep-alive timer every 5 s in direct mode.
  static Future<void> keepAlive() async {
    if (!Platform.isAndroid || AppPrefs.isHomeWifiMode) return;
    try {
      await _channel.invokeMethod<bool>('keepAlive');
    } on PlatformException {
      // Silently ignore.
    }
  }

  // ── Connect to HomeTank AP ───────────────────────────────────
  static Future<bool> connect({String? password}) async {
    if (!Platform.isAndroid) return false;
    if (!await ensurePermissions()) return false;

    if (await isOnDeviceAp()) {
      await forceLocalWifiRoute();
      return true;
    }

    try {
      final pass = password ?? AppPrefs.apPassword;
      final connected = await _channel.invokeMethod<bool>('connect', {
        'ssid': deviceApSsid,
        'password': pass,
      });
      if (connected == true) {
        if (password != null && password.isNotEmpty) {
          await AppPrefs.setApPassword(password);
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        await forceLocalWifiRoute();
      }
      return connected == true;
    } on PlatformException {
      return false;
    }
  }

  static bool _isDiscovering = false;
  static DateTime? _lastDiscoveryTime;

  // ── HTTP helpers (mode-aware) ─────────────────────────────────
  static Future<Map<String, dynamic>> getJson(String path) async {
    // Home WiFi mode: keep Wi-Fi IP and Direct IP separate! Never fall back to espBaseUrl (192.168.4.1).
    if (AppPrefs.isHomeWifiMode) {
      final savedIp = AppPrefs.homeIp;
      if (savedIp.isNotEmpty) {
        try {
          return await _dartGet('http://$savedIp', path);
        } catch (_) {
          debugPrint('Saved LAN IP $savedIp not responding. Checking if auto-discovery needed...');
        }
      }
      // Auto-discover if saved IP is empty or unreachable, debounced to avoid timer flood
      final now = DateTime.now();
      final canDiscover = !_isDiscovering &&
          (_lastDiscoveryTime == null || now.difference(_lastDiscoveryTime!) > const Duration(seconds: 25));
      if (canDiscover) {
        final discoveredIp = await autoDiscoverDeviceIp();
        if (discoveredIp != null && discoveredIp.isNotEmpty) {
          return await _dartGet('http://$discoveredIp', path);
        }
      }
      throw const SocketException('HomeTank not found on Wi-Fi router. Check network connection.');
    }

    // Direct mode — Android uses MethodChannel (bound to AP network).
    if (Platform.isAndroid) {
      try {
        await forceLocalWifiRoute();
        final body = await _channel.invokeMethod<String>('httpGet', {'path': path});
        if (body == null || body.isEmpty) {
          throw const HttpException('Empty response from ground unit');
        }
        return jsonDecode(body) as Map<String, dynamic>;
      } on PlatformException catch (e) {
        throw SocketException(e.message ?? 'Device unreachable');
      }
    }

    // Non-Android direct mode.
    return _dartGet(espBaseUrl, path);
  }

  static Future<void> postJson(String path, Map<String, dynamic> payload) async {
    if (AppPrefs.isHomeWifiMode) {
      final savedIp = AppPrefs.homeIp;
      if (savedIp.isNotEmpty) {
        try {
          await _dartPost('http://$savedIp', path, payload);
          return;
        } catch (_) {
          debugPrint('Saved LAN IP $savedIp not responding on POST. Checking auto-discovery...');
        }
      }
      final now = DateTime.now();
      final canDiscover = !_isDiscovering &&
          (_lastDiscoveryTime == null || now.difference(_lastDiscoveryTime!) > const Duration(seconds: 25));
      if (canDiscover) {
        final discoveredIp = await autoDiscoverDeviceIp();
        if (discoveredIp != null && discoveredIp.isNotEmpty) {
          await _dartPost('http://$discoveredIp', path, payload);
          return;
        }
      }
      throw const SocketException('HomeTank not found on Wi-Fi router.');
    }

    if (Platform.isAndroid) {
      try {
        await forceLocalWifiRoute();
        final code = await _channel.invokeMethod<int>('httpPost', {
          'path': path,
          'body': jsonEncode(payload),
        });
        if (code == null || code < 200 || code >= 300) {
          throw HttpException('HTTP ${code ?? 0}');
        }
        return;
      } on PlatformException catch (e) {
        throw SocketException(e.message ?? 'Device unreachable');
      }
    }

    await _dartPost(espBaseUrl, path, payload);
  }

  // ── WiFi config upload ───────────────────────────────────────

  /// Upload WiFi credentials to the device.
  /// [homeSsid] / [homePass] = home router credentials (stored on device).
  /// [apPassword] = new AP hotspot password (optional).
  /// Device reboots after receiving this — returns true if POST succeeded.
  static Future<bool> uploadWifiConfig({
    String? homeSsid,
    String? homePass,
    String? apPassword,
    bool clearHome = false,
  }) async {
    final payload = <String, dynamic>{};
    if (homeSsid != null)  payload['home_ssid']     = homeSsid;
    if (homePass != null)  payload['home_password']  = homePass;
    if (apPassword != null) payload['ap_password']   = apPassword;
    if (clearHome) payload['clear_home'] = true;

    try {
      // During onboarding the phone is on HomeTank AP even in a future
      // home-WiFi setup — temporarily force direct-mode HTTP for this call.
      if (Platform.isAndroid) {
        await forceLocalWifiRoute();
        final code = await _channel.invokeMethod<int>('httpPost', {
          'path': '/api/wifi',
          'body': jsonEncode(payload),
        });
        return code != null && code >= 200 && code < 300;
      } else {
        await _dartPost(espBaseUrl, '/api/wifi', payload);
        return true;
      }
    } catch (_) {
      return false;
    }
  }

  /// GET /api/wifi status from the device.
  static Future<Map<String, dynamic>> getWifiStatus() async {
    return getJson('/api/wifi');
  }

  /// Scan nearby WiFi SSIDs visible to the HomeTank device.
  static Future<List<String>> scanDeviceNetworks() async {
    try {
      final data = await getJson('/api/wifi/scan');
      final list = (data['networks'] as List?) ?? [];
      final ssids = <String>[];
      for (final item in list) {
        if (item is Map) {
          final ssid = item['ssid']?.toString();
          if (ssid != null && ssid.isNotEmpty && !ssids.contains(ssid)) {
            ssids.add(ssid);
          }
        }
      }
      return ssids;
    } catch (_) {
      return [];
    }
  }

  /// Automatically search the home WiFi network to find the HomeTank device IP.
  static Future<String?> autoDiscoverDeviceIp({
    void Function(String message)? onProgress,
  }) async {
    if (_isDiscovering) return null;
    _isDiscovering = true;
    try {
      // 1. Try mDNS hometank.local quick check
      onProgress?.call('Checking hostname hometank.local...');
      try {
        final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 1200);
        final req = await client.getUrl(Uri.parse('http://hometank.local/api/status'));
        final res = await req.close().timeout(const Duration(milliseconds: 1200));
        if (res.statusCode == 200) {
          final text = await res.transform(utf8.decoder).join();
          final json = jsonDecode(text) as Map<String, dynamic>;
          if (json.containsKey('model') || json.containsKey('device_id') || json.containsKey('unit_id')) {
            // Get exact socket remote IP in case firmware JSON still reports "192.168.4.1"
            final remoteIp = res.connectionInfo?.remoteAddress.address;
            final resolvedIp = (remoteIp != null && !remoteIp.startsWith('192.168.4.') && remoteIp != '127.0.0.1')
                ? remoteIp
                : (json['ip']?.toString() ?? '');
            if (resolvedIp.isNotEmpty && !resolvedIp.startsWith('192.168.4.')) {
              await AppPrefs.setHomeIp(resolvedIp);
              if (AppPrefs.isHomeWifiMode) await BackgroundService.updateConfig();
              return resolvedIp;
            }
          }
        }
      } catch (_) {}

      // 2. Discover local network subnet prefix from phone interfaces
      onProgress?.call('Scanning local Wi-Fi subnet...');
      final subnets = <String>{};
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.isLoopback) continue;
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
              if (subnet != '192.168.4' && subnet != '127.0.0') {
                subnets.add(subnet);
              }
            }
          }
        }
      } catch (_) {}

      // Add common default home router subnets as fallbacks
      subnets.addAll(['192.168.1', '192.168.0', '192.168.29', '192.168.178', '10.0.0']);
      subnets.remove('192.168.4'); // Never scan direct hotspot range in Home Wi-Fi mode

      // 3. Scan IPs concurrently in batches
      for (final subnet in subnets) {
        onProgress?.call('Scanning $subnet.x...');
        for (int batch = 1; batch <= 254; batch += 30) {
          final futures = <Future<String?>>[];
          for (int i = batch; i < batch + 30 && i <= 254; i++) {
            final targetIp = '$subnet.$i';
            futures.add(_testDeviceIp(targetIp));
          }
          final results = await Future.wait(futures);
          for (final ip in results) {
            if (ip != null && !ip.startsWith('192.168.4.')) {
              await AppPrefs.setHomeIp(ip);
              if (AppPrefs.isHomeWifiMode) await BackgroundService.updateConfig();
              return ip;
            }
          }
        }
      }
      return null;
    } finally {
      _lastDiscoveryTime = DateTime.now();
      _isDiscovering = false;
    }
  }

  static Future<String?> _testDeviceIp(String ip) async {
    if (ip.startsWith('192.168.4.')) return null;
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 450);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip/api/status'))
          .timeout(const Duration(milliseconds: 450));
      final res = await req.close().timeout(const Duration(milliseconds: 450));
      if (res.statusCode == 200) {
        final text = await res.transform(utf8.decoder).join();
        final json = jsonDecode(text);
        if (json is Map && (json.containsKey('model') || json.containsKey('device_id') || json.containsKey('unit_id'))) {
          return ip;
        }
      }
    } catch (_) {} finally {
      client.close(force: true);
    }
    return null;
  }

  // ── Private Dart HTTP helpers ─────────────────────────────────
  static Future<Map<String, dynamic>> _dartGet(String base, String path) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse('$base$path'))
          .timeout(requestTimeout);
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final text = await response.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _dartPost(
      String base, String path, Map<String, dynamic> payload) async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    try {
      final request = await client
          .postUrl(Uri.parse('$base$path'))
          .timeout(requestTimeout);
      final jsonStr = jsonEncode(payload);
      final bytes = utf8.encode(jsonStr);
      debugPrint('DART POST $path body=$jsonStr len=${bytes.length}');
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.contentLength = bytes.length;
      request.add(bytes);
      await request.flush();
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errBody = await response.transform(utf8.decoder).join();
        debugPrint('DART POST $path failed (${response.statusCode}): $errBody');
        throw HttpException('HTTP ${response.statusCode}');
      }
    } finally {
      client.close(force: true);
    }
  }
}
