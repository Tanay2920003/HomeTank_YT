// lib/settings_page.dart
// Full settings control screen for the HomeTank ground unit.
// Reads from GET /api/settings and writes via POST /api/settings.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'device_connection.dart';
import 'tank_settings.dart';
import 'calibration_history.dart';
import 'presets_ui.dart';
import 'preset_manager.dart';
import 'wifi_settings_section.dart';
import 'onboarding_page.dart';
import 'app_prefs.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

void _haptic() => HapticFeedback.lightImpact();

class _SettingsPageState extends State<SettingsPage> {
  TankSettings? _settings;
  TankSettings? _original;
  bool _loading = true;
  bool _saving   = false;
  bool _resetting = false;
  String? _error;
  String? _successMsg;

  // ── Controllers for text-input fields ──────────────────────────
  late TextEditingController _ctrlSleepFill;
  late TextEditingController _ctrlSleepFull;
  late TextEditingController _ctrlSleepNorm;
  late TextEditingController _ctrlMaxPumpMin;   // displayed in minutes
  late TextEditingController _ctrlStaleMins;    // displayed in minutes
  late TextEditingController _ctrlMinDist;
  late TextEditingController _ctrlMaxCycles;

  @override
  void initState() {
    super.initState();
    _ctrlSleepFill  = TextEditingController()..addListener(() => setState(() {}));
    _ctrlSleepFull  = TextEditingController()..addListener(() => setState(() {}));
    _ctrlSleepNorm  = TextEditingController()..addListener(() => setState(() {}));
    _ctrlMaxPumpMin = TextEditingController()..addListener(() => setState(() {}));
    _ctrlStaleMins  = TextEditingController()..addListener(() => setState(() {}));
    _ctrlMinDist    = TextEditingController()..addListener(() => setState(() {}));
    _ctrlMaxCycles  = TextEditingController()..addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _ctrlSleepFill.dispose();
    _ctrlSleepFull.dispose();
    _ctrlSleepNorm.dispose();
    _ctrlMaxPumpMin.dispose();
    _ctrlStaleMins.dispose();
    _ctrlMinDist.dispose();
    _ctrlMaxCycles.dispose();
    super.dispose();
  }

  // ── Load settings from device ──────────────────────────────────
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final json = await DeviceConnection.getJson('/api/settings');
      final s = TankSettings.fromJson(json);
      _applySettings(s);
    } catch (e) {
      setState(() { _error = 'Could not load settings: $e'; _loading = false; });
    }
  }

  void _applySettings(TankSettings s) {
    _settings = s;
    _original = TankSettings.fromJson(s.toJson()
      ..addAll({'calibration': {
        'valid': s.calValid, 'min_dist': s.calMinDist, 'max_dist': s.calMaxDist,
      }}));
    _ctrlSleepFill.text  = s.sleepFillingSec.toString();
    _ctrlSleepFull.text  = s.sleepFullSec.toString();
    _ctrlSleepNorm.text  = s.sleepNormalSec.toString();
    _ctrlMaxPumpMin.text = (s.maxPumpRunSec ~/ 60).toString();
    _ctrlStaleMins.text  = (s.staleTimeoutSec ~/ 60).toString();
    _ctrlMinDist.text    = s.minSafeDistCm.toStringAsFixed(1);
    _ctrlMaxCycles.text  = s.maxDailyCycles.toString();
    setState(() { _loading = false; });
  }

  bool get _hasUnsavedChanges {
    if (_settings == null || _original == null) return false;
    _syncFromFields();
    final cur = _settings!;
    final orig = _original!;
    return (cur.lowThreshold - orig.lowThreshold).abs() > 0.01 ||
           (cur.fullThreshold - orig.fullThreshold).abs() > 0.01 ||
           cur.sleepFillingSec != orig.sleepFillingSec ||
           cur.sleepFullSec != orig.sleepFullSec ||
           cur.sleepNormalSec != orig.sleepNormalSec ||
           cur.maxPumpRunSec != orig.maxPumpRunSec ||
           cur.staleTimeoutSec != orig.staleTimeoutSec ||
           (cur.minSafeDistCm - orig.minSafeDistCm).abs() > 0.01 ||
           cur.maxDailyCycles != orig.maxDailyCycles ||
           cur.calibrateMode != orig.calibrateMode ||
           cur.buzzerEnabled != orig.buzzerEnabled ||
           cur.buzzerOnFull != orig.buzzerOnFull ||
           cur.buzzerOnRx != orig.buzzerOnRx ||
           cur.buzzerOnPump != orig.buzzerOnPump;
  }

  // ── Read current form values into _settings ────────────────────
  void _syncFromFields() {
    final s = _settings;
    if (s == null) return;
    _settings = s.copyWith(
      sleepFillingSec: int.tryParse(_ctrlSleepFill.text)  ?? s.sleepFillingSec,
      sleepFullSec:    int.tryParse(_ctrlSleepFull.text)   ?? s.sleepFullSec,
      sleepNormalSec:  int.tryParse(_ctrlSleepNorm.text)   ?? s.sleepNormalSec,
      maxPumpRunSec:   (int.tryParse(_ctrlMaxPumpMin.text) ?? (s.maxPumpRunSec ~/ 60)) * 60,
      staleTimeoutSec: (int.tryParse(_ctrlStaleMins.text)  ?? (s.staleTimeoutSec ~/ 60)) * 60,
      minSafeDistCm:   double.tryParse(_ctrlMinDist.text)  ?? s.minSafeDistCm,
      maxDailyCycles:  int.tryParse(_ctrlMaxCycles.text)   ?? s.maxDailyCycles,
    );
  }

  // ── Save to device ─────────────────────────────────────────────
  Future<void> _save() async {
    _syncFromFields();
    final s = _settings;
    if (s == null) return;
    final wasCalibrating = _original?.calibrateMode == true;
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await DeviceConnection.postJson('/api/settings', s.toJson());
      
      // Reload to get latest calibration bounds
      final json = await DeviceConnection.getJson('/api/settings');
      final newS = TankSettings.fromJson(json);
      _applySettings(newS);

      // If calibration was just turned off and bounds are valid, log them
      if (wasCalibrating && !newS.calibrateMode && newS.calValid) {
        await CalibrationHistoryService.addRecord(newS.calMinDist, newS.calMaxDist);
      }

      setState(() { _successMsg = 'Settings saved ✓'; _saving = false; });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _successMsg = null);
    } catch (e) {
      setState(() { _error = 'Save failed: $e'; _saving = false; });
    }
  }

  Future<void> _resetCalibration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        title: const Text('Reset Calibration?'),
        content: const Text('This will reset tank bounds to hardcoded defaults (26.9 cm and 73.2 cm).'),
        actions: [
          TextButton(onPressed: () { _haptic(); Navigator.pop(ctx, false); }, child: const Text('Cancel')),
          FilledButton(
            onPressed: () { _haptic(); Navigator.pop(ctx, true); },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await DeviceConnection.postJson('/api/settings', {'reset_calibration': true});
      await _load();
      setState(() { _successMsg = 'Calibration reset ✓'; _saving = false; });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _successMsg = null);
    } catch (e) {
      setState(() { _error = 'Reset failed: $e'; _saving = false; });
    }
  }

  Future<void> _resetCycleCount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reset Daily Cycle Counter?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          'This will reset the pump daily cycle count back to 0 on the device.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () { _haptic(); Navigator.pop(ctx, false); }, child: const Text('Cancel')),
          FilledButton(
            onPressed: () { _haptic(); Navigator.pop(ctx, true); },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF14B8A6)),
            child: const Text('Reset Counter'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() { _saving = true; _error = null; _successMsg = null; });
    try {
      await DeviceConnection.postJson('/api/settings', {'reset_cycles': true});
      await _load();
      setState(() { _successMsg = 'Daily cycle count reset to 0 ✓'; _saving = false; });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _successMsg = null);
    } catch (e) {
      setState(() { _error = 'Cycle reset failed: $e'; _saving = false; });
    }
  }

  Future<void> _testBuzzer([String type = '']) async {
    try {
      String path = '/api/buzzer';
      if (type.isNotEmpty) path += '?type=$type';
      await DeviceConnection.postJson(path, {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Buzzer test sent'), duration: Duration(seconds: 1)));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to test buzzer: $e')));
    }
  }

  void _showPresets() {
    _syncFromFields();
    if (_settings == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.6,
        child: PresetsSheet(
          currentSettings: _settings!,
          onLoad: (s) {
            _applySettings(s);
            setState(() { _successMsg = 'Preset loaded. Press Save to apply.'; });
          },
        ),
      ),
    );
  }

  // ── Reset to firmware defaults ─────────────────────────────────
  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        title: const Text('Reset to Defaults?'),
        content: const Text(
          'This will restore all settings to firmware defaults and save them to the device.',
        ),
        actions: [
          TextButton(onPressed: () { _haptic(); Navigator.pop(ctx, false); }, child: const Text('Cancel')),
          FilledButton(
            onPressed: () { _haptic(); Navigator.pop(ctx, true); },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() { _resetting = true; _error = null; _successMsg = null; });
    try {
      await DeviceConnection.postJson('/api/settings/reset', {});
      await _load();
      setState(() { _successMsg = 'Reset to defaults ✓'; _resetting = false; });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _successMsg = null);
    } catch (e) {
      setState(() { _error = 'Reset failed: $e'; _resetting = false; });
    }
  }

  // ── Full Factory Reset ─────────────────────────────────────────
  Future<void> _factoryResetDevice() async {
    _haptic();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444)),
            SizedBox(width: 10),
            Expanded(child: Text('Factory Reset Device?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
          ],
        ),
        content: const Text(
          'WARNING: This will completely revert the HomeTank device to factory out-of-box defaults.\n\n'
          '• Hotspot AP Password reset to default: hometank@123\n'
          '• All custom water thresholds & sleep timers wiped\n'
          '• Saved Home Wi-Fi credentials erased\n'
          '• Water level calibration bounds wiped\n\n'
          'After reset, this device will require calibration and initial setup to work properly.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Factory Reset', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() {
      _resetting = true;
      _error = null;
      _successMsg = 'Performing full factory reset...';
    });

    try {
      // 1. Ensure connected to device before attempting reset
      if (Platform.isAndroid) {
        await DeviceConnection.connect();
      }

      // 2. Send factory reset command to bottom unit device
      await DeviceConnection.postJson('/api/factory_reset', {});

      // 3. ONLY if the bottom unit device resets successfully do we wipe phone app storage
      await AppPrefs.clearAll();
      setState(() {
        _successMsg = 'Device & app factory reset complete.';
        _resetting = false;
      });
      if (!mounted) return;
      final exitApp = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF111827),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: const [
              Icon(Icons.check_circle, color: Color(0xFF14B8A6)),
              SizedBox(width: 10),
              Expanded(
                child: Text('Factory Reset Complete',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          content: const Text(
            'Both your HomeTank device and this mobile app have been completely reset to out-of-box defaults.\n\n'
            '• Hotspot Wi-Fi Password reset to: hometank@123\n'
            '• All mobile app preferences & saved networks wiped\n'
            '• Sensor calibration cleared (recalibration required)\n\n'
            'You can close and reopen the app, or start onboarding setup immediately.',
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Start Setup Now', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF14B8A6)),
              child: const Text('Close App'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (exitApp == true) {
        SystemNavigator.pop();
      } else {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const OnboardingPage()),
          (route) => false,
        );
      }
    } catch (e) {
      setState(() {
        _error = 'Could not reset device ($e). Phone app settings were NOT reset.';
        _resetting = false;
      });
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080B10),
        foregroundColor: Colors.white,
        title: const Text('Device Settings',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (!_loading) ...[
            IconButton(
              icon: const Icon(Icons.bookmarks, size: 20),
              tooltip: 'Presets',
              onPressed: (_saving || _resetting) ? null : () { _haptic(); _showPresets(); },
            ),
            TextButton.icon(
              onPressed: (_saving || _resetting) ? null : () { _haptic(); _reset(); },
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('Defaults'),
              style: TextButton.styleFrom(foregroundColor: Colors.white54),
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF14B8A6)))
          : _error != null && _settings == null
              ? _ErrorView(error: _error!, onRetry: _load)
              : _buildForm(),
      bottomNavigationBar: (_loading || _settings == null || (!_hasUnsavedChanges && !_saving && _successMsg == null))
          ? null
          : _BottomBar(
              saving: _saving || _resetting,
              successMsg: _successMsg,
              error: _error,
              onSave: _save,
            ),
    );
  }

  Widget _buildForm() {
    final s = _settings!;
    final unsaved = _hasUnsavedChanges;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        // ── Water Levels ───────────────────────────────────────
        _SectionHeader('Water Level Thresholds', Icons.water_drop_outlined),
        _SliderTile(
          label: 'Pump ON below',
          value: s.lowThreshold,
          min: 5, max: 80, divisions: 75,
          unit: '%',
          color: const Color(0xFFEF4444),
          hint: 'Pump starts when tank drops to this level',
          onChanged: (v) => setState(() => _settings = s.copyWith(lowThreshold: v)),
        ),
        _SliderTile(
          label: 'Pump OFF above',
          value: s.fullThreshold,
          min: 50, max: 100, divisions: 50,
          unit: '%',
          color: const Color(0xFF10B981),
          hint: 'Pump stops when tank fills to this level',
          onChanged: (v) => setState(() => _settings = s.copyWith(fullThreshold: v)),
        ),
        const SizedBox(height: 8),

        // ── Sleep Timers ──────────────────────────────────────
        _SectionHeader('Sleep Timers (sent to top node)', Icons.bedtime_outlined),
        Row(children: [
          Expanded(child: _NumberField(
            label: 'While Filling', unit: 's',
            hint: 'Top sleep when pump is running',
            controller: _ctrlSleepFill,
          )),
          const SizedBox(width: 10),
          Expanded(child: _NumberField(
            label: 'When Full', unit: 's',
            hint: 'Top sleep after tank is full',
            controller: _ctrlSleepFull,
          )),
          const SizedBox(width: 10),
          Expanded(child: _NumberField(
            label: 'Normal', unit: 's',
            hint: 'Top sleep when level is OK',
            controller: _ctrlSleepNorm,
          )),
        ]),
        const SizedBox(height: 8),

        // ── Safety Limits ───────────────────────────────────────────
        _SectionHeader('Safety Limits', Icons.shield_outlined),
        Row(children: [
          Expanded(child: _NumberField(
            label: 'Max Pump Runtime', unit: 'min',
            hint: 'Auto-shutoff after this many minutes',
            controller: _ctrlMaxPumpMin,
          )),
          const SizedBox(width: 10),
          Expanded(child: _NumberField(
            label: 'Offline Timeout', unit: 'min',
            hint: 'Pump off if top node silent this long',
            controller: _ctrlStaleMins,
          )),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _NumberField(
            label: 'Blind Zone', unit: 'cm',
            hint: 'JSN-SR04T min range — treat as full',
            controller: _ctrlMinDist,
            decimal: true,
          )),
          const SizedBox(width: 10),
          Expanded(child: _NumberField(
            label: 'Max Daily Cycles',
            hint: 'Max pump starts per 24-hour window',
            controller: _ctrlMaxCycles,
          )),
        ]),
        const SizedBox(height: 10),
        InkWell(
          onTap: (_saving || _resetting) ? null : () { _haptic(); _resetCycleCount(); },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF14B8A6).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF14B8A6).withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.refresh_rounded, color: Color(0xFF14B8A6), size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Reset Today\'s Pump Cycle Counter to 0',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.white.withValues(alpha: 0.5), size: 18),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // ── Hardware Operational Modes ───────────────────────────
        _SectionHeader('Hardware Operational Modes', Icons.toggle_on_outlined),
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: s.calibrateMode ? const Color(0xFFF59E0B).withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: s.calibrateMode ? const Color(0xFFF59E0B).withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: s.calibrateMode ? const Color(0xFFF59E0B).withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.tune, color: s.calibrateMode ? const Color(0xFFF59E0B) : Colors.white70, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Calibration Mode', style: TextStyle(
                  color: s.calibrateMode ? const Color(0xFFF59E0B) : Colors.white,
                  fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 2),
                Text(s.calibrateMode 
                  ? 'Pump is OFF. Recording min/max levels.' 
                  : 'Toggle to set new tank dimensions.',
                  style: TextStyle(
                    color: s.calibrateMode ? const Color(0xFFF59E0B).withValues(alpha: 0.8) : Colors.white.withValues(alpha: 0.45),
                    fontSize: 12, fontWeight: FontWeight.w500)),
              ],
            )),
            Switch(
              value: s.calibrateMode,
              activeColor: const Color(0xFFF59E0B),
              onChanged: (v) => setState(() => _settings = s.copyWith(calibrateMode: v)),
            ),
          ]),
        ),

        // ── Device Sounds Toggle ──────────────────────────────
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.volume_up, color: Color(0xFF8B5CF6), size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Device Sounds (Buzzer)', style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(s.buzzerEnabled ? 'Buzzer active' : 'Muted',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12, fontWeight: FontWeight.w500)),
                  ],
                )),
                Switch(
                  value: s.buzzerEnabled,
                  activeColor: const Color(0xFF8B5CF6),
                  onChanged: (v) => setState(() => _settings = s.copyWith(buzzerEnabled: v)),
                ),
              ]),
              if (s.buzzerEnabled) ...[
                const Divider(color: Colors.white10, height: 24),
                CheckboxListTile(
                  title: const Text('Beep when tank is FULL', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Plays a pleasant 3-tone chime when filling finishes', style: TextStyle(fontSize: 12, color: Colors.white54)),
                  value: s.buzzerOnFull,
                  activeColor: const Color(0xFF8B5CF6),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: IconButton(
                    icon: const Icon(Icons.play_circle_outline, color: Color(0xFF8B5CF6)),
                    onPressed: () { _haptic(); _testBuzzer('full'); },
                  ),
                  onChanged: (val) {
                    _haptic();
                    if (val != null) {
                      setState(() => _settings = s.copyWith(buzzerOnFull: val));
                    }
                  },
                ),
                CheckboxListTile(
                  title: const Text('Beep on data received', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Plays a short click whenever telemetry arrives', style: TextStyle(fontSize: 12, color: Colors.white54)),
                  value: s.buzzerOnRx,
                  activeColor: const Color(0xFF8B5CF6),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: IconButton(
                    icon: const Icon(Icons.play_circle_outline, color: Color(0xFF8B5CF6)),
                    onPressed: () { _haptic(); _testBuzzer('rx'); },
                  ),
                  onChanged: (val) {
                    _haptic();
                    if (val != null) {
                      setState(() => _settings = s.copyWith(buzzerOnRx: val));
                    }
                  },
                ),
                CheckboxListTile(
                  title: const Text('Beep while pump is running', style: TextStyle(fontSize: 14)),
                  subtitle: const Text('Plays a repeating pattern every minute while filling', style: TextStyle(fontSize: 12, color: Colors.white54)),
                  value: s.buzzerOnPump,
                  activeColor: const Color(0xFF8B5CF6),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: IconButton(
                    icon: const Icon(Icons.play_circle_outline, color: Color(0xFF8B5CF6)),
                    onPressed: () { _haptic(); _testBuzzer('pump'); },
                  ),
                  onChanged: (val) {
                    _haptic();
                    if (val != null) {
                      setState(() => _settings = s.copyWith(buzzerOnPump: val));
                    }
                  },
                ),
              ],
            ],
          ),
        ),

        // ── INLINE DEVICE SETTINGS SAVE BANNER ─────────────────
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: unsaved
                ? const Color(0xFF14B8A6).withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: unsaved ? const Color(0xFF14B8A6) : Colors.white12,
              width: unsaved ? 1.5 : 1.0,
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    unsaved ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                    color: unsaved ? const Color(0xFF14B8A6) : Colors.white54,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      unsaved ? 'Unsaved Device Settings' : 'Device Settings Synced',
                      style: TextStyle(
                        color: unsaved ? Colors.white : Colors.white70,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
              if (unsaved) ...[
                const SizedBox(height: 6),
                Text(
                  'You have modified your device settings above. Tap Save to apply these changes to your HomeTank hardware.',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: (_saving || _resetting) ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : const Icon(Icons.save_rounded, color: Colors.black),
                    label: Text(
                      _saving ? 'Saving to Device...' : 'Save to Device',
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF14B8A6),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 28),

        // ── Wi-Fi & Network Configuration (SEPARATED) ──────────
        _SectionHeader('Wi-Fi Network Configuration', Icons.wifi_rounded),
        const WifiSettingsSection(),
        const SizedBox(height: 24),

        // ── Calibration Info ──────────────────────────────────
        _SectionHeader('Calibration Bounds', Icons.tune),
        _CalibrationCard(
          settings: s,
          onReset: _resetCalibration,
          onViewHistory: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CalibrationHistoryPage()),
          ),
        ),
        const SizedBox(height: 14),
        _SectionHeader('Device Factory Reset', Icons.restore_rounded),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2937),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4), width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 22),
                  SizedBox(width: 10),
                  Text(
                    'Full Factory Reset',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Reverts the HomeTank device to factory defaults. Direct Hotspot AP password is reset to hometank@123. All thresholds, sleep timers, daily cycles, Wi-Fi credentials, and calibration bounds are wiped.',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.info_outline, color: Color(0xFFEF4444), size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Note: The device will need recalibration to work properly after reset.',
                        style: TextStyle(color: Color(0xFFFCA5A5), fontSize: 11.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_saving || _resetting) ? null : _factoryResetDevice,
                  icon: const Icon(Icons.delete_forever_rounded, color: Color(0xFFEF4444)),
                  label: const Text(
                    'Factory Reset Device',
                    style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.w700),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  Shared UI components
// ══════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, this.icon);
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Row(children: [
        Icon(icon, size: 16, color: const Color(0xFF14B8A6)),
        const SizedBox(width: 8),
        Text(title.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: Color(0xFF14B8A6),
          )),
        const SizedBox(width: 8),
        Expanded(child: Container(height: 1,
          color: Colors.white.withValues(alpha: 0.08))),
      ]),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.unit,
    required this.color,
    required this.hint,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min, max;
  final int divisions;
  final String unit;
  final Color color;
  final String hint;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('${value.round()}$unit',
              style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(hint, style: TextStyle(
          color: Colors.white.withValues(alpha: 0.45), fontSize: 12)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: color,
            thumbColor: color,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
            overlayColor: color.withValues(alpha: 0.15),
            trackHeight: 4,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min, max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ]),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.controller,
    this.unit,
    this.hint,
    this.decimal = false,
  });

  final String label;
  final TextEditingController controller;
  final String? unit;
  final String? hint;
  final bool decimal;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(
        fontWeight: FontWeight.w600, fontSize: 12,
        color: Color(0xFF94A3B8),
      )),
      const SizedBox(height: 6),
      TextFormField(
        controller: controller,
        keyboardType: decimal
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.number,
        inputFormatters: decimal
            ? [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))]
            : [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          suffixText: unit,
          suffixStyle: const TextStyle(color: Color(0xFF14B8A6), fontWeight: FontWeight.w600),
          hintText: hint,
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.25), fontSize: 11),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF14B8A6)),
          ),
        ),
      ),
    ]);
  }
}

class _CalibrationCard extends StatelessWidget {
  const _CalibrationCard({
    required this.settings,
    required this.onReset,
    required this.onViewHistory,
  });
  final TankSettings settings;
  final VoidCallback onReset;
  final VoidCallback onViewHistory;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(children: [
        _CalRow('Status',
          s.calibrateMode ? 'Calibrating...' : (s.calValid ? 'EEPROM loaded' : 'Using defaults'),
          s.calibrateMode ? const Color(0xFFF59E0B) : (s.calValid ? const Color(0xFF10B981) : const Color(0xFFF59E0B))),
        const Divider(color: Color(0x14FFFFFF), height: 18),
        _CalRow('Tank FULL distance',
          (s.calValid || s.calibrateMode) && s.calMinDist < 9999 ? '${s.calMinDist.toStringAsFixed(1)} cm' : '—',
          Colors.white70),
        const SizedBox(height: 6),
        _CalRow('Tank EMPTY distance',
          (s.calValid || s.calibrateMode) && s.calMaxDist > -9999 ? '${s.calMaxDist.toStringAsFixed(1)} cm' : '—',
          Colors.white70),
        if (s.calibrateMode) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFF59E0B)),
            const SizedBox(width: 6),
            Expanded(child: Text(
              'Save this page and refresh to see live bounds update as you move the sensor.',
              style: const TextStyle(fontSize: 11, color: Color(0xFFF59E0B)),
            )),
          ]),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () { _haptic(); onViewHistory(); },
                icon: const Icon(Icons.history, size: 16),
                label: const Text('History'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF14B8A6),
                  side: BorderSide(color: const Color(0xFF14B8A6).withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: s.calValid ? () { _haptic(); onReset(); } : null,
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('Reset'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFEF4444),
                  side: BorderSide(color: const Color(0xFFEF4444).withValues(alpha: s.calValid ? 0.5 : 0.1)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ],
        ),
      ]),
    );
  }
}

class _CalRow extends StatelessWidget {
  const _CalRow(this.label, this.value, this.valueColor);
  final String label, value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: Text(label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.55), fontSize: 13))),
      Text(value, style: TextStyle(
        color: valueColor, fontWeight: FontWeight.w700, fontSize: 13)),
    ]);
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.saving,
    required this.onSave,
    this.successMsg,
    this.error,
  });
  final bool saving;
  final VoidCallback onSave;
  final String? successMsg;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF080B10),
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (successMsg != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 16),
              const SizedBox(width: 6),
              Text(successMsg!, style: const TextStyle(
                color: Color(0xFF10B981), fontWeight: FontWeight.w600)),
            ]),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!,
              style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12),
              textAlign: TextAlign.center),
          ),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: saving ? null : () { _haptic(); onSave(); },
            icon: saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2,
                        color: Colors.white))
                : const Icon(Icons.save_outlined),
            label: Text(saving ? 'Saving...' : 'Save to Device',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF14B8A6),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ]),
    ));
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.wifi_off, size: 48, color: Color(0xFF64748B)),
        const SizedBox(height: 16),
        Text(error, textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF94A3B8))),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () { _haptic(); onRetry(); },
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      ]),
    ));
  }
}
