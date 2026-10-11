import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_prefs.dart';
import 'background_service.dart';
import 'device_config.dart';
import 'device_connection.dart';
import 'manual_page.dart';
import 'onboarding_page.dart';
import 'permissions_page.dart';
import 'settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPrefs.init();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Start background monitor immediately if home WiFi mode is already configured.
  if (AppPrefs.isHomeWifiMode && AppPrefs.homeIp.isNotEmpty) {
    await BackgroundService.start();
  }
  runApp(const TankSyncApp());
}

class TankSyncApp extends StatelessWidget {
  const TankSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HomeTank',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        return child ?? const SizedBox();
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF14B8A6),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF080B10),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      initialRoute: (AppPrefs.onboardingDone && AppPrefs.privacyConsent) ? '/dashboard' : '/onboarding',
      routes: {
        '/onboarding': (_) => const OnboardingPage(),
        '/dashboard':  (_) => const DashboardPage(),
      },
    );
  }
}

// ── Safety snapshot from /api/status ──────────────────────────
class TankSafety {
  const TankSafety({
    this.tripped        = false,
    this.alert          = '',
    this.dailyCycles    = 0,
    this.maxCycles      = 5,
    this.resetInSec     = 0,
    this.pumpRunSec     = 0,
    this.maxRunSec      = 1800,
  });

  final bool   tripped;
  final String alert;
  final int    dailyCycles;
  final int    maxCycles;
  final int    resetInSec;
  final int    pumpRunSec;
  final int    maxRunSec;

  factory TankSafety.fromJson(Map<String, dynamic> json) {
    final s = (json['safety'] is Map<String, dynamic>)
        ? json['safety'] as Map<String, dynamic>
        : <String, dynamic>{};
    return TankSafety(
      tripped:     s['tripped'] == true,
      alert:       s['alert']?.toString() ?? '',
      dailyCycles: _toInt(s['daily_cycles']) ?? 0,
      maxCycles:   _toInt(s['max_cycles'])   ?? 5,
      resetInSec:  _toInt(s['reset_in_sec']) ?? 0,
      pumpRunSec:  _toInt(s['pump_run_sec']) ?? 0,
      maxRunSec:   _toInt(s['max_run_sec'])  ?? 1800,
    );
  }

  static int? _toInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

// ── Tank telemetry snapshot ────────────────────────────────────
class TankStatus {
  const TankStatus({
    required this.deviceId,
    required this.firmware,
    required this.water,
    required this.pump,
    required this.topOnline,
    required this.valid,
    this.distance,
    this.temperature,
    this.humidity,
    this.battery,
    this.solar,
    this.groundBattery,
    this.rssi,
    this.snr,
    this.lastSeenSeconds,
    this.safety,
    this.calibrateMode = false,
    this.autoMode = true,
  });

  final String deviceId;
  final String firmware;
  final double water;
  final bool pump;
  final bool topOnline;
  final bool valid;
  final double? distance;
  final double? temperature;
  final double? humidity;
  final double? battery;
  final double? solar;
  final double? groundBattery;
  final double? rssi;
  final double? snr;
  final int? lastSeenSeconds;
  final TankSafety? safety;
  final bool calibrateMode;
  final bool autoMode;

  factory TankStatus.fromJson(Map<String, dynamic> json) {
    final tank = (json['tank'] is Map<String, dynamic>)
        ? json['tank'] as Map<String, dynamic>
        : <String, dynamic>{};
    final uptime = _toDouble(json['uptime_ms']);
    final lastRx = _toDouble(json['last_rx_ms']);

    return TankStatus(
      deviceId: json['device_id']?.toString() ?? 'HomeTank',
      firmware: json['firmware']?.toString() ?? '-',
      water: _toDouble(tank['pct']) ?? _toDouble(json['water']) ?? 0,
      distance: _toDouble(tank['dist']) ?? _toDouble(json['distance']),
      temperature:
          _toDouble(tank['temp']) ??
          _toDouble(json['temperature']) ??
          _toDouble(json['temp']),
      humidity: _toDouble(tank['hum']) ?? _toDouble(json['humidity']),
      battery: _toDouble(tank['bat']) ?? _toDouble(json['battery']),
      solar: _toDouble(tank['sol']) ?? _toDouble(json['solar']),
      groundBattery: _toDouble(json['ground_bat']),
      rssi: _toDouble(tank['rssi']) ?? _toDouble(json['rssi']),
      snr: _toDouble(tank['snr']),
      pump: json['relay'] == true || json['pump'] == true,
      topOnline: json['online'] == true || json['tank'] == null,
      valid: json['valid'] == true || json['tank'] != null,
      lastSeenSeconds: uptime != null && lastRx != null
          ? ((uptime - lastRx) / 1000).clamp(0, double.infinity).round()
          : null,
      safety: TankSafety.fromJson(json),
      calibrateMode: json['calibrate_mode'] == true,
      autoMode: json['auto_mode'] != false,
    );
  }
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _keepAliveTimer;
  StreamSubscription<Map<String, dynamic>>? _bgSubscription;
  TankStatus? _status;
  bool _loading = true;
  bool _online = false;
  bool _connecting = false;
  bool _sendingRelay = false;
  bool _showRawRssi = false;
  String? _error;
  String? _wifiSsid;
  DateTime? _lastUpdated;
  DateTime? _offlineSince;
  String? _workingPath;

  String _getRssiString(double? rssi) {
    if (rssi == null) return '-';
    if (rssi >= -80) return 'Excellent';
    if (rssi >= -95) return 'Good';
    if (rssi >= -110) return 'Fair';
    return 'Weak';
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    WidgetsBinding.instance.addObserver(this);
    _loading = false;
    // Immediately load status right when opening the app, so we don't wait for the timer!
    _loadStatus();
    _timer = Timer.periodic(pollInterval, (_) => _loadStatus());
    // Keep-alive: re-bind Android WiFi network every 5 s in direct mode.
    _keepAliveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => DeviceConnection.keepAlive(),
    );
    // Subscribe to live status events streamed directly from the native background service
    _bgSubscription = BackgroundService.events.listen((data) {
      if (!mounted || data.isEmpty) return;
      try {
        final parsed = TankStatus.fromJson(data);
        setState(() {
          _status = parsed;
          _online = true;
          _offlineSince = null;
          _loading = false;
          _error = null;
          _lastUpdated = DateTime.now();
        });
      } catch (e) {
        debugPrint('Failed parsing event stream JSON: $e');
      }
    });
    // Request POST_NOTIFICATIONS permission (Android 13+) and start
    // the background service if in Home WiFi mode.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _requestNotificationPermission();
      if (AppPrefs.isHomeWifiMode) {
        await BackgroundService.start();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the user switches back to the app (on demand), immediately fetch status right away!
    if (state == AppLifecycleState.resumed) {
      _loadStatus();
    }
  }


  /// Requests POST_NOTIFICATIONS permission on Android 13+ (API 33).
  /// Uses the existing permission_handler package already in pubspec.
  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      const notifPermission = Permission.notification;
      final status = await notifPermission.status;
      if (status.isDenied) {
        await notifPermission.request();
      }
    } catch (_) {
      // Non-fatal — app works without notifications.
    }
  }

  void _showPermissionsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permissions Denied'),
        content: const Text('HomeTank needs Location permissions to connect to the device Wi-Fi.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const PermissionsPage()));
            },
            child: const Text('Fix Permissions'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndConnectDirect() async {
    if (AppPrefs.isHomeWifiMode) {
      await _connectAndPoll();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.wifi_tethering, color: Color(0xFFF59E0B)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Connect to Tank Hotspot?',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          'Connecting directly to HomeTank ($deviceApSsid) will temporarily disconnect your phone from your Home Wi-Fi network.\n\nYou may temporarily lose internet access while connected to the tank.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF14B8A6),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Connect', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _connectAndPoll();
    }
  }

  Future<void> _connectAndPoll() async {
    setState(() {
      _loading = true;
      _connecting = true;
      _error = null;
    });

    // Home WiFi mode: no AP connection needed — just poll via LAN IP.
    if (AppPrefs.isHomeWifiMode) {
      if (!mounted) return;
      setState(() { _loading = false; _connecting = false; });
      await _loadStatus();
      return;
    }

    if (Platform.isAndroid) {
      final permissionsGranted = await DeviceConnection.ensurePermissions();
      if (!permissionsGranted) {
        if (mounted) {
          setState(() {
            _loading = false;
            _connecting = false;
            _error = 'Permissions denied';
          });
          _showPermissionsDialog();
        }
        return;
      }

      bool connected = await DeviceConnection.connect();
      if (!connected && mounted) {
        final customPass = await _promptCustomApPassword();
        if (customPass != null && customPass.isNotEmpty) {
          connected = await DeviceConnection.connect(password: customPass);
        }
      }
      _wifiSsid = await DeviceConnection.currentSsid();
    }

    if (!mounted) return;
    setState(() => _connecting = false);
    await _loadStatus();
  }

  Future<String?> _promptCustomApPassword() async {
    final ctrl = TextEditingController(text: AppPrefs.apPassword);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Tank Hotspot Password Required', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Could not connect to "$deviceApSsid". If you changed the hotspot password from the default, please enter it below:',
              style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Hotspot password',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                filled: true,
                fillColor: const Color(0xFF1F2937),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF14B8A6)),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Future<void> _showConnectionMethodPicker() async {
    HapticFeedback.mediumImpact();
    final mode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Choose Connection Method',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Select how your phone should connect and control your HomeTank:',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 13),
              ),
              const SizedBox(height: 20),
              InkWell(
                onTap: () => Navigator.pop(ctx, 'direct'),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppPrefs.isDirectMode ? const Color(0xFF14B8A6).withValues(alpha: 0.15) : const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppPrefs.isDirectMode ? const Color(0xFF14B8A6) : Colors.white12,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF14B8A6).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.wifi_tethering, color: Color(0xFF14B8A6), size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Direct Hotspot (HomeTank)',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                            const SizedBox(height: 4),
                            Text('Connect directly to tank Wi-Fi. Ideal when lights/router are off.',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, height: 1.3)),
                          ],
                        ),
                      ),
                      if (AppPrefs.isDirectMode)
                        const Icon(Icons.check_circle, color: Color(0xFF14B8A6), size: 22),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () => Navigator.pop(ctx, 'home_wifi'),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppPrefs.isHomeWifiMode ? const Color(0xFF14B8A6).withValues(alpha: 0.15) : const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppPrefs.isHomeWifiMode ? const Color(0xFF14B8A6) : Colors.white12,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.router, color: Color(0xFF38BDF8), size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Home Wi-Fi Router',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                            const SizedBox(height: 4),
                            Text('Connect via your home router on the same network.',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, height: 1.3)),
                          ],
                        ),
                      ),
                      if (AppPrefs.isHomeWifiMode)
                        const Icon(Icons.check_circle, color: Color(0xFF14B8A6), size: 22),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (mode == null || !mounted) return;

    if (mode == 'direct' && !AppPrefs.isDirectMode) {
      await AppPrefs.setConnectionMode('direct');
      // Stop background service — direct mode requires the hotspot, not home WiFi.
      await BackgroundService.stop();
      setState(() => _offlineSince = null);
      await _confirmAndConnectDirect();
    } else if (mode == 'home_wifi' && !AppPrefs.isHomeWifiMode) {
      await AppPrefs.setConnectionMode('home_wifi');
      setState(() => _offlineSince = null);
      await _connectAndPoll();
      // Start background service now that home WiFi mode is active.
      await BackgroundService.start();
    } else {
      setState(() => _offlineSince = null);
      await _connectAndPoll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bgSubscription?.cancel();
    _timer?.cancel();
    _keepAliveTimer?.cancel();
    // Do NOT stop the background service here — it must survive app close.
    super.dispose();
  }

  Future<void> _loadStatus() async {
    if (Platform.isAndroid) {
      _wifiSsid = await DeviceConnection.currentSsid();
    }

    final paths = _workingPath == null
        ? ['/api/status', '/data']
        : [_workingPath!];

    for (final path in paths) {
      try {
        final json = await DeviceConnection.getJson(path);
        if (!mounted) return;
        setState(() {
          _status = TankStatus.fromJson(json);
          _workingPath = path;
          _online = true;
          _offlineSince = null;
          _loading = false;
          _error = null;
          _lastUpdated = DateTime.now();
        });
        return;
      } catch (e) {
        debugPrint('GET $path failed: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _online = false;
      _offlineSince ??= DateTime.now();
      _loading = false;
      if (AppPrefs.isHomeWifiMode) {
        final ip = AppPrefs.homeIp;
        _error = ip.isEmpty
            ? 'Home WiFi mode: no device IP saved. Go to Settings → WiFi to set it.'
            : 'Device not responding at http://$ip — make sure the HomeTank device is on your home WiFi.';
      } else if (Platform.isAndroid) {
        if (_wifiSsid != deviceApSsid) {
          _error =
              'Phone is on "${_wifiSsid ?? "unknown"}", not "$deviceApSsid". '
              'Tap Connect and approve the Android Wi-Fi prompt, or join '
              '"$deviceApSsid" manually in Settings.';
        } else {
          _error =
              'On $deviceApSsid but ground unit not responding at $espBaseUrl. '
              'Check the Heltec board is powered on.';
        }
      } else {
        _error =
            'Connect to Wi-Fi "$deviceApSsid" (password: $deviceApPassword), then refresh.';
      }
    });
  }

  Future<void> _togglePump() async {
    final status = _status;
    if (status == null || _sendingRelay) return;

    final next = !status.pump;

    // If turning ON and top sensor is offline, warn and prompt for run duration
    if (next && !status.topOnline) {
      _showOfflinePumpWarningDialog();
      return;
    }

    await _executeRelayCommand(next);
  }

  Future<void> _executeRelayCommand(bool turnOn, {int? runDurationSec}) async {
    setState(() => _sendingRelay = true);
    try {
      final body = <String, dynamic>{'state': turnOn};
      if (runDurationSec != null) {
        body['max_pump_run_sec'] = runDurationSec;
        body['duration_sec'] = runDurationSec;
      }
      await DeviceConnection.postJson('/api/relay', body);
      await Future.delayed(const Duration(milliseconds: 350));
      await _loadStatus();
      if (_status?.pump != turnOn) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _loadStatus();
      }
    } catch (e) {
      debugPrint('Relay command failed: $e');
      if (mounted) {
        setState(() => _error = 'Pump command failed.');
      }
    } finally {
      if (mounted) setState(() => _sendingRelay = false);
    }
  }

  Future<void> _toggleAutoMode(bool enabled) async {
    try {
      await DeviceConnection.postJson('/api/settings', {'auto_mode': enabled});
      await _loadStatus();
    } catch (e) {
      debugPrint('Auto mode toggle failed: $e');
      if (mounted) setState(() => _error = 'Failed to change mode.');
    }
  }

  void _showOfflinePumpWarningDialog() {
    int selectedMinutes = 10;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111722),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.warning_amber_rounded,
                          color: Color(0xFFF59E0B),
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Top Sensor Offline',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Manual Safety Timer Required',
                              style: TextStyle(
                                fontSize: 13,
                                color: Color(0xFFF59E0B),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'The top unit is currently offline. To prevent overflow, select how long the pump should run before shutting off automatically:',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.75),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: '$selectedMinutes ',
                            style: const TextStyle(
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF14B8A6),
                            ),
                          ),
                          const TextSpan(
                            text: 'minutes',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF14B8A6),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                      thumbColor: Colors.white,
                      overlayColor: const Color(0xFF14B8A6).withValues(alpha: 0.2),
                      trackHeight: 6,
                    ),
                    child: Slider(
                      value: selectedMinutes.toDouble(),
                      min: 1,
                      max: 45,
                      divisions: 44,
                      label: '$selectedMinutes min',
                      onChanged: (val) {
                        HapticFeedback.selectionClick();
                        setSheetState(() => selectedMinutes = val.round());
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [5, 10, 15, 20, 30].map((mins) {
                        final active = selectedMinutes == mins;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text('$mins min'),
                            selected: active,
                            onSelected: (_) {
                              HapticFeedback.lightImpact();
                              setSheetState(() => selectedMinutes = mins);
                            },
                            selectedColor: const Color(0xFF14B8A6).withValues(alpha: 0.25),
                            backgroundColor: Colors.white.withValues(alpha: 0.05),
                            labelStyle: TextStyle(
                              color: active ? const Color(0xFF14B8A6) : Colors.white70,
                              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                            ),
                            side: BorderSide(
                              color: active
                                  ? const Color(0xFF14B8A6)
                                  : Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _executeRelayCommand(true, runDurationSec: selectedMinutes * 60);
                          },
                          icon: const Icon(Icons.timer_outlined, size: 20),
                          label: Text(
                            'Run for $selectedMinutes min',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final pct = (status?.water ?? 0).clamp(0, 100).toDouble();
    final waterColor = pct < 30
        ? const Color(0xFFEF4444)
        : pct < 50
        ? const Color(0xFFF59E0B)
        : pct >= 90
        ? const Color(0xFF10B981)
        : const Color(0xFF0EA5E9);

    // Show connect overlay only in Direct mode when not online.
    // In Home WiFi mode the status banner already shows the error.
    final showConnectOverlay =
        !_online && !_loading && !_connecting && AppPrefs.isDirectMode;

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: RefreshIndicator(
              onRefresh: _connectAndPoll,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
                children: [
                  _Header(
                    online: _online,
                    onSettings: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsPage()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _ConnectionMethodBar(
                    isHomeWifi: AppPrefs.isHomeWifiMode,
                    onChangeMethod: _showConnectionMethodPicker,
                  ),
                  const SizedBox(height: 14),
                  _StatusBanner(
                    loading: _loading || _connecting,
                    online: _online,
                    status: status,
                    error: _error,
                  ),
                  if (!_online && _offlineSince != null && DateTime.now().difference(_offlineSince!).inSeconds >= 30) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2937),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: const [
                              Icon(Icons.wifi_off_rounded, color: Color(0xFFF59E0B), size: 22),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Connection Recovery (30s+)',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Unable to connect to the tank for over 30 seconds. Switch connection modes or try joining the tank direct hotspot:',
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13, height: 1.4),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () async {
                                    HapticFeedback.mediumImpact();
                                    await AppPrefs.setConnectionMode('direct');
                                    setState(() => _offlineSince = null);
                                    await _confirmAndConnectDirect();
                                  },
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF14B8A6),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  icon: const Icon(Icons.wifi_tethering, size: 18),
                                  label: const Text('Connect Directly', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () async {
                                    HapticFeedback.mediumImpact();
                                    await AppPrefs.setConnectionMode('home_wifi');
                                    setState(() => _offlineSince = null);
                                    await _connectAndPoll();
                                  },
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  icon: const Icon(Icons.router, size: 18),
                                  label: const Text('Try Home Wi-Fi', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (status?.calibrateMode == true) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.3)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.tune, color: Color(0xFFF59E0B)),
                        const SizedBox(width: 12),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text('Calibration Mode Active', style: TextStyle(
                              color: Color(0xFFF59E0B), fontWeight: FontWeight.w700)),
                            SizedBox(height: 4),
                            Text('Pump is OFF. Go to settings to disable.', style: TextStyle(
                              color: Color(0xFFF59E0B), fontSize: 12)),
                          ],
                        )),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _TankGauge(
                    percent: pct,
                    color: waterColor,
                    distance: status?.distance,
                  ),
                  const SizedBox(height: 14),
                  // Safety status row
                  if (status?.safety != null)
                    _SafetyRow(safety: status!.safety!),
                  if (status?.safety != null)
                    const SizedBox(height: 14),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.35,
                    children: [
                      _MetricCard(
                        'Top Temperature',
                        _fmt(status?.temperature, 1, '°C'),
                        Icons.thermostat,
                      ),
                      _MetricCard(
                        'Top Humidity',
                        status?.humidity != null ? '${status!.humidity!.toStringAsFixed(0)}%' : '-',
                        Icons.water_drop_outlined,
                      ),
                      _MetricCard(
                        'Top Battery',
                        _fmt(status?.battery, 2, ' V'),
                        Icons.battery_5_bar,
                      ),
                      _MetricCard(
                        'Solar Panel',
                        _fmt(status?.solar, 2, ' V'),
                        Icons.wb_sunny_outlined,
                      ),
                      _MetricCard(
                        'Bottom Battery',
                        _fmt(status?.groundBattery, 2, ' V'),
                        Icons.battery_charging_full,
                      ),
                      _MetricCard(
                        'Wireless Signal',
                        _showRawRssi ? _fmt(status?.rssi, 0, ' dBm') : _getRssiString(status?.rssi),
                        Icons.wifi_rounded,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _showRawRssi = !_showRawRssi);
                        },
                      ),
                      _MetricCard(
                        'Product Manual',
                        'View Guide',
                        Icons.menu_book,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const ManualPage()),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // ── Bottom Unit display card ──────────────────────────
                  _BottomUnitCard(groundBattery: status?.groundBattery),
                  const SizedBox(height: 14),
                  if (status != null) ...[
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: status.autoMode
                            ? Colors.white.withValues(alpha: 0.055)
                            : const Color(0xFFF59E0B).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: status.autoMode
                              ? Colors.white.withValues(alpha: 0.08)
                              : const Color(0xFFF59E0B).withValues(alpha: 0.25),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            status.autoMode ? Icons.auto_mode : Icons.pan_tool_alt_outlined,
                            color: status.autoMode ? const Color(0xFF14B8A6) : const Color(0xFFF59E0B),
                            size: 24,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  status.autoMode ? 'Automatic Fill Mode' : 'Manual Mode Only',
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  status.autoMode
                                      ? 'Pump follows water level thresholds automatically'
                                      : 'Automatic filling disabled • Pump responds to manual control',
                                  style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.65)),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: status.autoMode,
                            onChanged: _online ? (v) { HapticFeedback.lightImpact(); _toggleAutoMode(v); } : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  _PumpCard(
                    pumpOn: status?.pump ?? false,
                    enabled: status != null && _online && !_sendingRelay,
                    sending: _sendingRelay,
                    safety: status?.safety,
                    onChanged: () { HapticFeedback.lightImpact(); _togglePump(); },
                  ),
                  const SizedBox(height: 18),
                  Center(
  child: DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(30),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF4F8CFF).withValues(alpha: 0.35),
          blurRadius: 30,
          spreadRadius: 2,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: const LinearGradient(
              colors: [
                Color(0xFF6AA8FF),
                Color(0xFF4F8CFF),
                Color(0xFF3D6FFF),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(
              color: Colors.white24,
              width: 1.2,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(30),
            splashColor: Colors.white24,
            highlightColor: Colors.white10,
            onTap: () async {
              HapticFeedback.mediumImpact();

              final url = Uri.parse(
                'https://hometank.vercel.app/',
              );

              await launchUrl(
                url,
                mode: LaunchMode.externalApplication,
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 14,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.shopping_bag_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),

                  const SizedBox(width: 14),

                  const Text(
                    'View Product',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),

                  const SizedBox(width: 10),

                  const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
),
                  const SizedBox(height: 18),
                  Center(
                    child: Text(
                      'Device: ${status?.deviceId ?? '-'}  |  Firmware: ${status?.firmware ?? '-'}'
                      '${_lastUpdated == null ? '' : '  |  ${_time(_lastUpdated!)}'}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Full-screen connect overlay ───────────────────────────
          if (showConnectOverlay)
            _ConnectOverlay(
              connecting: _connecting,
              onConnect: () {
                HapticFeedback.heavyImpact();
                _confirmAndConnectDirect();
              },
            ),

          // ── Thin connecting progress indicator ───────────────────
          if (_connecting)
            const Positioned(
              top: 0, left: 0, right: 0,
              child: LinearProgressIndicator(minHeight: 3),
            ),
        ],
      ),
    );
  }
}

String _fmt(double? value, int digits, String suffix) {
  return value == null ? '-' : '${value.toStringAsFixed(digits)}$suffix';
}

String _time(DateTime time) {
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  final s = time.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String _formatHoursMins(int seconds) {
  if (seconds <= 0) return 'soon';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

class _Header extends StatelessWidget {
  const _Header({required this.online, required this.onSettings});

  final bool online;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xFF102025),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Image.asset('assets/icon.png', width: 24, height: 24),
        ),
        const SizedBox(width: 12),
        const Text(
          'HomeTank',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 10),
        // Live / Offline badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: online
                ? const Color(0xFF10B981).withValues(alpha: 0.12)
                : const Color(0xFFF59E0B).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: online
                  ? const Color(0xFF10B981).withValues(alpha: 0.3)
                  : const Color(0xFFF59E0B).withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle,
                size: 7,
                color: online
                    ? const Color(0xFF10B981)
                    : const Color(0xFFF59E0B),
              ),
              const SizedBox(width: 6),
              Text(
                online ? 'Live' : 'Offline',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: online
                      ? const Color(0xFF10B981)
                      : const Color(0xFFF59E0B),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        // Settings gear button
        IconButton(
          onPressed: () { HapticFeedback.lightImpact(); onSettings(); },
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }
}

// Safety status row shown below the tank gauge
class _SafetyRow extends StatelessWidget {
  const _SafetyRow({required this.safety});
  final TankSafety safety;

  @override
  Widget build(BuildContext context) {
    final tripped = safety.tripped;
    final runPct  = safety.maxRunSec > 0
        ? (safety.pumpRunSec / safety.maxRunSec).clamp(0.0, 1.0)
        : 0.0;
    final runMin  = safety.pumpRunSec ~/ 60;
    final runSec  = safety.pumpRunSec % 60;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tripped
            ? const Color(0xFFEF4444).withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: tripped
              ? const Color(0xFFEF4444).withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 4,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  tripped ? Icons.warning_amber_rounded : Icons.shield_outlined,
                  size: 18,
                  color: tripped ? const Color(0xFFEF4444) : const Color(0xFF14B8A6),
                ),
                const SizedBox(width: 8),
                Text(
                  tripped
                      ? 'Safety tripped: ${safety.alert}'
                      : 'Safety OK',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tripped ? const Color(0xFFEF4444) : Colors.white,
                  ),
                ),
              ],
            ),
            Text(
              'Cycles: ${safety.dailyCycles}/${safety.maxCycles} (resets in ${_formatHoursMins(safety.resetInSec)})',
              style: TextStyle(
                fontSize: 12,
                color: safety.dailyCycles >= safety.maxCycles
                    ? const Color(0xFFF59E0B)
                    : Colors.white.withValues(alpha: 0.55),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (safety.pumpRunSec > 0) ...[
          const SizedBox(height: 10),
          Row(children: [
            Text('Pump running: ${runMin}m ${runSec}s',
              style: TextStyle(
                fontSize: 12, color: Colors.white.withValues(alpha: 0.65))),
            const Spacer(),
            Text('Max: ${safety.maxRunSec ~/ 60}m',
              style: TextStyle(
                fontSize: 12, color: Colors.white.withValues(alpha: 0.40))),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: runPct,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.10),
              valueColor: AlwaysStoppedAnimation<Color>(
                runPct > 0.75
                    ? const Color(0xFFEF4444)
                    : runPct > 0.5
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF14B8A6),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

class _ConnectionMethodBar extends StatelessWidget {
  const _ConnectionMethodBar({
    required this.isHomeWifi,
    required this.onChangeMethod,
  });

  final bool isHomeWifi;
  final VoidCallback onChangeMethod;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onChangeMethod();
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2937).withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF14B8A6).withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Icon(
                isHomeWifi ? Icons.router_rounded : Icons.wifi_tethering_rounded,
                color: const Color(0xFF14B8A6),
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isHomeWifi ? 'Mode: Home Wi-Fi Router' : 'Mode: Tank Direct Hotspot',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF14B8A6).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      'Switch',
                      style: TextStyle(
                        color: Color(0xFF14B8A6),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(width: 4),
                    Icon(Icons.swap_horiz, color: Color(0xFF14B8A6), size: 14),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.loading,
    required this.online,
    required this.status,
    required this.error,
  });

  final bool loading;
  final bool online;
  final TankStatus? status;
  final String? error;

  String _friendlyMessage() {
    if (loading) return 'Connecting to HomeTank...';
    if (!online) {
      if (error == null || error!.isEmpty) {
        return 'Device unreachable • Check power & Wi-Fi';
      }
      final errLower = error!.toLowerCase();
      if (errLower.contains('timeout') ||
          errLower.contains('future not completed') ||
          errLower.contains('failed') ||
          errLower.contains('not responding') ||
          errLower.contains('socketexception') ||
          errLower.contains('httpexception')) {
        return 'Could not reach HomeTank • Check Wi-Fi connection';
      }
      return error!;
    }
    if (status?.topOnline == true) {
      final ago = status?.lastSeenSeconds;
      return ago == null
          ? 'All sensors active & online'
          : 'All sensors online • Updated ${ago}s ago';
    }
    return 'Top tank sensor offline • Showing last recorded level';
  }

  @override
  Widget build(BuildContext context) {
    final message = _friendlyMessage();
    final isErrorState = !online && !loading;
    final isTopOffline = online && status?.topOnline != true;
    final iconColor = loading
        ? const Color(0xFF38BDF8)
        : isErrorState || isTopOffline
            ? const Color(0xFFF59E0B)
            : const Color(0xFF10B981);
    final icon = loading
        ? Icons.sync_rounded
        : isErrorState
            ? Icons.info_outline_rounded
            : isTopOffline
                ? Icons.warning_amber_rounded
                : Icons.check_circle_rounded;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isErrorState
            ? const Color(0xFFF59E0B).withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isErrorState
              ? const Color(0xFFF59E0B).withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                message,
                key: ValueKey<String>(message),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaterWavePainter extends CustomPainter {
  _WaterWavePainter({required this.phase, required this.color});
  final double phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final waveHeight = size.height * 0.36;
    final baseY = size.height - waveHeight;

    // Back wave
    final backPath = Path();
    backPath.moveTo(0, size.height);
    for (double x = 0; x <= size.width; x += 2) {
      final y = baseY +
          9 * math.sin((x / size.width * 2 * math.pi) + phase + 1.2) +
          3 * math.cos((x / size.width * 4 * math.pi) + phase);
      backPath.lineTo(x, y);
    }
    backPath.lineTo(size.width, size.height);
    backPath.close();

    final backPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.35),
          const Color(0xFF1D4ED8).withValues(alpha: 0.4),
        ],
      ).createShader(Rect.fromLTWH(0, baseY - 20, size.width, waveHeight + 20));
    canvas.drawPath(backPath, backPaint);

    // Front wave
    final frontPath = Path();
    frontPath.moveTo(0, size.height);
    for (double x = 0; x <= size.width; x += 2) {
      final y = baseY +
          11 * math.sin((x / size.width * 2 * math.pi) + phase) +
          3 * math.sin((x / size.width * 3 * math.pi) + phase * 1.5);
      frontPath.lineTo(x, y);
    }
    frontPath.lineTo(size.width, size.height);
    frontPath.close();

    final frontPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.88),
          const Color(0xFF032B69),
        ],
      ).createShader(Rect.fromLTWH(0, baseY - 20, size.width, waveHeight + 20));
    canvas.drawPath(frontPath, frontPaint);

    // Glowing crest line
    final crestPath = Path();
    for (double x = 0; x <= size.width; x += 2) {
      final y = baseY +
          11 * math.sin((x / size.width * 2 * math.pi) + phase) +
          3 * math.sin((x / size.width * 3 * math.pi) + phase * 1.5);
      if (x == 0) {
        crestPath.moveTo(x, y);
      } else {
        crestPath.lineTo(x, y);
      }
    }
    canvas.drawPath(
        crestPath,
        Paint()
          ..color = const Color(0xFF38BDF8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 4.0));
    canvas.drawPath(
        crestPath,
        Paint()
          ..color = const Color(0xFF38BDF8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0);
  }

  @override
  bool shouldRepaint(covariant _WaterWavePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.color != color;
}

class _TankGauge extends StatefulWidget {
  const _TankGauge({
    required this.percent,
    required this.color,
    required this.distance,
  });

  final double percent;
  final Color color;
  final double? distance;

  @override
  State<_TankGauge> createState() => _TankGaugeState();
}

class _TankGaugeState extends State<_TankGauge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pctClamped = widget.percent.clamp(0.0, 100.0) / 100.0;

    return Container(
      height: 280,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0A1628), Color(0xFF0D1E36)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: const Color(0xFF38BDF8).withValues(alpha: 0.22),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: widget.color.withValues(alpha: 0.18),
            blurRadius: 32,
            spreadRadius: 1,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Animated flowing water wave at bottom
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (ctx, _) {
                return CustomPaint(
                  painter: _WaterWavePainter(
                    phase: _controller.value * 2 * math.pi,
                    color: widget.color,
                  ),
                );
              },
            ),
          ),

          // Top center WATER LEVEL header
          const Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: 18),
              child: Text(
                'WATER LEVEL',
                style: TextStyle(
                  color: Color(0xFF38BDF8),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.5,
                ),
              ),
            ),
          ),

          // Center percentage and distance
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    '${widget.percent.round()}%',
                    key: ValueKey<int>(widget.percent.round()),
                    style: const TextStyle(
                      fontSize: 68,
                      fontWeight: FontWeight.w900,
                      height: 1,
                      shadows: [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 16,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.distance == null
                      ? 'Water level'
                      : '${widget.distance!.toStringAsFixed(1)} cm to water',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    shadows: const [
                      Shadow(
                        color: Colors.black54,
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Right side vertical level meter
          Positioned(
            right: 20,
            top: 48,
            bottom: 48,
            child: Row(
              children: [
                // Vertical liquid track
                Container(
                  width: 14,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: pctClamped,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0xFF38BDF8),
                            widget.color,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Tick percentages
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('100%', style: TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w600)),
                    Text('75%', style: TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w600)),
                    Text('50%', style: TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w600)),
                    Text('25%', style: TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w600)),
                    Text('0%', style: TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Bottom Unit display card ───────────────────────────────────
class _BottomUnitCard extends StatelessWidget {
  const _BottomUnitCard({required this.groundBattery});
  final double? groundBattery;

  Color _battColor(double? v) {
    if (v == null) return Colors.white54;
    if (v >= 3.8) return const Color(0xFF10B981);
    if (v >= 3.5) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  IconData _battIcon(double? v) {
    if (v == null) return Icons.battery_unknown;
    if (v >= 4.0) return Icons.battery_full;
    if (v >= 3.8) return Icons.battery_5_bar;
    if (v >= 3.6) return Icons.battery_3_bar;
    if (v >= 3.5) return Icons.battery_2_bar;
    return Icons.battery_alert;
  }

  @override
  Widget build(BuildContext context) {
    final color = _battColor(groundBattery);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF14B8A6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF14B8A6).withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'BOTTOM UNIT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF14B8A6),
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const Spacer(),
              Icon(Icons.router, size: 18, color: Colors.white.withValues(alpha: 0.4)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(_battIcon(groundBattery), color: color, size: 32),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Battery',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    groundBattery != null
                        ? '${groundBattery!.toStringAsFixed(2)} V'
                        : 'No data',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (groundBattery != null)
                _BatteryBar(voltage: groundBattery!),
            ],
          ),
        ],
      ),
    );
  }
}

class _BatteryBar extends StatelessWidget {
  const _BatteryBar({required this.voltage});
  final double voltage;

  @override
  Widget build(BuildContext context) {
    // LiPo: 3.0 V empty → 4.2 V full
    final pct = ((voltage - 3.0) / (4.2 - 3.0)).clamp(0.0, 1.0);
    final color = pct > 0.5
        ? const Color(0xFF10B981)
        : pct > 0.25
            ? const Color(0xFFF59E0B)
            : const Color(0xFFEF4444);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${(pct * 100).round()}%',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            width: 70,
            height: 8,
            child: LinearProgressIndicator(
              value: pct,
              backgroundColor: Colors.white.withValues(alpha: 0.10),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Full-screen connect overlay ────────────────────────────────
class _ConnectOverlay extends StatelessWidget {
  const _ConnectOverlay({
    required this.connecting,
    required this.onConnect,
  });

  final bool connecting;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF080B10).withValues(alpha: 0.88),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: const Color(0xFF14B8A6).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF14B8A6).withValues(alpha: 0.35),
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 44,
                  color: Color(0xFF14B8A6),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Not Connected',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Connect your phone to the HomeTank\nground unit Wi-Fi ($deviceApSsid)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white.withValues(alpha: 0.6),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: connecting ? null : onConnect,
                  icon: connecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.wifi_rounded, size: 22),
                  label: Text(
                    connecting ? 'Connecting...' : 'Connect to HomeTank',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14B8A6),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Glowing3DIcon extends StatelessWidget {
  const _Glowing3DIcon(this.icon, this.accentColor);
  final IconData icon;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accentColor.withValues(alpha: 0.32),
            accentColor.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.45),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.22),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        color: accentColor,
        size: 23,
        shadows: [
          Shadow(
            color: accentColor,
            blurRadius: 8,
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(this.label, this.value, this.icon, {this.onTap});

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;

  Color _getAccentColor() {
    if (icon == Icons.thermostat) return const Color(0xFF38BDF8);
    if (icon == Icons.water_drop_outlined) return const Color(0xFF06B6D4);
    if (icon == Icons.battery_5_bar || icon == Icons.battery_charging_full) {
      return const Color(0xFF4ADE80);
    }
    if (icon == Icons.wb_sunny_outlined) return const Color(0xFFFACC15);
    if (icon == Icons.wifi_rounded || icon == Icons.settings_input_antenna) {
      return const Color(0xFF60A5FA);
    }
    if (icon == Icons.menu_book) return const Color(0xFF22D3EE);
    return const Color(0xFF14B8A6);
  }

  @override
  Widget build(BuildContext context) {
    final accent = _getAccentColor();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.055),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            _Glowing3DIcon(icon, accent),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      value,
                      key: ValueKey<String>(value),
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PumpCard extends StatelessWidget {
  const _PumpCard({
    required this.pumpOn,
    required this.enabled,
    required this.sending,
    required this.onChanged,
    this.safety,
  });

  final bool pumpOn;
  final bool enabled;
  final bool sending;
  final VoidCallback onChanged;
  final TankSafety? safety;

  String _fmtDuration(int totalSec) {
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    if (m > 0) {
      return '${m}m ${s.toString().padLeft(2, '0')}s';
    }
    return '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    int remSec = 0;
    if (pumpOn && safety != null && safety!.maxRunSec > 0) {
      remSec = (safety!.maxRunSec - safety!.pumpRunSec).clamp(0, safety!.maxRunSec);
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: pumpOn
            ? const Color(0xFF10B981).withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: pumpOn
              ? const Color(0xFF10B981).withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: [
          Icon(
            pumpOn ? Icons.power : Icons.power_settings_new,
            color: pumpOn ? const Color(0xFF10B981) : Colors.white54,
            size: 26,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    const Text(
                      'Pump Relay',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    if (pumpOn && safety != null && safety!.maxRunSec > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(0xFF10B981).withValues(alpha: 0.35),
                          ),
                        ),
                        child: Text(
                          '⏱ ${_fmtDuration(remSec)} left',
                          style: const TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    sending
                        ? 'Sending command...'
                        : pumpOn
                        ? (safety != null && safety!.maxRunSec > 0
                            ? 'Running • ${_fmtDuration(safety!.pumpRunSec)} / ${_fmtDuration(safety!.maxRunSec)}'
                            : 'Running')
                        : 'Stopped',
                    key: ValueKey<bool>(pumpOn),
                    style: TextStyle(
                      color: pumpOn ? Colors.white : Colors.white.withValues(alpha: 0.65),
                      fontWeight: pumpOn ? FontWeight.w600 : FontWeight.w400,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Switch(value: pumpOn, onChanged: enabled ? (_) { HapticFeedback.lightImpact(); onChanged(); } : null),
        ],
      ),
    );
  }
}
