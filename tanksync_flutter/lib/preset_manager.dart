import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'tank_settings.dart';

class Preset {
  const Preset({required this.name, required this.settings});
  final String name;
  final TankSettings settings;

  factory Preset.fromJson(Map<String, dynamic> json) {
    return Preset(
      name: json['name'],
      settings: TankSettings.fromJson(json['settings']),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'settings': settings.toJson(),
  };
}

class PresetService {
  static const _key = 'tank_settings_presets';

  static Future<List<Preset>> getPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key);
    if (list == null) return [];
    try {
      return list.map((e) => Preset.fromJson(jsonDecode(e))).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePreset(String name, TankSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    final presets = await getPresets();
    presets.removeWhere((p) => p.name == name);
    presets.add(Preset(name: name, settings: s));
    await prefs.setStringList(_key, presets.map((p) => jsonEncode(p.toJson())).toList());
  }

  static Future<void> deletePreset(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final presets = await getPresets();
    presets.removeWhere((p) => p.name == name);
    await prefs.setStringList(_key, presets.map((p) => jsonEncode(p.toJson())).toList());
  }

  static Future<void> shareSettings(TankSettings s) async {
    final jsonStr = jsonEncode(s.toJson());
    await Share.share(jsonStr, subject: 'HomeTank Settings Preset');
  }

  static TankSettings? parseSharedJson(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr);
      return TankSettings.fromJson(map);
    } catch (_) {
      return null;
    }
  }
}
