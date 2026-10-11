import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_prefs.dart';
import 'device_config.dart';
import 'device_connection.dart';

/// First-launch onboarding shown once.
/// Sets [AppPrefs.onboardingDone] = true when finished.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  final _featureScrollController = ScrollController();
  int _page = 0;

  // Home WiFi setup state
  String _mode = 'direct'; // 'direct' or 'home_wifi'
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _passVisible = false;
  bool _privacyAccepted = false;

  // Flow status
  bool _connectingAp = false;
  bool _apConnected = false;
  bool _scanningSsids = false;
  List<String> _scannedSsids = [];
  bool _uploading = false;
  String? _statusMsg;
  bool _statusError = false;
  bool _uploadDone = false;
  String? _foundIp;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _startAutoScroll();
  }

  void _startAutoScroll() async {
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted || !_featureScrollController.hasClients) return;
    try {
      await _featureScrollController.animateTo(
        _featureScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 3500),
        curve: Curves.easeInOut,
      );
      await Future.delayed(const Duration(milliseconds: 1200));
      if (!mounted || !_featureScrollController.hasClients) return;
      await _featureScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 2500),
        curve: Curves.easeInOut,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _featureScrollController.dispose();
    _controller.dispose();
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    HapticFeedback.lightImpact();
    _controller.animateToPage(page,
        duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
  }

  void _selectMode(String mode) {
    HapticFeedback.mediumImpact();
    setState(() => _mode = mode);
    _goTo(4);
    if (mode == 'home_wifi') {
      _detectCurrentHomeSsid();
    }
  }

  Future<void> _detectCurrentHomeSsid() async {
    final current = await DeviceConnection.currentSsid();
    if (current != null && current.isNotEmpty && current != deviceApSsid) {
      if (!mounted) return;
      setState(() {
        _ssidCtrl.text = current;
        _statusMsg = '✓ Auto-detected your Wi-Fi network: "$current"';
        _statusError = false;
      });
    } else {
      // If not detected immediately, scan nearby networks from device
      _connectAndScan();
    }
  }

  Future<void> _quickConnectExisting() async {
    HapticFeedback.mediumImpact();
    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Already Configured Device?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          'How is your phone connecting to your existing HomeTank?',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'home_wifi'),
            child: const Text('Home Wi-Fi Network', style: TextStyle(color: Color(0xFF14B8A6), fontWeight: FontWeight.w600)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'direct'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF14B8A6)),
            child: const Text('Direct Hotspot'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    if (mode == 'home_wifi') {
      await AppPrefs.setConnectionMode('home_wifi');
      await AppPrefs.setOnboardingDone(true);
      if (!mounted) return;
      _finish();
      return;
    }

    if (Platform.isAndroid) {
      final perms = await DeviceConnection.ensurePermissions();
      if (!perms) return;
      bool connected = await DeviceConnection.connect();
      if (!connected && mounted) {
        final customPass = await _promptCustomApPassword();
        if (customPass != null && customPass.isNotEmpty) {
          connected = await DeviceConnection.connect(password: customPass);
        }
      }
    }
    await AppPrefs.setConnectionMode('direct');
    await AppPrefs.setOnboardingDone(true);
    if (!mounted) return;
    _finish();
  }

  Future<String?> _promptCustomApPassword() async {
    final ctrl = TextEditingController(text: AppPrefs.apPassword);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Hotspot Password Required', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Could not connect to "$deviceApSsid" with default password. Enter your hotspot password:',
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

  Future<void> _connectAndScan() async {
    setState(() {
      _connectingAp = true;
      _statusMsg = 'Connecting to $deviceApSsid hotspot...';
      _statusError = false;
    });

    if (Platform.isAndroid) {
      final permsOk = await DeviceConnection.ensurePermissions();
      if (!permsOk) {
        if (!mounted) return;
        setState(() {
          _connectingAp = false;
          _statusMsg = 'Location permission required to connect to device Wi-Fi.';
          _statusError = true;
        });
        return;
      }
      bool connected = await DeviceConnection.connect();
      if (!connected && mounted) {
        final customPass = await _promptCustomApPassword();
        if (customPass != null && customPass.isNotEmpty) {
          connected = await DeviceConnection.connect(password: customPass);
        }
      }
    }

    // Try scanning SSIDs from the device
    if (!mounted) return;
    setState(() {
      _connectingAp = false;
      _apConnected = true;
      _scanningSsids = true;
      _statusMsg = 'Scanning nearby Wi-Fi networks...';
    });

    final ssids = await DeviceConnection.scanDeviceNetworks();
    if (!mounted) return;
    setState(() {
      _scanningSsids = false;
      _scannedSsids = ssids;
      _statusMsg = null;
    });
  }

  Future<void> _uploadHomeWifi() async {
    final ssid = _ssidCtrl.text.trim();
    final pass = _passCtrl.text;

    if (ssid.isEmpty || pass.isEmpty) {
      setState(() {
        _statusMsg = 'Please enter both Wi-Fi Name (SSID) and Password.';
        _statusError = true;
      });
      return;
    }

    setState(() {
      _uploading = true;
      _statusMsg = '1/3 Connecting to HomeTank hotspot...\n⚠️ Please stay on this screen and do not switch apps.';
      _statusError = false;
    });

    if (Platform.isAndroid) {
      final connected = await DeviceConnection.connect();
      if (!connected) {
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _statusMsg = 'Could not connect to $deviceApSsid hotspot.';
          _statusError = true;
        });
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _statusMsg = '2/3 Uploading Wi-Fi credentials to HomeTank...\n⚠️ Please stay on this screen and do not switch apps.';
    });

    final ok = await DeviceConnection.uploadWifiConfig(
      homeSsid: ssid,
      homePass: pass,
    );

    if (!ok) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _statusMsg = 'Could not communicate with HomeTank at $deviceApSsid.';
        _statusError = true;
      });
      return;
    }

    await AppPrefs.setHomeWifiSsid(ssid);
    await AppPrefs.setHomeWifiPass(pass);

    // Release hotspot route so phone returns to user's home Wi-Fi network
    await DeviceConnection.releaseWifiRoute();

    if (!mounted) return;
    setState(() {
      _statusMsg = '3/3 Credentials sent! Reconnecting phone to "$ssid"...\n⚠️ Please stay on this screen and do not switch apps while searching...';
    });

    // Wait for ESP32 to reboot and connect to home router (~6s)
    await Future<void>.delayed(const Duration(seconds: 6));

    // Automatically search the home network for the HomeTank device IP
    final ip = await DeviceConnection.autoDiscoverDeviceIp(
      onProgress: (msg) {
        if (mounted) {
          setState(() => _statusMsg = msg);
        }
      },
    );

    if (!mounted) return;
    if (ip != null) {
      setState(() {
        _uploading = false;
        _uploadDone = true;
        _foundIp = ip;
        _statusMsg = '✓ Success! HomeTank connected to "$ssid" at IP: $ip';
        _statusError = false;
      });
    } else {
      setState(() {
        _uploading = false;
        _uploadDone = true;
        _statusMsg = '✓ Credentials saved to HomeTank!\nMake sure your phone is connected to "$ssid".';
        _statusError = false;
      });
    }
  }

  Future<void> _finish() async {
    await AppPrefs.setConnectionMode(_mode);
    await AppPrefs.setOnboardingDone(true);
    await AppPrefs.setPrivacyConsent(true);
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/dashboard');
  }

  // ── Build ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isWhiteBg = _page == 0;
    return Scaffold(
      backgroundColor: isWhiteBg ? const Color(0xFFF8FAFC) : const Color(0xFF080B10),
      body: Stack(
        children: [
          PageView(
            controller: _controller,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (p) {
              setState(() => _page = p);
              if (p == 0) _startAutoScroll();
            },
            children: [
              _buildProductOverview(),
              _buildPrivacyConsent(),
              _buildWelcome(),
              _buildModeSelect(),
              _mode == 'home_wifi' ? _buildHomeWifiSetup() : _buildDirectReady(),
              _buildDone(),
            ],
          ),
          // Page dots
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _PageDots(count: 6, current: _page),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openProductsWebView() async {
    HapticFeedback.mediumImpact();
    final url = Uri.parse('https://hometank.vercel.app/');
    try {
      await launchUrl(
        url,
        mode: LaunchMode.inAppWebView,
        webViewConfiguration: const WebViewConfiguration(
          enableJavaScript: true,
          enableDomStorage: true,
        ),
      );
    } catch (e) {
      debugPrint('inAppWebView launch failed: $e, trying inAppBrowserView');
      try {
        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
      } catch (_) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    }
  }

  // ── Page 0: Product Overview (Hero Banner) ───────────────────
  // ── Page 0: Product Overview (Hero Banner) ───────────────────
  Widget _buildProductOverview() {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    // Calculate adaptive item width so exactly 4 columns show on any Android screen width (capped cleanly for tablets)
    final double itemWidth = math.max(76.0, math.min(108.0, (math.min(screenWidth, 680.0) - 58.0) / 4.0));
    final double totalRowWidth = (5 * itemWidth) + 4.0;

    return Container(
      color: const Color(0xFFF8FAFC),
      child: SafeArea(
        child: Column(
          children: [
            // 1. Adaptive Top Section: Dynamically takes all remaining height above the cards without overlapping
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset(
                      'assets/onboarding.png',
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                      errorBuilder: (context, error, stackTrace) => Image.asset(
                        'assets/onbaording.png',
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                        errorBuilder: (context, error, stackTrace) => const Center(
                          child: Icon(Icons.water_drop, size: 80, color: Color(0xFF14B8A6)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 2. Adaptive Bottom Cards: Constrained to max 680px width so they look stunning on phones, foldables, and tablets
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 44, top: 4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 2-Row Auto-Scrolling Feature Card
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0F172A).withValues(alpha: 0.08),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                        border: Border.all(
                          color: const Color(0xFFE2E8F0),
                          width: 1.5,
                        ),
                      ),
                      child: SingleChildScrollView(
                        controller: _featureScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                _buildFeatureIconItem(Icons.water_rounded, 'Real-time\nWater Level', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.settings_remote_rounded, 'Pump Control\n(Relay)', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.timer_rounded, 'Smart\nTimer', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.sensors_rounded, '4 Concrete\nWalls Range', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.solar_power_rounded, 'Solar Powered\nTop Unit', itemWidth),
                              ],
                            ),
                            Container(
                              width: totalRowWidth,
                              height: 1,
                              margin: const EdgeInsets.symmetric(vertical: 10),
                              color: const Color(0xFFE2E8F0),
                            ),
                            Row(
                              children: [
                                _buildFeatureIconItem(Icons.bar_chart_rounded, 'History &\nInsights', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.notifications_active_rounded, 'Smart\nAlerts', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.battery_alert_rounded, 'Low Power\nAlerts', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.groups_rounded, 'Multi-Tank\nSupport', itemWidth),
                                _buildFeatureDivider(),
                                _buildFeatureIconItem(Icons.auto_mode_rounded, 'Automatic\nPump Mode', itemWidth),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Buttons Card (Protected against font scaling overflows)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0F172A).withValues(alpha: 0.18),
                            blurRadius: 32,
                            offset: const Offset(0, 12),
                          ),
                          BoxShadow(
                            color: const Color(0xFF14B8A6).withValues(alpha: 0.12),
                            blurRadius: 20,
                            offset: const Offset(0, -4),
                          ),
                        ],
                        border: Border.all(
                          color: const Color(0xFFCBD5E1),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _openProductsWebView,
                              icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                              label: const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'View Products',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
                                foregroundColor: const Color(0xFF0F172A),
                                backgroundColor: const Color(0xFFF8FAFC),
                                side: const BorderSide(color: Color(0xFF94A3B8), width: 1.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                elevation: 0,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _goTo(1),
                              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                              label: const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Get Started',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
                                backgroundColor: const Color(0xFF14B8A6),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                elevation: 6,
                                shadowColor: const Color(0xFF14B8A6).withValues(alpha: 0.45),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureIconItem(IconData icon, String label, double width) {
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFF0066FF), size: 24),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1E293B),
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureDivider() {
    return Container(
      width: 1,
      height: 36,
      color: const Color(0xFFE2E8F0),
    );
  }


  // ── Page 1: Privacy Consent ──────────────────────────────────
  Widget _buildPrivacyConsent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.privacy_tip_rounded, size: 80, color: Color(0xFF14B8A6)),
          const SizedBox(height: 36),
          const Text('Privacy & Data Safety',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white, height: 1.2)),
          const SizedBox(height: 16),
          Text(
            'Your privacy is our priority. HomeTank operates 100% locally. We do NOT track you, collect personal data, or sell your information. Location permission is only requested to scan for the HomeTank Wi-Fi device over your local network.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.7), height: 1.5),
          ),
          const SizedBox(height: 24),
          InkWell(
            onTap: () {
              HapticFeedback.lightImpact();
              setState(() => _privacyAccepted = !_privacyAccepted);
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Row(
                children: [
                  Icon(
                    _privacyAccepted ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    color: _privacyAccepted ? const Color(0xFF14B8A6) : Colors.white54,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'I have read and agree to the Privacy Policy and Data Safety terms.',
                      style: TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              // Open privacy policy on web or a dialog
              launchUrl(Uri.parse('https://privacypolicies-beta.vercel.app/app/hometank'));
            },
            child: const Text('Read Full Privacy Policy', style: TextStyle(color: Color(0xFF38BDF8))),
          ),
          const SizedBox(height: 40),
          SizedBox(
            height: 56,
            child: ElevatedButton(
              onPressed: _privacyAccepted ? () => _goTo(2) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF14B8A6),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF1F2937),
                disabledForegroundColor: Colors.white38,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              child: const Text(
                'Accept & Continue',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Page 2: Welcome ───────────────────────────────────────────
  Widget _buildWelcome() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 114,
            height: 114,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF14B8A6).withValues(alpha: 0.35),
                  blurRadius: 32,
                  spreadRadius: 4,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset(
                'assets/icon.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF0EA5E9), Color(0xFF14B8A6)],
                    ),
                  ),
                  child: const Icon(Icons.water_drop_rounded, size: 60, color: Colors.white),
                ),
              ),
            ),
          ),
          const SizedBox(height: 36),
          const Text('HomeTank',
            style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: Colors.white)),
          const SizedBox(height: 12),
          Text('Smart Tank Monitoring System',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17, color: Colors.white.withValues(alpha: 0.65),
              fontWeight: FontWeight.w500)),
          const SizedBox(height: 10),
          Text('Monitor your water level, control your pump,\nand get alerts — all from your phone.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13, color: Colors.white.withValues(alpha: 0.4), height: 1.6)),
          const SizedBox(height: 64),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: () => _goTo(3),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
              label: const Text(
                'Start Setup',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF14B8A6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                elevation: 8,
                shadowColor: const Color(0xFF14B8A6).withValues(alpha: 0.45),
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextButton.icon(
            onPressed: _quickConnectExisting,
            icon: const Icon(Icons.phone_android_rounded, size: 18, color: Color(0xFF38BDF8)),
            label: const Text(
              'Device already set up? Connect another phone',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF38BDF8),
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Page 3: Mode selection ────────────────────────────────────
  Widget _buildModeSelect() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How do you want\nto connect?',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white, height: 1.2)),
          const SizedBox(height: 8),
          Text('You can change this later in Settings.',
            style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.45))),
          const SizedBox(height: 32),
          _ModeCard(
            icon: Icons.wifi_rounded,
            iconColor: const Color(0xFF14B8A6),
            title: 'Direct Mode',
            subtitle: 'Connect directly to\nHomeTank device hotspot',
            pros: const ['Works offline — no router needed', 'Instant, no setup required'],
            cons: const ['Phone stays on device WiFi\nwhile monitoring'],
            selected: _mode == 'direct',
            onTap: () => _selectMode('direct'),
          ),
          const SizedBox(height: 16),
          _ModeCard(
            icon: Icons.home_rounded,
            iconColor: const Color(0xFF8B5CF6),
            title: 'Home WiFi Mode',
            subtitle: 'Device joins your home\nrouter — app works on any network',
            pros: const ['Phone stays on home WiFi', 'Monitor from same-network devices'],
            cons: const ['One-time router setup required'],
            selected: _mode == 'home_wifi',
            onTap: () => _selectMode('home_wifi'),
          ),
        ],
      ),
    );
  }

  // ── Page 4a: Direct ready ─────────────────────────────────────
  Widget _buildDirectReady() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88, height: 88,
            decoration: BoxDecoration(
              color: const Color(0xFF14B8A6).withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF14B8A6).withValues(alpha: 0.35), width: 2),
            ),
            child: const Icon(Icons.wifi_rounded, size: 44, color: Color(0xFF14B8A6)),
          ),
          const SizedBox(height: 28),
          const Text('Direct Mode Selected',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          Text(
            'When you\'re near your tank:\n\n'
            '1. Turn on the HomeTank device\n'
            '2. Open this app\n'
            '3. Tap "Connect to HomeTank" and approve the WiFi prompt\n\n'
            'The app handles the connection — you just tap connect.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14, color: Colors.white.withValues(alpha: 0.65), height: 1.7)),
          const SizedBox(height: 48),
          _buildFinishButton('Got it — Let\'s Go!'),
        ],
      ),
    );
  }

  // ── Page 3b: Home WiFi setup ──────────────────────────────────
  Widget _buildHomeWifiSetup() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 64, 24, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Home WiFi Setup',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Select your home Wi-Fi network. The app will configure the HomeTank device automatically.',
            style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5), height: 1.5)),
          const SizedBox(height: 24),

          // Scanned networks picker
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _FieldLabel('Select Wi-Fi Network (SSID)'),
              if (_scanningSsids || _connectingAp)
                const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF14B8A6)))
              else
                TextButton.icon(
                  onPressed: _connectAndScan,
                  icon: const Icon(Icons.refresh, size: 14, color: Color(0xFF14B8A6)),
                  label: const Text('Scan', style: TextStyle(color: Color(0xFF14B8A6), fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (_scannedSsids.isNotEmpty) ...[
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _scannedSsids.length,
                separatorBuilder: (_, __) => Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
                itemBuilder: (context, idx) {
                  final s = _scannedSsids[idx];
                  final selected = _ssidCtrl.text == s;
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.wifi, size: 18, color: selected ? const Color(0xFF14B8A6) : Colors.white54),
                    title: Text(s, style: TextStyle(
                      color: selected ? const Color(0xFF14B8A6) : Colors.white,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    )),
                    trailing: selected ? const Icon(Icons.check_circle, color: Color(0xFF14B8A6), size: 18) : null,
                    onTap: () => setState(() => _ssidCtrl.text = s),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
          _OnboardTextField(
            controller: _ssidCtrl,
            hint: 'Or enter Wi-Fi Name (SSID)',
            icon: Icons.wifi,
          ),
          const SizedBox(height: 16),

          _FieldLabel('Home Wi-Fi Password'),
          const SizedBox(height: 6),
          _OnboardTextField(
            controller: _passCtrl,
            hint: 'Your Wi-Fi password',
            icon: Icons.lock_outline,
            obscure: !_passVisible,
            suffix: IconButton(
              icon: Icon(_passVisible ? Icons.visibility_off : Icons.visibility,
                color: Colors.white38, size: 20),
              onPressed: () => setState(() => _passVisible = !_passVisible),
            ),
          ),
          const SizedBox(height: 24),

          if (_statusMsg != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_statusError ? const Color(0xFFEF4444) : const Color(0xFF10B981)).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: (_statusError ? const Color(0xFFEF4444) : const Color(0xFF10B981)).withValues(alpha: 0.3)),
              ),
              child: Text(_statusMsg!,
                style: TextStyle(color: _statusError ? const Color(0xFFEF4444) : const Color(0xFF10B981), fontSize: 13)),
            ),

          SizedBox(
            width: double.infinity, height: 50,
            child: ElevatedButton.icon(
              onPressed: _uploading ? null : (_uploadDone ? null : _uploadHomeWifi),
              icon: _uploading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_uploadDone ? Icons.check_rounded : Icons.wifi_protected_setup_rounded, size: 20),
              label: Text(
                _uploading ? 'Connecting & Uploading...' : (_uploadDone ? 'Configured!' : 'Connect & Auto-Setup'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _uploadDone ? const Color(0xFF10B981) : const Color(0xFF8B5CF6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_uploadDone) _buildFinishButton('Continue to Dashboard →'),
        ],
      ),
    );
  }

  // ── Page 4: Done ──────────────────────────────────────────────
  Widget _buildDone() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.35), width: 2),
            ),
            child: const Icon(Icons.check_rounded, size: 52, color: Color(0xFF10B981)),
          ),
          const SizedBox(height: 32),
          const Text('All Set!',
            style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: Colors.white)),
          const SizedBox(height: 14),
          Text(
            _mode == 'home_wifi'
                ? 'HomeTank is configured for your Home Wi-Fi${_foundIp != null ? " ($_foundIp)" : ""}.\nYou can monitor your tank effortlessly.'
                : 'HomeTank is set up in Direct mode.\nTap Connect on the dashboard whenever you\'re near the device.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15, color: Colors.white.withValues(alpha: 0.6), height: 1.6)),
          const SizedBox(height: 52),
          SizedBox(
            width: double.infinity, height: 54,
            child: ElevatedButton(
              onPressed: _finish,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: const Text('Open Dashboard',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinishButton(String label) {
    return SizedBox(
      width: double.infinity, height: 54,
      child: ElevatedButton(
        onPressed: () => _goTo(4),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF14B8A6),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        child: Text(label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

// ── Reusable sub-widgets ──────────────────────────────────────────

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.pros,
    required this.cons,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final List<String> pros;
  final List<String> cons;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: selected
              ? iconColor.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? iconColor.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.1),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800,
                    color: selected ? iconColor : Colors.white)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(
                    fontSize: 12, color: Colors.white.withValues(alpha: 0.5), height: 1.4)),
                ],
              )),
              if (selected)
                Icon(Icons.check_circle_rounded, color: iconColor, size: 22),
            ]),
            const SizedBox(height: 14),
            for (final p in pros)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.check, size: 14, color: Color(0xFF10B981)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(p,
                    style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6)))),
                ]),
              ),
            for (final c in cons)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.white.withValues(alpha: 0.3)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(c,
                    style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.4)))),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.current});
  final int count, current;

  @override
  Widget build(BuildContext context) {
    final isWhiteBg = current == 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) => AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: i == current ? 22 : 8,
        height: 8,
        decoration: BoxDecoration(
          color: i == current
              ? const Color(0xFF14B8A6)
              : (isWhiteBg ? const Color(0xFFCBD5E1) : Colors.white.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(4),
        ),
      )),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(
      fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8)));
  }
}

class _OnboardTextField extends StatelessWidget {
  const _OnboardTextField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.suffix,
    this.keyboard,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontWeight: FontWeight.w400),
        prefixIcon: Icon(icon, color: const Color(0xFF14B8A6), size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF14B8A6), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}
