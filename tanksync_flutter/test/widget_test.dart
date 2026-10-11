import 'package:flutter_test/flutter_test.dart';
import 'package:tanksync_flutter/main.dart';

void main() {
  testWidgets('shows TankSync dashboard', (tester) async {
    await tester.pumpWidget(const TankSyncApp());
    expect(find.text('TankSync'), findsOneWidget);
  });

  group('TankStatus.fromJson matches bottomfinal.ino API', () {
    test('parses full status payload', () {
      final status = TankStatus.fromJson({
        'device_id': 'TANK-A1B2C3',
        'firmware': '1.1.0-pwa',
        'uptime_ms': 120000,
        'last_rx_ms': 115000,
        'relay': true,
        'pump': true,
        'online': true,
        'valid': true,
        'ground_bat': 4.15,
        'tank': {
          'id': 42,
          'dist': 32.5,
          'pct': 68.0,
          'temp': 27.3,
          'hum': 55.0,
          'bat': 4.05,
          'sol': 5.8,
          'rssi': -72.0,
          'snr': 8.5,
        },
      });

      expect(status.deviceId, 'TANK-A1B2C3');
      expect(status.firmware, '1.1.0-pwa');
      expect(status.water, 68.0);
      expect(status.distance, 32.5);
      expect(status.temperature, 27.3);
      expect(status.humidity, 55.0);
      expect(status.battery, 4.05);
      expect(status.solar, 5.8);
      expect(status.groundBattery, 4.15);
      expect(status.rssi, -72.0);
      expect(status.snr, 8.5);
      expect(status.pump, isTrue);
      expect(status.topOnline, isTrue);
      expect(status.valid, isTrue);
      expect(status.lastSeenSeconds, 5);
    });

    test('parses flat fallback fields when tank object is absent', () {
      final status = TankStatus.fromJson({
        'device_id': 'TANK-TEST',
        'firmware': '1.0.0',
        'water': 40.0,
        'distance': 80.0,
        'temperature': 25.0,
        'humidity': 70.0,
        'battery': 3.9,
        'solar': 0.0,
        'rssi': -90.0,
        'relay': false,
        'online': false,
        'valid': false,
      });

      expect(status.water, 40.0);
      expect(status.distance, 80.0);
      expect(status.pump, isFalse);
      expect(status.topOnline, isTrue);
      expect(status.valid, isFalse);
    });

    test('marks top offline when online flag is false', () {
      final status = TankStatus.fromJson({
        'online': false,
        'valid': true,
        'tank': {'pct': 10.0},
      });

      expect(status.topOnline, isFalse);
      expect(status.valid, isTrue);
      expect(status.water, 10.0);
    });
  });
}
