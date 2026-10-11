import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'preset_manager.dart';
import 'tank_settings.dart';

class PresetsSheet extends StatefulWidget {
  const PresetsSheet({super.key, required this.currentSettings, required this.onLoad});
  final TankSettings currentSettings;
  final ValueChanged<TankSettings> onLoad;

  @override
  State<PresetsSheet> createState() => _PresetsSheetState();
}

class _PresetsSheetState extends State<PresetsSheet> {
  void _haptic() => HapticFeedback.lightImpact();

  List<Preset> _presets = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await PresetService.getPresets();
    setState(() => _presets = list);
  }

  Future<void> _saveCurrent() async {
    final result = await showDialog<_SaveResult>(
      context: context,
      builder: (ctx) => const _SavePresetDialog(),
    );
    if (result != null && result.name.isNotEmpty) {
      // Build a masked version of current settings based on selection
      final s = widget.currentSettings;
      Map<String, dynamic> json = s.toJson();
      if (!result.waterLevels) {
        json.remove('low_threshold');
        json.remove('full_threshold');
      }
      if (!result.timers) {
        json.remove('sleep_filling_sec');
        json.remove('sleep_full_sec');
        json.remove('sleep_normal_sec');
      }
      if (!result.safety) {
        json.remove('max_pump_run_sec');
        json.remove('stale_timeout_sec');
        json.remove('min_safe_dist_cm');
        json.remove('max_daily_cycles');
      }
      if (!result.sounds) {
        json.remove('buzzer_enabled');
        json.remove('buzzer_on_full');
        json.remove('buzzer_on_rx');
        json.remove('buzzer_on_pump');
      }
      if (!result.calibration) {
        json.remove('calibration');
      }
      
      final maskedSettings = TankSettings.fromJson(json);
      await PresetService.savePreset(result.name, maskedSettings);
      await _load();
    }
  }

  void _share(Preset p) async {
    await PresetService.shareSettings(p.settings);
  }

  void _delete(Preset p) async {
    await PresetService.deletePreset(p.name);
    await _load();
  }

  void _import() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data == null || data.text == null || data.text!.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clipboard is empty')));
      return;
    }
    final s = PresetService.parseSharedJson(data.text!);
    if (s == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid preset format on clipboard')));
      return;
    }
    
    // Using the old simple save dialog for imports to keep it fast
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        title: const Text('Save Imported Preset'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Preset Name'),
        ),
        actions: [
          TextButton(onPressed: () { _haptic(); Navigator.pop(ctx); }, child: const Text('Cancel')),
          FilledButton(onPressed: () { _haptic(); Navigator.pop(ctx, ctrl.text); }, child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await PresetService.savePreset(name.trim(), s);
      await _load();
    }
  }
  
  void _onLoadPresetTap(Preset p) async {
    final mask = await showDialog<_LoadMask>(
      context: context,
      builder: (ctx) => _LoadPresetDialog(preset: p),
    );
    if (mask != null) {
      // Merge selected fields into current settings
      var merged = widget.currentSettings.copyWith();
      final pSet = p.settings;
      
      if (mask.waterLevels) {
        merged = merged.copyWith(lowThreshold: pSet.lowThreshold, fullThreshold: pSet.fullThreshold);
      }
      if (mask.timers) {
        merged = merged.copyWith(
          sleepFillingSec: pSet.sleepFillingSec,
          sleepFullSec: pSet.sleepFullSec,
          sleepNormalSec: pSet.sleepNormalSec,
        );
      }
      if (mask.safety) {
        merged = merged.copyWith(
          maxPumpRunSec: pSet.maxPumpRunSec,
          staleTimeoutSec: pSet.staleTimeoutSec,
          minSafeDistCm: pSet.minSafeDistCm,
          maxDailyCycles: pSet.maxDailyCycles,
        );
      }
      if (mask.sounds) {
        merged = merged.copyWith(
          buzzerEnabled: pSet.buzzerEnabled,
          buzzerOnFull: pSet.buzzerOnFull,
          buzzerOnRx: pSet.buzzerOnRx,
          buzzerOnPump: pSet.buzzerOnPump,
        );
      }
      if (mask.calibration && pSet.calValid) {
        // TankSettings doesn't allow updating calMinDist/calMaxDist in copyWith cleanly right now,
        // so we serialize and inject it to recreate a proper object.
        Map<String, dynamic> mergedJson = merged.toJson();
        mergedJson['calibration'] = {
          'valid': true,
          'min_dist': pSet.calMinDist,
          'max_dist': pSet.calMaxDist,
        };
        merged = TankSettings.fromJson(mergedJson);
      }
      
      widget.onLoad(merged);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF080B10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Saved Presets', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.content_paste),
                    tooltip: 'Import from Clipboard',
                    onPressed: () { _haptic(); _haptic(); _import(); },
                  ),
                  TextButton.icon(
                    onPressed: () { _haptic(); _haptic(); _saveCurrent(); },
                    icon: const Icon(Icons.add),
                    label: const Text('Save Current'),
                  ),
                ],
              ),
            ],
          ),
          const Divider(color: Colors.white24),
          Expanded(
            child: _presets.isEmpty
                ? const Center(child: Text('No presets saved.', style: TextStyle(color: Colors.white54)))
                : ListView.builder(
                    itemCount: _presets.length,
                    itemBuilder: (context, index) {
                      final p = _presets[index];
                      return ListTile(
                        title: Text(p.name),
                        subtitle: const Text('Tap to load • Swipe left to delete', style: TextStyle(fontSize: 12, color: Colors.white54)),
                        trailing: IconButton(
                          icon: const Icon(Icons.share, color: Colors.blueAccent),
                          onPressed: () { _haptic(); _haptic(); _share(p); },
                        ),
                        onTap: () { _haptic(); _onLoadPresetTap(p); },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SaveResult {
  final String name;
  final bool waterLevels;
  final bool timers;
  final bool safety;
  final bool sounds;
  final bool calibration;
  _SaveResult(this.name, this.waterLevels, this.timers, this.safety, this.sounds, this.calibration);
}

class _SavePresetDialog extends StatefulWidget {
  const _SavePresetDialog();

  @override
  State<_SavePresetDialog> createState() => _SavePresetDialogState();
}

class _SavePresetDialogState extends State<_SavePresetDialog> {
  void _haptic() => HapticFeedback.lightImpact();

  final _ctrl = TextEditingController();
  bool _waterLevels = true;
  bool _timers = true;
  bool _safety = true;
  bool _sounds = true;
  bool _calibration = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF111827),
      title: const Text('Save Preset'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Preset Name'),
            ),
            const SizedBox(height: 16),
            const Text('Include in Preset:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            CheckboxListTile(
              title: const Text('Water Levels', style: TextStyle(fontSize: 14)),
              value: _waterLevels,
              onChanged: (v) => setState(() => _waterLevels = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              title: const Text('Sleep Timers', style: TextStyle(fontSize: 14)),
              value: _timers,
              onChanged: (v) => setState(() => _timers = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              title: const Text('Safety Limits', style: TextStyle(fontSize: 14)),
              value: _safety,
              onChanged: (v) => setState(() => _safety = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              title: const Text('Device Sounds', style: TextStyle(fontSize: 14)),
              value: _sounds,
              onChanged: (v) => setState(() => _sounds = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              title: const Text('Calibration Bounds', style: TextStyle(fontSize: 14)),
              value: _calibration,
              onChanged: (v) => setState(() => _calibration = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () { _haptic(); _haptic(); Navigator.pop(context); }, child: const Text('Cancel')),
        FilledButton(
          onPressed: () { _haptic();
            if (_ctrl.text.trim().isEmpty) return;
            Navigator.pop(context, _SaveResult(
              _ctrl.text.trim(),
              _waterLevels, _timers, _safety, _sounds, _calibration
            ));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _LoadMask {
  final bool waterLevels;
  final bool timers;
  final bool safety;
  final bool sounds;
  final bool calibration;
  _LoadMask(this.waterLevels, this.timers, this.safety, this.sounds, this.calibration);
}

class _LoadPresetDialog extends StatefulWidget {
  final Preset preset;
  const _LoadPresetDialog({required this.preset});

  @override
  State<_LoadPresetDialog> createState() => _LoadPresetDialogState();
}

class _LoadPresetDialogState extends State<_LoadPresetDialog> {
  void _haptic() => HapticFeedback.lightImpact();

  bool _waterLevels = true;
  bool _timers = true;
  bool _safety = true;
  bool _sounds = true;
  bool _calibration = false;

  @override
  void initState() {
    super.initState();
    _calibration = widget.preset.settings.calValid;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF111827),
      title: Text('Apply Preset: ${widget.preset.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select settings to apply:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('Water Levels', style: TextStyle(fontSize: 14)),
              value: _waterLevels,
              onChanged: (v) => setState(() => _waterLevels = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              title: const Text('Sleep Timers', style: TextStyle(fontSize: 14)),
              value: _timers,
              onChanged: (v) => setState(() => _timers = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              title: const Text('Safety Limits', style: TextStyle(fontSize: 14)),
              value: _safety,
              onChanged: (v) => setState(() => _safety = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              title: const Text('Device Sounds', style: TextStyle(fontSize: 14)),
              value: _sounds,
              onChanged: (v) => setState(() => _sounds = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            if (widget.preset.settings.calValid)
              CheckboxListTile(
                title: const Text('Calibration Bounds', style: TextStyle(fontSize: 14)),
                subtitle: const Text('DANGER: Overrides physical tank bounds', style: TextStyle(fontSize: 12, color: Colors.redAccent)),
                value: _calibration,
                onChanged: (v) => setState(() => _calibration = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () { _haptic(); _haptic(); Navigator.pop(context); }, child: const Text('Cancel')),
        FilledButton(
          onPressed: () { _haptic();
            Navigator.pop(context, _LoadMask(_waterLevels, _timers, _safety, _sounds, _calibration));
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
