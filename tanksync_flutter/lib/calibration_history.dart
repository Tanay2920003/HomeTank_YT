import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CalibrationRecord {
  const CalibrationRecord({
    required this.timestamp,
    required this.minDist,
    required this.maxDist,
  });

  final DateTime timestamp;
  final double minDist;
  final double maxDist;

  factory CalibrationRecord.fromJson(Map<String, dynamic> json) {
    return CalibrationRecord(
      timestamp: DateTime.parse(json['timestamp']),
      minDist: (json['minDist'] as num).toDouble(),
      maxDist: (json['maxDist'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'minDist': minDist,
    'maxDist': maxDist,
  };
}

class CalibrationHistoryService {
  static const _key = 'tank_calibration_history';

  static Future<List<CalibrationRecord>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key);
    if (jsonList == null) return [];
    try {
      return jsonList
          .map((s) => CalibrationRecord.fromJson(jsonDecode(s)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  static Future<void> addRecord(double min, double max) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await getHistory();
    // Don't add if it's the exact same as the last record (to avoid duplicates)
    if (history.isNotEmpty) {
      final last = history.first;
      if (last.minDist == min && last.maxDist == max) return;
    }
    final record = CalibrationRecord(
      timestamp: DateTime.now(),
      minDist: min,
      maxDist: max,
    );
    history.insert(0, record); // newest first
    
    // keep last 50 entries
    if (history.length > 50) {
      history.removeRange(50, history.length);
    }
    
    await prefs.setStringList(
        _key, history.map((r) => jsonEncode(r.toJson())).toList());
  }

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

class CalibrationHistoryPage extends StatefulWidget {
  const CalibrationHistoryPage({super.key});

  @override
  State<CalibrationHistoryPage> createState() => _CalibrationHistoryPageState();
}

class _CalibrationHistoryPageState extends State<CalibrationHistoryPage> {
  List<CalibrationRecord>? _history;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final history = await CalibrationHistoryService.getHistory();
    if (mounted) setState(() => _history = history);
  }

  Future<void> _clear() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Clear History'),
        content: const Text('Delete all past calibration records?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await CalibrationHistoryService.clearHistory();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080B10),
        foregroundColor: Colors.white,
        title: const Text('Calibration History',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white54),
            onPressed: _history?.isNotEmpty == true ? _clear : null,
          ),
        ],
      ),
      body: _history == null
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF14B8A6)))
          : _history!.isEmpty
              ? const Center(child: Text('No calibration history yet.', style: TextStyle(color: Colors.white54)))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _history!.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final r = _history![i];
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF14B8A6).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.history, color: Color(0xFF14B8A6), size: 20),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${r.timestamp.year}-${r.timestamp.month.toString().padLeft(2, '0')}-${r.timestamp.day.toString().padLeft(2, '0')} at ${r.timestamp.hour.toString().padLeft(2, '0')}:${r.timestamp.minute.toString().padLeft(2, '0')}',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(child: _Val('Full', r.minDist, const Color(0xFF10B981))),
                                    Expanded(child: _Val('Empty', r.maxDist, const Color(0xFFEF4444))),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

class _Val extends StatelessWidget {
  const _Val(this.label, this.val, this.color);
  final String label;
  final double val;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('${val.toStringAsFixed(1)} cm', style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w800)),
      ],
    );
  }
}
