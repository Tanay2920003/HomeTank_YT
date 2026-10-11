import 'package:flutter/material.dart';

class ManualPage extends StatelessWidget {
  const ManualPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Text('Product Manual'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          _ManualSection(
            title: 'Dashboard Overview',
            icon: Icons.dashboard,
            content: 'The main dashboard provides real-time information about your tank system:\n\n'
                '• Tank Level: The current water level (percentage) in the tank.\n'
                '• Ground Unit & Solar Unit: Battery voltages for both units.\n'
                '• LoRa Signal: The communication strength between the solar and ground units. Tap the signal box to view the exact RSSI value.\n'
                '• Manual Override: Tap the large pump toggle to manually start or stop the pump. This respects the configured safety limits.',
          ),
          SizedBox(height: 20),
          _ManualSection(
            title: 'Water Levels & Auto Pump',
            icon: Icons.water_drop,
            content: 'In the Settings page, you can configure automatic pump operation:\n\n'
                '• Low Water Threshold: When the water drops below this %, the pump turns on automatically.\n'
                '• Full Water Threshold: When the water reaches this %, the pump turns off automatically.\n\n'
                'Ensure your tank is properly calibrated so these percentages are accurate.',
          ),
          SizedBox(height: 20),
          _ManualSection(
            title: 'Presets',
            icon: Icons.bookmarks,
            content: 'Save and load your favorite configurations using Presets.\n\n'
                '• You can save your current setup (alarms, timers, calibration) into a preset.\n'
                '• When loading a preset, you can pick exactly which settings to apply using the tick-boxes.',
          ),
          SizedBox(height: 20),
          _ManualSection(
            title: 'Timers & Sleep',
            icon: Icons.timer,
            content: 'The Solar Unit goes to sleep to save battery. You can configure how often it wakes up and sends data:\n\n'
                '• While Filling: Frequent updates while the pump is running.\n'
                '• When Full: Sleep duration when the tank is completely full.\n'
                '• Normal Mode: Regular update interval for normal operation.',
          ),
          SizedBox(height: 20),
          _ManualSection(
            title: 'Safety Limits',
            icon: Icons.security,
            content: 'Safety is critical to prevent overflowing and pump burnout:\n\n'
                '• Max Pump Run Time: The longest the pump is allowed to run in a single session.\n'
                '• Dead Sensor Timeout: If the Ground Unit hasn\'t heard from the Solar Unit in this time, it assumes the connection is lost and shuts off the pump safely.\n'
                '• Minimum Safe Distance: The absolute highest the water can get before triggering an emergency shut-off.',
          ),
        ],
      ),
    );
  }
}

class _ManualSection extends StatelessWidget {
  final String title;
  final String content;
  final IconData icon;

  const _ManualSection({
    required this.title,
    required this.content,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF67E8F9), size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.7),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
