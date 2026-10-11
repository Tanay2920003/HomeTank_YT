// lib/tank_settings.dart
// Data model for all runtime settings on the ground unit.
// Mirrors the JSON schema of GET/POST /api/settings.

class TankSettings {
  // Water level thresholds
  double lowThreshold;    // % — pump turns ON below this
  double fullThreshold;   // % — pump turns OFF above this

  // Sleep durations sent to top node (seconds)
  int sleepFillingSec;    // top sleep while filling
  int sleepFullSec;       // top sleep when tank is full
  int sleepNormalSec;     // top sleep when level is OK

  // Safety
  int maxPumpRunSec;      // max continuous pump runtime (seconds)
  int staleTimeoutSec;    // pump off if top silent this long (seconds)
  double minSafeDistCm;   // blind zone — sensor reading below this = full
  int maxDailyCycles;     // max pump starts per 24-hour window

  // Modes
  bool calibrateMode;     // true = passive calibration mode, pump off
  bool buzzerEnabled;     // true = tones enabled
  bool buzzerOnFull;      // true = beep when full
  bool buzzerOnRx;        // true = beep on packet receive
  bool buzzerOnPump;      // true = beep while pump is running

  // Calibration (read-only — written by calibrate.ino)
  final bool calValid;
  final double calMinDist;
  final double calMaxDist;

  TankSettings({
    this.lowThreshold    = 50.0,
    this.fullThreshold   = 90.0,
    this.sleepFillingSec = 60,
    this.sleepFullSec    = 300,
    this.sleepNormalSec  = 300,
    this.maxPumpRunSec   = 1800,
    this.staleTimeoutSec = 480,
    this.minSafeDistCm   = 20.0,
    this.maxDailyCycles  = 5,
    this.calibrateMode   = false,
    this.buzzerEnabled   = true,
    this.buzzerOnFull    = true,
    this.buzzerOnRx      = false,
    this.buzzerOnPump    = false,
    this.calValid        = false,
    this.calMinDist      = 0,
    this.calMaxDist      = 0,
  });

  factory TankSettings.fromJson(Map<String, dynamic> json) {
    final cal = (json['calibration'] is Map<String, dynamic>)
        ? json['calibration'] as Map<String, dynamic>
        : <String, dynamic>{};

    return TankSettings(
      lowThreshold:    _d(json['low_threshold'])    ?? 50.0,
      fullThreshold:   _d(json['full_threshold'])   ?? 90.0,
      sleepFillingSec: _i(json['sleep_filling_sec']) ?? 60,
      sleepFullSec:    _i(json['sleep_full_sec'])    ?? 300,
      sleepNormalSec:  _i(json['sleep_normal_sec'])  ?? 300,
      maxPumpRunSec:   _i(json['max_pump_run_sec'])  ?? 1800,
      staleTimeoutSec: _i(json['stale_timeout_sec']) ?? 480,
      minSafeDistCm:   _d(json['min_safe_dist_cm'])  ?? 20.0,
      maxDailyCycles:  _i(json['max_daily_cycles'])  ?? 5,
      calibrateMode:   json['calibrate_mode'] == true,
      buzzerEnabled:   json['buzzer_enabled'] != false,
      buzzerOnFull:    json['buzzer_on_full'] != false,
      buzzerOnRx:      json['buzzer_on_rx'] == true,
      buzzerOnPump:    json['buzzer_on_pump'] == true,
      calValid:   cal['valid'] == true,
      calMinDist: _d(cal['min_dist']) ?? 0,
      calMaxDist: _d(cal['max_dist']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'low_threshold':     lowThreshold,
    'full_threshold':    fullThreshold,
    'sleep_filling_sec': sleepFillingSec,
    'sleep_full_sec':    sleepFullSec,
    'sleep_normal_sec':  sleepNormalSec,
    'max_pump_run_sec':  maxPumpRunSec,
    'stale_timeout_sec': staleTimeoutSec,
    'min_safe_dist_cm':  minSafeDistCm,
    'max_daily_cycles':  maxDailyCycles,
    'calibrate_mode':    calibrateMode,
    'buzzer_enabled':    buzzerEnabled,
    'buzzer_on_full':    buzzerOnFull,
    'buzzer_on_rx':      buzzerOnRx,
    'buzzer_on_pump':    buzzerOnPump,
    if (calValid)
      'calibration': {
        'valid': true,
        'min_dist': calMinDist,
        'max_dist': calMaxDist,
      },
  };

  TankSettings copyWith({
    double? lowThreshold,
    double? fullThreshold,
    int? sleepFillingSec,
    int? sleepFullSec,
    int? sleepNormalSec,
    int? maxPumpRunSec,
    int? staleTimeoutSec,
    double? minSafeDistCm,
    int? maxDailyCycles,
    bool? calibrateMode,
    bool? buzzerEnabled,
    bool? buzzerOnFull,
    bool? buzzerOnRx,
    bool? buzzerOnPump,
  }) => TankSettings(
    lowThreshold:    lowThreshold    ?? this.lowThreshold,
    fullThreshold:   fullThreshold   ?? this.fullThreshold,
    sleepFillingSec: sleepFillingSec ?? this.sleepFillingSec,
    sleepFullSec:    sleepFullSec    ?? this.sleepFullSec,
    sleepNormalSec:  sleepNormalSec  ?? this.sleepNormalSec,
    maxPumpRunSec:   maxPumpRunSec   ?? this.maxPumpRunSec,
    staleTimeoutSec: staleTimeoutSec ?? this.staleTimeoutSec,
    minSafeDistCm:   minSafeDistCm   ?? this.minSafeDistCm,
    maxDailyCycles:  maxDailyCycles  ?? this.maxDailyCycles,
    calibrateMode:   calibrateMode   ?? this.calibrateMode,
    buzzerEnabled:   buzzerEnabled   ?? this.buzzerEnabled,
    buzzerOnFull:    buzzerOnFull    ?? this.buzzerOnFull,
    buzzerOnRx:      buzzerOnRx      ?? this.buzzerOnRx,
    buzzerOnPump:    buzzerOnPump    ?? this.buzzerOnPump,
    calValid:   calValid,
    calMinDist: calMinDist,
    calMaxDist: calMaxDist,
  );
}

double? _d(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? _i(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
