import 'dart:io';

import 'package:flutter/material.dart';

import 'app_prefs.dart';
import 'device_config.dart';
import 'device_connection.dart';

class WifiSettingsSection extends StatefulWidget {
  const WifiSettingsSection({
    super.key,
    this.onModeChanged,
  });

  final VoidCallback? onModeChanged;

  @override
  State<WifiSettingsSection> createState() => _WifiSettingsSectionState();
}

class _WifiSettingsSectionState extends State<WifiSettingsSection> {
  late String _mode; // 'direct' or 'home_wifi'

  // AP password (for hotspot mode)
  final _apPassCtrl = TextEditingController();
  bool _apPassVisible = false;

  // Home WiFi credentials
  final _ssidCtrl = TextEditingController();
  final _homePassCtrl = TextEditingController();
  bool _homePassVisible = false;

  // Manual IP override (if needed)
  final _ipCtrl = TextEditingController();

  bool _loading = false;
  bool _scanning = false;
  List<String> _scannedSsids = [];
  String? _statusMessage;
  bool _statusError = false;

  @override
  void initState() {
    super.initState();
    _mode = AppPrefs.connectionMode;
    _apPassCtrl.text = AppPrefs.apPassword;
    _ssidCtrl.text = AppPrefs.homeWifiSsid;
    _homePassCtrl.text = AppPrefs.homeWifiPass;
    _ipCtrl.text = AppPrefs.homeIp;
  }

  @override
  void dispose() {
    _apPassCtrl.dispose();
    _ssidCtrl.dispose();
    _homePassCtrl.dispose();
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _changeMode(String newMode) async {
    if (_mode == newMode) return;

    final isDirect = newMode == 'direct';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              isDirect ? Icons.wifi_tethering : Icons.router_outlined,
              color: const Color(0xFFF59E0B),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isDirect ? 'Switch to Direct Mode?' : 'Switch to Home Wi-Fi Mode?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          isDirect
              ? 'Switching to Direct Hotspot mode will temporarily disconnect your phone from your Home Wi-Fi network to connect directly to the HomeTank hotspot.\n\nYou may temporarily lose internet access.'
              : 'Switching to Home Wi-Fi mode will disconnect from the HomeTank hotspot and reconnect to your Home Wi-Fi router.\n\nMake sure your tank is configured to join your home Wi-Fi network.',
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
            child: const Text('Switch Mode', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _mode = newMode);
    await AppPrefs.setConnectionMode(newMode);
    widget.onModeChanged?.call();
  }

  Future<void> _scanNetworks() async {
    setState(() {
      _scanning = true;
      _statusMessage = 'Detecting current Wi-Fi & scanning networks...';
      _statusError = false;
    });

    // Extract current connected SSID first
    final current = await DeviceConnection.currentSsid();
    if (current != null && current.isNotEmpty && current != deviceApSsid) {
      if (_ssidCtrl.text.isEmpty) {
        _ssidCtrl.text = current;
      }
    }

    if (Platform.isAndroid) {
      await DeviceConnection.connect();
    }

    final ssids = await DeviceConnection.scanDeviceNetworks();
    if (!mounted) return;
    if (current != null && current.isNotEmpty && current != deviceApSsid && !ssids.contains(current)) {
      ssids.insert(0, current);
    }
    setState(() {
      _scanning = false;
      _scannedSsids = ssids;
      _statusMessage = ssids.isNotEmpty
          ? 'Select your network below:'
          : (current != null ? 'Detected current network: "$current"' : 'Could not reach HomeTank scanner.');
      _statusError = ssids.isEmpty && current == null;
    });
  }

  Future<void> _autoDiscoverNetwork() async {
    setState(() {
      _loading = true;
      _statusMessage = 'Searching your Wi-Fi network for HomeTank...';
      _statusError = false;
    });

    final foundIp = await DeviceConnection.autoDiscoverDeviceIp(
      onProgress: (msg) {
        if (mounted) {
          setState(() => _statusMessage = msg);
        }
      },
    );

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (foundIp != null) {
        _ipCtrl.text = foundIp;
        _statusMessage = '✓ Found HomeTank at IP: $foundIp';
        _statusError = false;
      } else {
        _statusMessage = 'Device not found on current Wi-Fi subnet.';
        _statusError = true;
      }
    });
  }

  Future<void> _saveApPassword() async {
    final pass = _apPassCtrl.text.trim();
    if (pass.length < 8) {
      _setStatus('Hotspot password must be at least 8 characters.', true);
      return;
    }

    setState(() {
      _loading = true;
      _statusMessage = 'Updating hotspot password on device...\n⚠️ Please stay on this screen and do not switch apps.';
      _statusError = false;
    });

    if (Platform.isAndroid) {
      await DeviceConnection.connect();
    }

    final ok = await DeviceConnection.uploadWifiConfig(apPassword: pass);
    if (!mounted) return;

    if (ok) {
      await AppPrefs.setApPassword(pass);
      _setStatus('Hotspot password updated! Reconnect to $deviceApSsid.', false);
    } else {
      _setStatus('Could not reach device. Connect phone to $deviceApSsid first.', true);
    }
    setState(() => _loading = false);
  }

  Future<void> _uploadHomeWifi() async {
    final ssid = _ssidCtrl.text.trim();
    final pass = _homePassCtrl.text;

    if (ssid.isEmpty) {
      _setStatus('Wi-Fi Name (SSID) cannot be empty.', true);
      return;
    }

    setState(() {
      _loading = true;
      _statusMessage = 'Uploading Wi-Fi credentials to HomeTank...\n⚠️ Please stay on this screen and do not switch apps.';
      _statusError = false;
    });

    if (Platform.isAndroid) {
      await DeviceConnection.connect();
    }

    final ok = await DeviceConnection.uploadWifiConfig(
      homeSsid: ssid,
      homePass: pass,
    );
    if (!mounted) return;

    if (ok) {
      await AppPrefs.setHomeWifiSsid(ssid);
      await AppPrefs.setHomeWifiPass(pass);
      await DeviceConnection.releaseWifiRoute();
      _setStatus('Credentials sent! Phone returning to "$ssid"... Searching network...', false);

      // Auto-search after 6 seconds
      await Future<void>.delayed(const Duration(seconds: 6));
      await _autoDiscoverNetwork();
    } else {
      _setStatus('Could not reach HomeTank. Ensure phone is connected to $deviceApSsid.', true);
      setState(() => _loading = false);
    }
  }

  Future<void> _clearHomeWifi() async {
    setState(() {
      _loading = true;
      _statusMessage = 'Clearing Home Wi-Fi config on device...';
      _statusError = false;
    });

    if (Platform.isAndroid) {
      await DeviceConnection.connect();
    }

    final ok = await DeviceConnection.uploadWifiConfig(clearHome: true);
    if (!mounted) return;
    setState(() => _loading = false);

    if (ok) {
      _ssidCtrl.clear();
      _homePassCtrl.clear();
      await AppPrefs.setHomeWifiSsid('');
      await AppPrefs.setHomeWifiPass('');
      _setStatus('Home Wi-Fi cleared. Device running AP-only mode.', false);
    } else {
      _setStatus('Could not reach device.', true);
    }
  }

  void _setStatus(String msg, bool error) {
    setState(() {
      _statusMessage = msg;
      _statusError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('CONNECTION MODE', style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w700,
          color: Color(0xFF64748B), letterSpacing: 1.1)),
        const SizedBox(height: 10),

        // Mode Switcher Cards
        Row(
          children: [
            Expanded(child: _ModeSelectCard(
              title: 'Direct Hotspot',
              subtitle: 'Connect to $deviceApSsid',
              icon: Icons.wifi_rounded,
              selected: _mode == 'direct',
              onTap: () => _changeMode('direct'),
            )),
            const SizedBox(width: 12),
            Expanded(child: _ModeSelectCard(
              title: 'Home Wi-Fi',
              subtitle: 'Via home router',
              icon: Icons.home_rounded,
              selected: _mode == 'home_wifi',
              onTap: () => _changeMode('home_wifi'),
            )),
          ],
        ),
        const SizedBox(height: 24),

        // Status Feedback Banner
        if (_statusMessage != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (_statusError ? const Color(0xFFEF4444) : const Color(0xFF10B981))
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: (_statusError ? const Color(0xFFEF4444) : const Color(0xFF10B981))
                    .withValues(alpha: 0.3)),
            ),
            child: Text(_statusMessage!,
              style: TextStyle(
                color: _statusError ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                fontSize: 13)),
          ),
          const SizedBox(height: 16),
        ],

        if (_mode == 'direct') _buildDirectSettings() else _buildHomeWifiSettings(),
      ],
    );
  }

  Widget _buildDirectSettings() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('DEVICE HOTSPOT PASSWORD', style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8))),
          const SizedBox(height: 6),
          Text('Change the password for the "$deviceApSsid" Wi-Fi hotspot.',
            style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.4))),
          const SizedBox(height: 14),
          _TextField(
            controller: _apPassCtrl,
            hint: 'Min. 8 characters',
            icon: Icons.lock_outline,
            obscure: !_apPassVisible,
            suffix: IconButton(
              icon: Icon(_apPassVisible ? Icons.visibility_off : Icons.visibility,
                color: Colors.white38, size: 18),
              onPressed: () => setState(() => _apPassVisible = !_apPassVisible),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity, height: 46,
            child: ElevatedButton(
              onPressed: _loading ? null : _saveApPassword,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF14B8A6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _loading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Update Hotspot Password',
                      style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeWifiSettings() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('HOME ROUTER CREDENTIALS', style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8))),
              TextButton.icon(
                onPressed: _scanning ? null : _scanNetworks,
                icon: const Icon(Icons.refresh, size: 14, color: Color(0xFF14B8A6)),
                label: const Text('Scan Wi-Fi', style: TextStyle(color: Color(0xFF14B8A6), fontSize: 12)),
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
          _TextField(
            controller: _ssidCtrl,
            hint: 'Wi-Fi Name (SSID)',
            icon: Icons.wifi,
          ),
          const SizedBox(height: 10),
          _TextField(
            controller: _homePassCtrl,
            hint: 'Wi-Fi Password',
            icon: Icons.lock_outline,
            obscure: !_homePassVisible,
            suffix: IconButton(
              icon: Icon(_homePassVisible ? Icons.visibility_off : Icons.visibility,
                color: Colors.white38, size: 18),
              onPressed: () => setState(() => _homePassVisible = !_homePassVisible),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _uploadHomeWifi,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B5CF6),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _loading
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Save & Connect',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 46,
                child: OutlinedButton(
                  onPressed: _loading ? null : _clearHomeWifi,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFEF4444),
                    side: const BorderSide(color: Color(0xFFEF4444)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Clear'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(color: Colors.white.withValues(alpha: 0.08)),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('DEVICE LAN IP ADDRESS', style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8))),
              TextButton.icon(
                onPressed: _loading ? null : _autoDiscoverNetwork,
                icon: const Icon(Icons.saved_search_rounded, size: 16, color: Color(0xFF14B8A6)),
                label: const Text('Auto-Find Device', style: TextStyle(
                  color: Color(0xFF14B8A6), fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _TextField(
            controller: _ipCtrl,
            hint: 'e.g. 192.168.1.50',
            icon: Icons.lan_outlined,
            onChanged: (val) => AppPrefs.setHomeIp(val.trim()),
          ),
        ],
      ),
    );
  }
}

class _ModeSelectCard extends StatelessWidget {
  const _ModeSelectCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF14B8A6).withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? const Color(0xFF14B8A6) : Colors.white.withValues(alpha: 0.08),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22,
              color: selected ? const Color(0xFF14B8A6) : Colors.white54),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : Colors.white70)),
                  Text(subtitle, style: TextStyle(
                    fontSize: 11, color: Colors.white.withValues(alpha: 0.4))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.suffix,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.25)),
        prefixIcon: Icon(icon, color: Colors.white54, size: 18),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF14B8A6)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}
