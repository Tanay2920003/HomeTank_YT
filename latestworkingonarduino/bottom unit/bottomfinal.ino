/*
 * ═══════════════════════════════════════════════════════════════
 *  GROUND CONTROL — final.ino  (Heltec WiFi LoRa 32 V3)
 *  Tank Monitor & Relay Controller
 *  Uses EEPROM-calibrated min/max distance for water % calculation
 * ═══════════════════════════════════════════════════════════════
 *
 *  CALIBRATION
 *  -----------
 *  Before flashing this sketch, run calibrate.ino for a full day.
 *  calibrate.ino writes two floats to EEPROM:
 *    Addr 0-3 : minDist (cm) — sensor distance when tank is FULL
 *    Addr 4-7 : maxDist (cm) — sensor distance when tank is EMPTY
 *    Addr 8   : magic byte 0xCA
 *
 *  This sketch reads those at boot. If not found, it falls back to
 *  TANK_HEIGHT_CM / TANK_FULL_CM hard-coded defaults.
 *
 *  OPERATION
 *  ---------
 *  • Top node sends raw TANK packets (dist, pct, temp, hum, bat, sol).
 *  • This sketch IGNORES the top's pct and recalculates pct from
 *    raw dist using the EEPROM-calibrated min/max.
 *  • Relay logic, buzzer, WiFi AP, Web API — all identical to
 *    bottomfinal.ino.
 *
 *  Libraries: RadioLib, Heltec ESP32 Dev-Boards (HT_SSD1306Wire),
 *             ArduinoJson, EEPROM (built-in)
 *  Board:     Heltec WiFi LoRa 32 (V3)
 * ═══════════════════════════════════════════════════════════════
 */

#include <RadioLib.h>
#include <Wire.h>
#include "HT_SSD1306Wire.h"
#include <WiFi.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <EEPROM.h>

// ─── OLED — Heltec V3 built-in 128×64 ────────────────────────
static SSD1306Wire display(0x3c, 500000, SDA_OLED, SCL_OLED, GEOMETRY_128_64, RST_OLED);

// ─── LoRa SX1262 pins (Heltec V3 fixed wiring) ───────────────
#define LORA_NSS      8
#define LORA_DIO1    14
#define LORA_RST     12
#define LORA_BUSY    13

// ─── Relay & Buzzer ───────────────────────────────────────────
#define RELAY_PIN      4
#define RELAY_ACTIVE  HIGH
#define BUZZER_PIN     7

// 🎵 Notes
#define E5 659
#define DS5 622
#define D5 587
#define C5 523
#define B4 494
#define A4 440
#define G4 392
#define E4 330
#define A3 220
#define F5 698
#define F4 349

// ─── LoRa radio config (must match top node) ─────────────────
#define LORA_FREQ   865.0
#define LORA_BW     125.0
#define LORA_SF       9
#define LORA_CR       7
#define LORA_SYNC   0xAB

// ─── Unit ID (Pairing ID for Multi-Unit Production) ──────────
// Must be identical on both Top and Bottom units! (1-65535)
#define UNIT_ID     1001

// ─── Water level thresholds ───────────────────────────────────
#define LOW_WATER_THRESHOLD   50.0   // % — pump ON  / FILLING command (DEFAULT)
#define FULL_WATER_THRESHOLD  90.0   // % — pump OFF / FULL command  (DEFAULT)

// ─── Timing ───────────────────────────────────────────────────
#define COMMAND_DELAY_MS    300UL
#define ACK_TIMEOUT_MS     4000UL
#define MAX_RETRIES            3
#define STALE_TIMEOUT_MS  480000UL   // 8 min — pump shuts off if top silent this long
#define PAGE_INTERVAL_MS    2000UL
#define DISPLAY_IDLE_MS      500UL

// ─── Sleep durations sent to top node (DEFAULT values) ─────────
#define SLEEP_FILLING_SEC    60
#define SLEEP_FULL_SEC      300
#define SLEEP_NORMAL_SEC    300

// ══════════════════════════════════════════════════════════════
//  SAFETY SETTINGS  ← adjust these to suit your setup
// ══════════════════════════════════════════════════════════════

// 1) Max continuous pump runtime before forced shutoff
//    30 min = 1800 s. Protects against sensor failure / stuck relay.
#define MAX_PUMP_RUN_MS    (30UL * 60UL * 1000UL)

// 2) Offline shutoff — if top sends nothing for this long, pump OFF.
//    Already = STALE_TIMEOUT_MS (2 min). Pump cut happens in loop().

// 3) Blind zone — JSN-SR04T can't measure below ~20 cm.
//    Any reading below this is treated as FULL → pump OFF.
#define MIN_SAFE_DIST_CM   20.0f

// 4) Daily pump cycle limit — max times pump is allowed to START
//    per 24-hour window. Prevents endless cycling.
#define MAX_DAILY_CYCLES      5
#define DAY_MS        (24UL * 60UL * 60UL * 1000UL)

// ─── PWA hotspot / API ────────────────────────────────────────
#define FIRMWARE_VERSION  "1.3.0-settings"
#define DEVICE_MODEL      "Heltec WiFi LoRa 32 V3"
#define AP_SSID           "HomeTank"
#define AP_PASSWORD       "hometank@123"

// ─── EEPROM calibration ───────────────────────────────────────
#define EEPROM_SIZE     256
#define ADDR_MIN_DIST     0   // float, 4 bytes — tank FULL  distance
#define ADDR_MAX_DIST     4   // float, 4 bytes — tank EMPTY distance
#define ADDR_MAGIC        8   // uint8
#define MAGIC_BYTE     0xCA

// ─── EEPROM settings addresses ────────────────────────────────
#define ADDR_SETTINGS_MAGIC  9    // uint8  — 0xCB marks settings valid
#define ADDR_LOW_THRESH     10    // float  4B
#define ADDR_FULL_THRESH    14    // float  4B
#define ADDR_SLEEP_FILL     18    // uint16 2B
#define ADDR_SLEEP_FULL     20    // uint16 2B
#define ADDR_SLEEP_NORM     22    // uint16 2B
#define ADDR_MAX_PUMP_SEC   24    // uint32 4B
#define ADDR_STALE_SEC      28    // uint32 4B
#define ADDR_MIN_DIST_S     32    // float  4B
#define ADDR_MAX_CYCLES     36    // uint8  1B
#define ADDR_CAL_MODE       37    // uint8  1B
#define ADDR_BUZZER_EN      38    // uint8  1B
#define ADDR_BUZZER_FULL    39    // uint8  1B
#define ADDR_BUZZER_RX      40    // uint8  1B
#define ADDR_BUZZER_PUMP    41    // uint8  1B
#define ADDR_AUTO_MODE      42    // uint8  1B
#define SETTINGS_MAGIC    0xD0

// ─── WiFi credential EEPROM addresses ────────────────────────
#define ADDR_HOME_SSID    50    // char[32]  home router SSID
#define ADDR_HOME_PASS    82    // char[64]  home router password
#define ADDR_AP_PASS     146    // char[32]  AP hotspot password
#define ADDR_WIFI_MAGIC  178    // uint8
#define WIFI_MAGIC_BYTE 0xD2

// Hard-coded fallback (used if no EEPROM calibration found)
#define DEFAULT_DIST_FULL    26.9f    // cm — sensor when tank full
#define DEFAULT_DIST_EMPTY   73.2f    // cm — sensor when tank empty
//Replace the numbers with whatever calibrate.ino showed you. For example if you saw minDist = 12.3 and maxDist = 187.4:
//#define DEFAULT_DIST_FULL    12.3f    // cm — sensor when tank full
//#define DEFAULT_DIST_EMPTY  187.4f    // cm — sensor when tank empty
// ─── LoRa object ──────────────────────────────────────────────
SX1262 radio = new Module(LORA_NSS, LORA_DIO1, LORA_RST, LORA_BUSY);
WebServer httpServer(80);
volatile bool loraRxFlag = false;

// ─── Calibration values (loaded from EEPROM at boot) ─────────
float calMinDist = DEFAULT_DIST_FULL;    // tank FULL  (nearest)
float calMaxDist = DEFAULT_DIST_EMPTY;   // tank EMPTY (farthest)
bool  calValid   = false;

// ─── Runtime settings (loaded from EEPROM, changeable via /api/settings) ─────
float    g_lowThreshold    = LOW_WATER_THRESHOLD;   // %
float    g_fullThreshold   = FULL_WATER_THRESHOLD;  // %
uint16_t g_sleepFillingSec = SLEEP_FILLING_SEC;     // s
uint16_t g_sleepFullSec    = SLEEP_FULL_SEC;        // s
uint16_t g_sleepNormalSec  = SLEEP_NORMAL_SEC;      // s
uint32_t g_maxPumpRunSec   = 30 * 60;               // s  (30 min)
uint32_t g_staleTimeoutSec = 480;                   // s  (8 min)
float    g_minSafeDistCm   = MIN_SAFE_DIST_CM;      // cm
uint8_t  g_maxDailyCycles  = MAX_DAILY_CYCLES;
bool     g_calibrateMode   = false;                 // bool
bool     g_buzzerEnabled   = true;
bool     g_buzzerOnFull    = true;
bool     g_buzzerOnRx      = false;
bool     g_buzzerOnPump    = false;
bool     g_autoModeEnabled = true;
uint32_t calPacketCount    = 0;

// ─── Tank telemetry state ─────────────────────────────────────
struct TankData {
  uint16_t unitID    = 0;
  uint16_t id        = 0;
  float    dist      = 0;
  float    pct       = 0;   // recalculated locally using EEPROM cal
  float    temp      = 0;
  float    hum       = 0;
  float    bat       = 0;
  float    sol       = 0;
  float    rssi      = 0;
  float    snr       = 0;
  bool     valid     = false;
  bool     online    = false;
  unsigned long lastRxMs = 0;
};

TankData tank;
String   lastCommand  = "";
String   deviceID     = "HomeTank";
String   localIP      = "192.168.4.1";
uint16_t lastPacketID = 0;
bool     relayState   = false;
bool     g_manualPumpOverride = false;
float    cachedGroundBat = 0;
unsigned long lastGroundBatMs = 0;

// ─── Safety state ─────────────────────────────────────────────
unsigned long pumpStartMs    = 0;      // millis() when pump last turned ON
unsigned int  dailyCycles    = 0;      // pump start count this 24-hr window
unsigned long dayWindowStart = 0;      // start of current 24-hr window
String        safetyAlert    = "";     // last safety event description
bool          safetyTripped  = false;  // true if a safety shutoff fired

// ─── WiFi state ──────────────────────────────────────────
String   g_homeSsid          = "";
String   g_homePass          = "";
String   g_apPass            = AP_PASSWORD;
bool     g_homeWifiConfigured = false;
bool     g_homeWifiConnected  = false;
String   g_homeIp            = "";
unsigned long g_lastHomeCheckMs = 0;

// ─── Display page cycling ─────────────────────────────────────
enum DisplayPage { PAGE_MAIN, PAGE_CAL, PAGE_RELAY, PAGE_SAFETY, PAGE_BOTTOM, PAGE_MODE, PAGE_COUNT };
DisplayPage   currentPage    = PAGE_MAIN;
unsigned long lastPageFlipMs = 0;

// ══════════════════════════════════════════════════════════════
//  HTTP keep-alive helper
// ══════════════════════════════════════════════════════════════

void serviceHttp() { httpServer.handleClient(); }

void delayMs(unsigned long ms) {
  unsigned long start = millis();
  while (millis() - start < ms) { serviceHttp(); delay(1); }
}

// ══════════════════════════════════════════════════════════════
//  Vext power
// ══════════════════════════════════════════════════════════════

void VextON()  { pinMode(Vext, OUTPUT); digitalWrite(Vext, LOW); }
void VextOFF() { pinMode(Vext, OUTPUT); digitalWrite(Vext, HIGH); }

// ══════════════════════════════════════════════════════════════
//  EEPROM calibration
// ══════════════════════════════════════════════════════════════

void loadCalibration() {
  EEPROM.begin(EEPROM_SIZE);
  uint8_t magic = EEPROM.read(ADDR_MAGIC);

  if (magic == MAGIC_BYTE) {
    float mn, mx;
    EEPROM.get(ADDR_MIN_DIST, mn);
    EEPROM.get(ADDR_MAX_DIST, mx);

    if (mn > 0 && mn < 9999.0f && mx > 0 && mx < 9999.0f && mx > mn) {
      calMinDist = mn;
      calMaxDist = mx;
      calValid   = true;
      Serial.printf("📂 EEPROM cal loaded: FULL=%.1fcm  EMPTY=%.1fcm\n", mn, mx);
    } else {
      Serial.println("⚠️  EEPROM data looks invalid — using defaults");
    }
  } else {
    Serial.println("🆕 No calibration in EEPROM — using hard-coded defaults");
    Serial.printf("   FULL=%.1fcm  EMPTY=%.1fcm\n", calMinDist, calMaxDist);
  }
}

// ─── Settings: save & load ────────────────────────────────────

void saveCalibration() {
  EEPROM.put(ADDR_MIN_DIST, calMinDist);
  EEPROM.put(ADDR_MAX_DIST, calMaxDist);
  EEPROM.write(ADDR_MAGIC, MAGIC_BYTE);
  EEPROM.commit();
}

void saveSettings() {
  EEPROM.put(ADDR_LOW_THRESH,   g_lowThreshold);
  EEPROM.put(ADDR_FULL_THRESH,  g_fullThreshold);
  EEPROM.put(ADDR_SLEEP_FILL,   g_sleepFillingSec);
  EEPROM.put(ADDR_SLEEP_FULL,   g_sleepFullSec);
  EEPROM.put(ADDR_SLEEP_NORM,   g_sleepNormalSec);
  EEPROM.put(ADDR_MAX_PUMP_SEC, g_maxPumpRunSec);
  EEPROM.put(ADDR_STALE_SEC,    g_staleTimeoutSec);
  EEPROM.put(ADDR_MIN_DIST_S,   g_minSafeDistCm);
  EEPROM.write(ADDR_MAX_CYCLES, g_maxDailyCycles);
  EEPROM.write(ADDR_CAL_MODE,   g_calibrateMode ? 1 : 0);
  EEPROM.write(ADDR_BUZZER_EN,  g_buzzerEnabled ? 1 : 0);
  EEPROM.write(ADDR_BUZZER_FULL,g_buzzerOnFull ? 1 : 0);
  EEPROM.write(ADDR_BUZZER_RX,  g_buzzerOnRx ? 1 : 0);
  EEPROM.write(ADDR_BUZZER_PUMP,g_buzzerOnPump ? 1 : 0);
  EEPROM.write(ADDR_AUTO_MODE,  g_autoModeEnabled ? 1 : 0);
  EEPROM.write(ADDR_SETTINGS_MAGIC, SETTINGS_MAGIC);
  EEPROM.commit();
  Serial.println("💾 Settings saved to EEPROM");
}

void loadSettings() {
  if (EEPROM.read(ADDR_SETTINGS_MAGIC) != SETTINGS_MAGIC) {
    Serial.println("🆕 No saved settings — using defaults");
    return;
  }
  EEPROM.get(ADDR_LOW_THRESH,   g_lowThreshold);
  EEPROM.get(ADDR_FULL_THRESH,  g_fullThreshold);
  EEPROM.get(ADDR_SLEEP_FILL,   g_sleepFillingSec);
  EEPROM.get(ADDR_SLEEP_FULL,   g_sleepFullSec);
  EEPROM.get(ADDR_SLEEP_NORM,   g_sleepNormalSec);
  EEPROM.get(ADDR_MAX_PUMP_SEC, g_maxPumpRunSec);
  EEPROM.get(ADDR_STALE_SEC,    g_staleTimeoutSec);
  EEPROM.get(ADDR_MIN_DIST_S,   g_minSafeDistCm);
  g_maxDailyCycles  = EEPROM.read(ADDR_MAX_CYCLES);
  g_calibrateMode   = EEPROM.read(ADDR_CAL_MODE) == 1;
  g_buzzerEnabled   = EEPROM.read(ADDR_BUZZER_EN) == 1;
  g_buzzerOnFull    = EEPROM.read(ADDR_BUZZER_FULL) == 1;
  g_buzzerOnRx      = EEPROM.read(ADDR_BUZZER_RX) == 1;
  g_buzzerOnPump    = EEPROM.read(ADDR_BUZZER_PUMP) == 1;
  g_autoModeEnabled = EEPROM.read(ADDR_AUTO_MODE) == 1;
  Serial.println("📂 Settings loaded from EEPROM");
  Serial.printf("   Low:%.0f%% Full:%.0f%% FillSleep:%us FullSleep:%us NormSleep:%us\n",
    g_lowThreshold, g_fullThreshold, g_sleepFillingSec, g_sleepFullSec, g_sleepNormalSec);
  Serial.printf("   MaxPump:%us Stale:%us MinDist:%.1fcm MaxCycles:%u\n",
    g_maxPumpRunSec, g_staleTimeoutSec, g_minSafeDistCm, g_maxDailyCycles);
}

// ─── WiFi credential save/load ───────────────────────────

void loadWifiSettings() {
  if (EEPROM.read(ADDR_WIFI_MAGIC) != WIFI_MAGIC_BYTE) {
    Serial.println("No WiFi creds in EEPROM — using defaults");
    return;
  }
  char buf[65];
  // AP password
  for (int i = 0; i < 32; i++) buf[i] = (char)EEPROM.read(ADDR_AP_PASS + i);
  buf[31] = '\0';
  g_apPass = String(buf);
  if (g_apPass.length() < 8) g_apPass = AP_PASSWORD;
  // Home SSID
  for (int i = 0; i < 32; i++) buf[i] = (char)EEPROM.read(ADDR_HOME_SSID + i);
  buf[31] = '\0';
  g_homeSsid = String(buf);
  // Home password
  for (int i = 0; i < 64; i++) buf[i] = (char)EEPROM.read(ADDR_HOME_PASS + i);
  buf[63] = '\0';
  g_homePass = String(buf);
  g_homeWifiConfigured = (g_homeSsid.length() > 0);
  Serial.printf("WiFi loaded: apPass=%s homeSsid=%s homeConfigured=%d\n",
    g_apPass.c_str(), g_homeSsid.c_str(), g_homeWifiConfigured);
}

void saveWifiSettings() {
  // AP password (32 bytes)
  for (int i = 0; i < 32; i++)
    EEPROM.write(ADDR_AP_PASS + i, i < (int)g_apPass.length() ? g_apPass[i] : 0);
  // Home SSID (32 bytes)
  for (int i = 0; i < 32; i++)
    EEPROM.write(ADDR_HOME_SSID + i, i < (int)g_homeSsid.length() ? g_homeSsid[i] : 0);
  // Home password (64 bytes)
  for (int i = 0; i < 64; i++)
    EEPROM.write(ADDR_HOME_PASS + i, i < (int)g_homePass.length() ? g_homePass[i] : 0);
  EEPROM.write(ADDR_WIFI_MAGIC, WIFI_MAGIC_BYTE);
  EEPROM.commit();
  Serial.println("WiFi settings saved");
}

// ─── Convert raw distance to water % using calibrated range ───
float distToCalPct(float distCm) {
  if (distCm < 0) return -1.0f;
  float range = calMaxDist - calMinDist;
  if (range <= 0) return -1.0f;
  float pct = (1.0f - ((distCm - calMinDist) / range)) * 100.0f;
  return constrain(pct, 0.0f, 100.0f);
}

// ══════════════════════════════════════════════════════════════
//  Buzzer / music helpers
// ══════════════════════════════════════════════════════════════

void play(int note, int duration) {
  ledcWriteTone(BUZZER_PIN, note);
  delayMs(duration);
  ledcWriteTone(BUZZER_PIN, 0);
  delayMs(40);
}

void playStartupMusic() {
  if (!g_buzzerEnabled) return;
  int melody[] = { E5, DS5, E5, DS5, E5, B4, D5, C5, A3 }; play(DS5,150);
  play(E5,150); play(B4,150);  play(D5,150); play(C5,150);
  play(A4,300);
  delayMs(200);
  play(B4,150); play(C5,150); play(D5,150);
  play(E5,300);
  delayMs(150);
  play(G4,150); play(F5,150); play(E5,150);
  play(D5,300);
  delayMs(150);
  play(F4,150); play(E5,150); play(D5,150);
  play(C5,300);
  delayMs(150);
  play(E4,150); play(D5,150); play(C5,150);
  play(B4,300);
  delayMs(200);
  play(A3,200); play(E4,200); play(A4,300);
  ledcWriteTone(BUZZER_PIN, 0);
}

void playBeethoven(bool force = false) {
  if (!force && (!g_buzzerEnabled || !g_buzzerOnFull)) return;
  play(E5,150); play(DS5,150); play(E5,150); play(DS5,150);
  play(E5,150); play(B4,150);  play(D5,150); play(C5,150);
  play(A4,300);
  delayMs(200);
  play(B4,150); play(C5,150); play(D5,150);
  play(E5,300);
  delayMs(150);
  play(G4,150); play(F5,150); play(E5,150);
  play(D5,300);
  delayMs(150);
  play(F4,150); play(E5,150); play(D5,150);
  play(C5,300);
  delayMs(150);
  play(E4,150); play(D5,150); play(C5,150);
  play(B4,300);
  delayMs(200);
  play(A3,200); play(E4,200); play(A4,300);
  ledcWriteTone(BUZZER_PIN, 0);
}

void pumpRunningBeep(bool force = false) {
  if (!force && (!g_buzzerEnabled || !g_buzzerOnPump)) return;
  ledcWriteTone(BUZZER_PIN, 1000);
  delayMs(2000);
  ledcWriteTone(BUZZER_PIN, 0);
  delayMs(200);
  for (int i = 0; i < 4; i++) {
    ledcWriteTone(BUZZER_PIN, 2000);
    delayMs(120);
    ledcWriteTone(BUZZER_PIN, 0);
    delayMs(80);
  }
}

// ══════════════════════════════════════════════════════════════
//  Time helper
// ══════════════════════════════════════════════════════════════

String getTimeStr() {
  unsigned long sec = millis() / 1000;
  unsigned int  min = sec / 60;
  unsigned int  hr  = min / 60;
  sec %= 60; min %= 60;
  char buf[16];
  sprintf(buf, "%02u:%02u:%02lu", hr, min, sec);
  return String(buf);
}

// ══════════════════════════════════════════════════════════════
//  Display helpers
// ══════════════════════════════════════════════════════════════

void drawBar(int x, int y, int w, int h, int pct) {
  display.drawRect(x, y, w, h);
  int fill = (int)((constrain(pct, 0, 100) / 100.0f) * (w - 2));
  if (fill > 0) display.fillRect(x + 1, y + 1, fill, h - 2);
}

// ─── Page 1 : Main overview ───────────────────────────────────
void drawPageMain() {
  display.clear();
  char buf[32];
  float gBat = readGroundBattery();

  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 0, "TANK [ID:" + String(UNIT_ID) + "]");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  display.drawString(127, 0, tank.online ? "ONLINE" : "OFFLNE");
  display.drawHorizontalLine(0, 11, 128);

  uint32_t runSec = (pumpStartMs > 0) ? (millis() - pumpStartMs) / 1000 : 0;
  uint32_t effMaxRunSec = (g_maxPumpRunSec > 0) ? g_maxPumpRunSec : 1800UL;
  uint32_t remSec = (effMaxRunSec > runSec) ? (effMaxRunSec - runSec) : 0;

  if (!tank.valid) {
    display.setTextAlignment(TEXT_ALIGN_CENTER);
    if (relayState) {
      display.drawString(64, 16, "MANUAL PUMP RUNNING");
      snprintf(buf, sizeof(buf), "Left: %02lum %02lus", remSec / 60, remSec % 60);
      display.drawString(64, 29, String(buf));
    } else {
      display.drawString(64, 16, "AP: HomeTank");
      display.drawString(64, 29, "Waiting for top node...");
    }
    snprintf(buf, sizeof(buf), "IP:%s", localIP.c_str());
    display.drawString(64, 41, String(buf));
    snprintf(buf, sizeof(buf), "BotBat:%.2fV  PMP:%s", gBat, relayState ? "ON" : "OFF");
    display.drawString(64, 53, String(buf));
    display.display();
    return;
  }

  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 13, "WTR:");
  drawBar(28, 14, 74, 9, (int)tank.pct);
  snprintf(buf, sizeof(buf), "%3.0f%%", tank.pct);
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  display.drawString(127, 13, buf);

  display.setFont(ArialMT_Plain_16);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  snprintf(buf, sizeof(buf), "%.1f%%", tank.pct);
  display.drawString(0, 24, String(buf));

  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  if      (tank.pct < g_lowThreshold)   display.drawString(127, 27, "FILLING");
  else if (tank.pct >= g_fullThreshold)  display.drawString(127, 27, "FULL");
  else                                   display.drawString(127, 27, "OK");

  display.setTextAlignment(TEXT_ALIGN_LEFT);
  snprintf(buf, sizeof(buf), "T:%.1fC  H:%.0f%%", tank.temp, tank.hum);
  display.drawString(0, 43, String(buf));

  // Show top bat + ground bat + pump state + remaining timer if ON
  if (relayState) {
    snprintf(buf, sizeof(buf), "G:%.1fV PMP:ON (%02lum%02lus)", gBat, remSec / 60, remSec % 60);
  } else {
    snprintf(buf, sizeof(buf), "T:%.1fV G:%.1fV PMP:OFF", tank.bat, gBat);
  }
  display.drawString(0, 53, String(buf));

  display.display();
}

// ─── Page 2 : Calibration info ───────────────────────────────
void drawPageCal() {
  display.clear();
  char buf[28];

  // ── Header ──
  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 0, "CALIBRATE");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  display.drawString(127, 0, (g_calibrateMode && calPacketCount > 0) ? "LIVE" : "WAIT");
  display.drawHorizontalLine(0, 11, 128);

  // ── minDist ──
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 13, "FULL(min):");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  snprintf(buf, sizeof(buf), calMinDist < 9999.0f ? "%.1f cm" : "---", calMinDist);
  display.drawString(127, 13, buf);

  // ── maxDist ──
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 25, "EMTY(max):");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  snprintf(buf, sizeof(buf), calMaxDist > -9999.0f ? "%.1f cm" : "---", calMaxDist);
  display.drawString(127, 25, buf);

  // ── Last raw dist ──
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 37, "Last dist:");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  snprintf(buf, sizeof(buf), tank.valid ? "%.1f cm" : "---", tank.dist);
  display.drawString(127, 37, buf);

  // ── Packet count ──
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 49, g_calibrateMode ? "Pkts:" : "Pct:");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  if (g_calibrateMode) snprintf(buf, sizeof(buf), "%lu", calPacketCount);
  else snprintf(buf, sizeof(buf), "%.1f %%", tank.pct);
  display.drawString(127, 49, buf);

  display.display();
}

// ─── Page 3 : Relay / pump status ────────────────────────────
void drawPageRelay() {
  display.clear();
  char buf[28];

  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 0, "RELAY / PUMP");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  display.drawString(127, 0, g_autoModeEnabled ? "[AUTO]" : "[MAN]");
  display.drawHorizontalLine(0, 11, 128);

  display.setFont(ArialMT_Plain_16);
  display.setTextAlignment(TEXT_ALIGN_CENTER);
  display.drawString(64, 14, "PUMP:");
  display.drawString(64, 32, relayState ? ">>> ON <<<" : "   OFF    ");

  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  snprintf(buf, sizeof(buf), "LVL:%.1f%%  LO:%.0f HI:%.0f",
           tank.pct, g_lowThreshold, g_fullThreshold);
  display.drawString(0, 53, String(buf));

  display.display();
}

// ─── Splash ───────────────────────────────────────────────────
void drawSplash() {
  display.clear();
  display.setTextAlignment(TEXT_ALIGN_CENTER);
  display.setFont(ArialMT_Plain_16);
  display.drawString(64, 4,  "GROUND CTL");
  display.setFont(ArialMT_Plain_10);
  display.drawString(64, 26, "Tank Monitor v1.3-settings");
  display.drawString(64, 38, "Heltec WiFi LoRa V3");
  display.drawString(64, 50, "865 MHz  ID:" + String(UNIT_ID));
  display.display();
  delay(2500);
}

void drawLoRaError() {
  display.clear();
  display.setTextAlignment(TEXT_ALIGN_CENTER);
  display.setFont(ArialMT_Plain_16);
  display.drawString(64, 10, "LoRa FAIL");
  display.setFont(ArialMT_Plain_10);
  display.drawString(64, 34, "Check wiring / module");
  display.drawString(64, 46, "Halted.");
  display.display();
}

// ─── Page 5 : Bottom unit status ────────────────────────────
void drawPageBottom() {
  display.clear();
  char buf[28];

  // ── Header ──
  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 0, "BOTTOM UNIT");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  display.drawString(127, 0, "LOCAL");
  display.drawHorizontalLine(0, 11, 128);

  // ── Battery voltage (big) ──
  float gBat = readGroundBattery();
  display.setFont(ArialMT_Plain_16);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 14, "Battery:");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  snprintf(buf, sizeof(buf), "%.2f V", gBat);
  display.drawString(127, 14, buf);

  // ── Percentage bar (LiPo: 3.0 V empty, 4.2 V full) ──
  int batPct = (int)(((gBat - 3.0f) / (4.2f - 3.0f)) * 100.0f);
  batPct = constrain(batPct, 0, 100);
  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  snprintf(buf, sizeof(buf), "Charge: %d%%", batPct);
  display.drawString(0, 34, buf);
  drawBar(0, 46, 128, 10, batPct);

  display.display();
}

// ─── Page 4 : Safety status ───────────────────────────────────
void drawPageSafety() {
  display.clear();
  char buf[28];

  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 0, safetyTripped ? "!! SAFETY !!": "SAFETY OK");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  display.drawString(127, 0, relayState ? "PUMP:ON" : "PUMP:OFF");
  display.drawHorizontalLine(0, 11, 128);

  // Pump runtime
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  if (relayState && pumpStartMs > 0) {
    unsigned long runSec = (millis() - pumpStartMs) / 1000;
    unsigned long maxSec = g_maxPumpRunSec;
    snprintf(buf, sizeof(buf), "Run: %lus / %lus", runSec, maxSec);
  } else {
    snprintf(buf, sizeof(buf), "Run: --");
  }
  display.drawString(0, 13, buf);

  // Daily cycles
  snprintf(buf, sizeof(buf), "Cycles: %u / %u today", dailyCycles, g_maxDailyCycles);
  display.drawString(0, 25, buf);

  // Min safe dist
  snprintf(buf, sizeof(buf), "Blind zone: <%.0fcm", g_minSafeDistCm);
  display.drawString(0, 37, buf);

  // Alert
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  snprintf(buf, sizeof(buf), safetyAlert.length() ? "Alert: %s" : "Alert: none",
           safetyAlert.c_str());
  display.drawString(0, 49, buf);

  display.display();
}

// ─── Page 6 : Operating Mode ──────────────────────────────────
void drawPageMode() {
  display.clear();

  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_LEFT);
  display.drawString(0, 0, "CONTROL MODE");
  display.setTextAlignment(TEXT_ALIGN_RIGHT);
  display.drawString(127, 0, relayState ? "PUMP:ON" : "PUMP:OFF");
  display.drawHorizontalLine(0, 11, 128);

  display.setFont(ArialMT_Plain_16);
  display.setTextAlignment(TEXT_ALIGN_CENTER);
  if (g_autoModeEnabled) {
    display.drawString(64, 16, "AUTOMATIC");
  } else {
    display.drawString(64, 16, "MANUAL ONLY");
  }

  display.setFont(ArialMT_Plain_10);
  if (g_autoModeEnabled) {
    display.drawString(64, 37, "Level threshold control");
    display.drawString(64, 49, "Auto Fill & Shutoff");
  } else {
    display.drawString(64, 37, "App/API Override");
    display.drawString(64, 49, "Safety cutoffs active");
  }

  display.display();
}

// ─── Page rotation ────────────────────────────────────────────
void updateDisplay() {
  if (g_calibrateMode) {
    drawPageCal();
    return;
  }
  if (millis() - lastPageFlipMs >= PAGE_INTERVAL_MS) {
    lastPageFlipMs = millis();
    currentPage = (DisplayPage)((currentPage + 1) % PAGE_COUNT);
  }
  switch (currentPage) {
    case PAGE_MAIN:   drawPageMain();   break;
    case PAGE_CAL:    drawPageCal();    break;
    case PAGE_RELAY:  drawPageRelay();  break;
    case PAGE_SAFETY: drawPageSafety(); break;
    case PAGE_BOTTOM: drawPageBottom(); break;
    case PAGE_MODE:   drawPageMode();   break;
    default: break;
  }
}

// ══════════════════════════════════════════════════════════════
//  LoRa helpers
// ══════════════════════════════════════════════════════════════

#if defined(ESP8266) || defined(ESP32)
  ICACHE_RAM_ATTR
#endif
void setLoRaRxFlag() { loraRxFlag = true; }

void beginLoRaListen() {
  loraRxFlag = false;
  radio.setDio1Action(setLoRaRxFlag);
  radio.startReceive();
}

bool initLoRa() {
  int s = radio.begin(LORA_FREQ);
  if (s != RADIOLIB_ERR_NONE) {
    Serial.print("LoRa init failed: "); Serial.println(s);
    return false;
  }
  radio.setSpreadingFactor(LORA_SF);
  radio.setBandwidth(LORA_BW);
  radio.setCodingRate(LORA_CR);
  radio.setSyncWord(LORA_SYNC);
  beginLoRaListen();
  return true;
}

// Parse TANK packet — returns raw dist and top's pct (we override pct)
bool parseTelemetry(const String& pkt,
                    uint16_t& unitID, uint16_t& id, float& dist, float& topPct,
                    float& temp, float& hum, float& bat, float& sol) {
  if (!pkt.startsWith("TANK,")) return false;
  return sscanf(pkt.c_str(), "TANK,%hu,%hu,%f,%f,%f,%f,%f,%f",
                &unitID, &id, &dist, &topPct, &temp, &hum, &bat, &sol) == 8;
}

// ─── Relay ────────────────────────────────────────────────────
void setRelay(bool on) {
  bool wasOff = !relayState;
  relayState = on;
  digitalWrite(RELAY_PIN, on ? RELAY_ACTIVE : !RELAY_ACTIVE);
  Serial.print("🔌 RELAY: "); Serial.println(on ? "ON" : "OFF");

  if (on && wasOff) {
    // Pump just turned ON — record start time and count cycle
    pumpStartMs = millis();
    dailyCycles++;
    Serial.printf("   ⏱  Pump ON — cycle %u/%u today\n", dailyCycles, g_maxDailyCycles);
  }
}

// ─── Safety alarm beep ────────────────────────────────────────
void safetyAlarmBeep() {
  if (!g_buzzerEnabled) return;
  // Three sharp double-beeps to signal a safety shutoff
  for (int i = 0; i < 3; i++) {
    ledcWriteTone(BUZZER_PIN, 2500); delayMs(150);
    ledcWriteTone(BUZZER_PIN, 0);    delayMs(80);
    ledcWriteTone(BUZZER_PIN, 2500); delayMs(150);
    ledcWriteTone(BUZZER_PIN, 0);    delayMs(300);
  }
}

// ─── Safety watchdog (called every loop) ─────────────────────
// Returns true if everything is OK to run the pump.
// Shuts pump off immediately if any condition is violated.
void checkSafety() {

  // ── 1. Max continuous pump runtime ──────────────────────────
  uint32_t effMaxRunSec = (g_maxPumpRunSec > 0) ? g_maxPumpRunSec : 1800UL;
  if (relayState && pumpStartMs > 0 &&
      (millis() - pumpStartMs) > (effMaxRunSec * 1000UL)) {
    setRelay(false);
    g_manualPumpOverride = false;
    safetyAlert   = "MAX RUNTIME";
    safetyTripped = true;
    Serial.println("🚨 SAFETY: Max pump runtime exceeded — SHUTOFF");
    safetyAlarmBeep();
  }

  // ── 2. Top node offline → pump off (unless manually turned ON)
  if (relayState && !g_manualPumpOverride && !tank.online) {
    setRelay(false);
    safetyAlert   = "TOP OFFLINE";
    safetyTripped = true;
    Serial.println("🚨 SAFETY: Top node offline — pump SHUTOFF");
    safetyAlarmBeep();
  }

  // ── 3. Bad / blind-zone sensor reading → pump off ───────────
  //    dist < 0 = sensor error; dist < g_minSafeDistCm = blind zone
  if (relayState && !g_manualPumpOverride && tank.online && tank.valid &&
      (tank.dist < 0 || (tank.dist > 0 && tank.dist < g_minSafeDistCm))) {
    setRelay(false);
    g_manualPumpOverride = false;
    safetyAlert   = tank.dist < 0 ? "SENSOR ERROR" : "BLIND ZONE";
    safetyTripped = true;
    Serial.printf("🚨 SAFETY: %s (dist=%.1fcm) — pump SHUTOFF\n",
                  safetyAlert.c_str(), tank.dist);
    safetyAlarmBeep();
  }

  // ── 4. Daily cycle limit ─────────────────────────────────────
  //    Reset counter every 24 hr
  if (millis() - dayWindowStart >= DAY_MS) {
    dayWindowStart = millis();
    dailyCycles    = 0;
    safetyTripped  = false;    // clear trip flag at day reset
    safetyAlert    = "";
    Serial.println("ℹ️ 24-hr window reset — cycle counter cleared");
  }
  // Block pump start if daily limit reached (pump already OFF)
  // Enforcement happens in chooseCommand() below.
}

// ─── Command decision ─────────────────────────────────────────
bool chooseCommand(float pct, String& action, uint16_t& sleepSec) {

  // ── Manual mode: don't auto-control the relay, just tell the top
  //    node a reasonable sleep interval based on current pump state ──
  if (!g_autoModeEnabled) {
    action   = relayState ? "FILLING" : "SLEEP";
    sleepSec = relayState ? g_sleepFillingSec : g_sleepNormalSec;
    return true;
  }

  // ── Bad / blind-zone reading — treat as FULL, shut off ──────
  if (pct < 0 || tank.dist < g_minSafeDistCm) {
    action = "FULL"; sleepSec = g_sleepFullSec;
    g_manualPumpOverride = false;
    if (relayState) setRelay(false);
    Serial.println("⚠️  Bad/blind reading — forcing FULL command");
    return true;
  }

  // ── Daily cycle limit reached — keep pump OFF ────────────────
  if (!relayState && dailyCycles >= g_maxDailyCycles) {
    action = "SLEEP"; sleepSec = g_sleepNormalSec;
    if (safetyAlert == "") safetyAlert = "CYCLE LIMIT";
    Serial.printf("⚠️  Daily cycle limit (%u) reached — no pump start\n",
                  g_maxDailyCycles);
    return true;
  }

  // ── Normal logic ─────────────────────────────────────────────
  if (relayState) {
    if (pct >= g_fullThreshold) {
      action = "FULL"; sleepSec = g_sleepFullSec; setRelay(false);
      g_manualPumpOverride = false;
      safetyAlert   = "";    // clear any prior alert on clean shutoff
      safetyTripped = false;
    } else {
      action = "FILLING"; sleepSec = g_sleepFillingSec; setRelay(true);
    }
    return true;
  }
  if (pct <= g_lowThreshold) {
    action = "FILLING"; sleepSec = g_sleepFillingSec; setRelay(true);
    return true;
  }
  action = "SLEEP"; sleepSec = g_sleepNormalSec; setRelay(false);
  g_manualPumpOverride = false;
  return true;
}

bool waitForAck(const String& expectedAck) {
  unsigned long start = millis();
  beginLoRaListen();

  while (millis() - start < ACK_TIMEOUT_MS) {
    serviceHttp();
    if (loraRxFlag) {
      loraRxFlag = false;
      String ack;
      int s = radio.readData(ack);
      if (s == RADIOLIB_ERR_NONE) {
        Serial.println("ACK: " + ack);
        if (ack == expectedAck) { Serial.println("ACK OK"); return true; }
        Serial.println("Wrong ACK");
      } else {
        Serial.print("ACK read err: "); Serial.println(s);
      }
      beginLoRaListen();
    }
    delay(1);
  }
  return false;
}

bool sendCommandUntilAck(const String& command, uint16_t id, uint16_t sleepSec) {
  String fullCmd     = "CMD:" + command + ":" + String(UNIT_ID) + ":" + String(id) + ":" + String(sleepSec);
  String expectedAck = "ACK:" + command + ":" + String(UNIT_ID) + ":" + String(id);

  for (int i = 1; i <= MAX_RETRIES; i++) {
    Serial.print("\n🕒 "); Serial.print(getTimeStr());
    Serial.print(" | 📤 CMD ("); Serial.print(i); Serial.print("): ");
    Serial.println(fullCmd);

    radio.standby();
    delayMs(80);

    if (radio.transmit(fullCmd) != RADIOLIB_ERR_NONE) {
      Serial.println("❌ TX failed"); continue;
    }

    beginLoRaListen();
    delayMs(20);

    if (waitForAck(expectedAck)) return true;
    Serial.println("⚠️ Retry...");
  }
  return false;
}

// ══════════════════════════════════════════════════════════════
//  PWA JSON API
// ══════════════════════════════════════════════════════════════

// ──── setupWifi() — AP-only or AP+STA (home WiFi) ────────────────
void setupWifi() {
  buildDeviceID();
  const char* apPass = (g_apPass.length() >= 8) ? g_apPass.c_str() : AP_PASSWORD;

  if (g_homeWifiConfigured) {
    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP(AP_SSID, apPass);
    WiFi.setSleep(WIFI_PS_NONE);
    localIP = WiFi.softAPIP().toString();

    Serial.print("Connecting to home WiFi: "); Serial.println(g_homeSsid);
    WiFi.begin(g_homeSsid.c_str(), g_homePass.c_str());
    unsigned long startMs = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - startMs < 12000UL) {
      delay(100);
      serviceHttp();
    }
    if (WiFi.status() == WL_CONNECTED) {
      g_homeWifiConnected = true;
      g_homeIp = WiFi.localIP().toString();
      MDNS.begin("hometank");
      Serial.println("Home WiFi OK: " + g_homeIp);
    } else {
      g_homeWifiConnected = false;
      Serial.println("Home WiFi failed — AP-only fallback");
    }
  } else {
    WiFi.mode(WIFI_AP);
    WiFi.softAP(AP_SSID, apPass);
    WiFi.setSleep(WIFI_PS_NONE);
    localIP = WiFi.softAPIP().toString();
  }
}

void handleScanWifi() {
  addCorsHeaders();
  int n = WiFi.scanNetworks();
  StaticJsonDocument<1024> doc;
  JsonArray arr = doc.createNestedArray("networks");
  for (int i = 0; i < n && i < 15; i++) {
    String ssid = WiFi.SSID(i);
    if (ssid.length() == 0) continue;
    JsonObject net = arr.createNestedObject();
    net["ssid"] = ssid;
    net["rssi"] = WiFi.RSSI(i);
    net["secure"] = (WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
  }
  String out;
  serializeJson(doc, out);
  httpServer.send(200, "application/json", out);
}

// ──── /api/wifi handlers ──────────────────────────────────
void handleGetWifi() {
  addCorsHeaders();
  StaticJsonDocument<256> doc;
  doc["ap_ssid"]        = AP_SSID;
  doc["ap_pass_set"]    = true;
  doc["home_ssid"]      = g_homeSsid;
  doc["home_configured"] = g_homeWifiConfigured;
  doc["home_connected"]  = g_homeWifiConnected;
  doc["home_ip"]        = g_homeIp;
  String out; serializeJson(doc, out);
  httpServer.send(200, "application/json", out);
}

void handlePostWifi() {
  addCorsHeaders();
  if (httpServer.method() == HTTP_OPTIONS) { httpServer.send(204); return; }
  if (!httpServer.hasArg("plain")) {
    httpServer.send(400, "application/json", "{\"ok\":false,\"error\":\"missing_body\"}");
    return;
  }
  StaticJsonDocument<256> req;
  if (deserializeJson(req, httpServer.arg("plain"))) {
    httpServer.send(400, "application/json", "{\"ok\":false,\"error\":\"bad_json\"}");
    return;
  }
  bool changed = false;
  if (req.containsKey("ap_password")) {
    String p = req["ap_password"].as<String>();
    if (p.length() >= 8) { g_apPass = p; changed = true; }
    else {
      httpServer.send(400, "application/json", "{\"ok\":false,\"error\":\"ap_password too short (min 8)\"}\r\n");
      return;
    }
  }
  if (req.containsKey("home_ssid"))     { g_homeSsid = req["home_ssid"].as<String>();     changed = true; }
  if (req.containsKey("home_password")) { g_homePass  = req["home_password"].as<String>(); changed = true; }
  if (req.containsKey("clear_home") && req["clear_home"].as<bool>()) {
    g_homeSsid = ""; g_homePass = ""; g_homeWifiConfigured = false; changed = true;
  }
  if (changed) {
    g_homeWifiConfigured = (g_homeSsid.length() > 0);
    saveWifiSettings();
    // Respond before reboot so app gets 200 OK
    httpServer.send(200, "application/json", "{\"ok\":true,\"reboot\":true}");
    delayMs(800);
    ESP.restart();
    return;
  }
  httpServer.send(200, "application/json", "{\"ok\":true,\"reboot\":false}");
}

void buildDeviceID() {
  uint8_t mac[6];
  WiFi.macAddress(mac);
  char buf[16];
  snprintf(buf, sizeof(buf), "TANK-%02X%02X%02X", mac[3], mac[4], mac[5]);
  deviceID = String(buf);
}

float readGroundBattery() {
  if (millis() - lastGroundBatMs < 5000UL) return cachedGroundBat;
  pinMode(37, OUTPUT);
  digitalWrite(37, HIGH);
  delayMs(5);
  uint32_t sum = 0;
  for (int i = 0; i < 16; i++) {
    sum += analogRead(1);
    delayMicroseconds(500);
  }
  float avgAdc = sum / 16.0f;
  // Calibrated against true multimeter reading (3.32V actual vs 3.15V uncalibrated)
  // Multiplier: 4.9 * (3.32 / 3.15) = 5.164f
  cachedGroundBat = (avgAdc / 4095.0f) * 3.3f * 5.164f;
  digitalWrite(37, LOW);
  lastGroundBatMs = millis();
  return cachedGroundBat;
}

void addCorsHeaders() {
  httpServer.sendHeader("Access-Control-Allow-Origin", "*");
  httpServer.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  httpServer.sendHeader("Access-Control-Allow-Headers", "Content-Type");
}

String buildStatusJson() {
  StaticJsonDocument<1024> doc;

  doc["device_id"] = deviceID;
  doc["unit_id"]   = UNIT_ID;
  doc["firmware"]  = FIRMWARE_VERSION;
  doc["model"]     = DEVICE_MODEL;
  doc["ip"]        = localIP;
  doc["uptime_ms"] = millis();
  doc["relay"]     = relayState;
  doc["pump"]      = relayState;
  doc["online"]    = tank.online;
  doc["valid"]     = tank.valid;
  doc["last_rx_ms"] = tank.lastRxMs;
  doc["ground_bat"] = readGroundBattery();
  doc["calibrate_mode"] = g_calibrateMode;
  doc["auto_mode"]      = g_autoModeEnabled;

  JsonObject t = doc.createNestedObject("tank");
  t["unit_id"] = tank.unitID;
  t["id"]   = tank.id;
  t["dist"] = tank.dist;
  t["pct"]  = tank.pct;
  t["temp"] = tank.temp;
  t["hum"]  = tank.hum;
  t["bat"]  = tank.bat;
  t["sol"]  = tank.sol;
  t["rssi"] = tank.rssi;
  t["snr"]  = tank.snr;

  doc["water"]       = tank.pct;
  doc["distance"]    = tank.dist;
  doc["temp"]        = tank.temp;
  doc["temperature"] = tank.temp;
  doc["humidity"]    = tank.hum;
  doc["battery"]     = tank.bat;
  doc["solar"]       = tank.sol;
  doc["rssi"]        = tank.rssi;

  JsonObject thresholds = doc.createNestedObject("thresholds");
  thresholds["low"]  = g_lowThreshold;
  thresholds["full"] = g_fullThreshold;

  // Calibration info in JSON for PWA inspection
  JsonObject cal = doc.createNestedObject("calibration");
  cal["valid"]    = calValid;
  cal["min_dist"] = calMinDist;
  cal["max_dist"] = calMaxDist;

  // Safety state
  JsonObject safety = doc.createNestedObject("safety");
  safety["tripped"]       = safetyTripped;
  safety["alert"]         = safetyAlert;
  safety["daily_cycles"]  = dailyCycles;
  safety["max_cycles"]    = g_maxDailyCycles;
  safety["reset_in_sec"]  = (DAY_MS - (millis() - dayWindowStart)) / 1000;
  if (relayState && pumpStartMs > 0) {
    safety["pump_run_sec"] = (millis() - pumpStartMs) / 1000;
    safety["max_run_sec"]  = g_maxPumpRunSec;
  } else {
    safety["pump_run_sec"] = 0;
    safety["max_run_sec"]  = g_maxPumpRunSec;
  }

  String out;
  serializeJson(doc, out);
  return out;
}

void handleOptions()    { addCorsHeaders(); httpServer.send(204); }
void handlePing()       { addCorsHeaders(); httpServer.send(200, "application/json", "{\"ok\":true}"); }
void handleStatus()     { addCorsHeaders(); httpServer.send(200, "application/json", buildStatusJson()); }
void handleRoot()       { addCorsHeaders(); httpServer.send(200, "text/plain", "TankSync API running. Use /api/status"); }

void handleDeviceInfo() {
  addCorsHeaders();
  StaticJsonDocument<256> doc;
  doc["device_id"] = deviceID;
  doc["unit_id"]   = UNIT_ID;
  doc["firmware"]  = FIRMWARE_VERSION;
  doc["model"]     = DEVICE_MODEL;
  doc["ip"]        = localIP;
  String out; serializeJson(doc, out);
  httpServer.send(200, "application/json", out);
}

void handleRelay() {
  addCorsHeaders();
  if (httpServer.method() == HTTP_OPTIONS) { httpServer.send(204); return; }
  String body = httpServer.hasArg("plain") ? httpServer.arg("plain") : (httpServer.args() > 0 ? httpServer.arg(0) : "");
  Serial.println("RX /api/relay body=[" + body + "] len=" + String(body.length()));
  if (body.isEmpty()) {
    httpServer.send(400, "application/json", "{\"ok\":false,\"error\":\"missing_body\"}"); return;
  }
  StaticJsonDocument<256> req;
  if (deserializeJson(req, body)) {
    httpServer.send(400, "application/json", "{\"ok\":false,\"error\":\"bad_json\"}"); return;
  }
  if (req.containsKey("duration_sec")) {
    uint32_t newVal = req["duration_sec"].as<uint32_t>();
    if (newVal != g_maxPumpRunSec) {
      g_maxPumpRunSec = newVal;
      saveSettings();
    }
  } else if (req.containsKey("max_pump_run_sec")) {
    uint32_t newVal = req["max_pump_run_sec"].as<uint32_t>();
    if (newVal != g_maxPumpRunSec) {
      g_maxPumpRunSec = newVal;
      saveSettings();
    }
  }
  bool targetState = req["state"].as<bool>();
  if (targetState) {
    safetyTripped = false;
    safetyAlert   = "";
    g_manualPumpOverride = true;
  } else {
    g_manualPumpOverride = false;
  }
  setRelay(targetState);
  httpServer.send(200, "application/json", "{\"ok\":true}");
}

// ─── /api/settings handlers ───────────────────────────────────

String buildSettingsJson() {
  StaticJsonDocument<512> doc;
  doc["low_threshold"]     = g_lowThreshold;
  doc["full_threshold"]    = g_fullThreshold;
  doc["sleep_filling_sec"] = g_sleepFillingSec;
  doc["sleep_full_sec"]    = g_sleepFullSec;
  doc["sleep_normal_sec"]  = g_sleepNormalSec;
  doc["max_pump_run_sec"]  = g_maxPumpRunSec;
  doc["stale_timeout_sec"] = g_staleTimeoutSec;
  doc["min_safe_dist_cm"]  = g_minSafeDistCm;
  doc["max_daily_cycles"]  = g_maxDailyCycles;
  doc["calibrate_mode"]    = g_calibrateMode;
  doc["buzzer_enabled"]    = g_buzzerEnabled;
  doc["buzzer_on_full"]    = g_buzzerOnFull;
  doc["buzzer_on_rx"]      = g_buzzerOnRx;
  doc["buzzer_on_pump"]    = g_buzzerOnPump;
  doc["auto_mode"]         = g_autoModeEnabled;
  // read-only calibration
  JsonObject cal = doc.createNestedObject("calibration");
  cal["valid"]    = calValid;
  cal["min_dist"] = calMinDist;
  cal["max_dist"] = calMaxDist;
  String out; serializeJson(doc, out);
  return out;
}

void handleGetSettings() {
  addCorsHeaders();
  httpServer.send(200, "application/json", buildSettingsJson());
}

void handlePostSettings() {
  addCorsHeaders();
  if (httpServer.method() == HTTP_OPTIONS) { httpServer.send(204); return; }
  String body = httpServer.hasArg("plain") ? httpServer.arg("plain") : (httpServer.args() > 0 ? httpServer.arg(0) : "");
  Serial.println("RX /api/settings body=[" + body + "] len=" + String(body.length()));
  if (body.isEmpty()) {
    httpServer.send(400, "application/json", "{\"ok\":false,\"error\":\"missing_body\"}");
    return;
  }
  StaticJsonDocument<512> req;
  if (deserializeJson(req, body)) {
    httpServer.send(400, "application/json", "{\"ok\":false,\"error\":\"bad_json\"}");
    return;
  }
  bool changed = false;
  if (req.containsKey("low_threshold"))     { g_lowThreshold    = req["low_threshold"].as<float>();    changed = true; }
  if (req.containsKey("full_threshold"))    { g_fullThreshold   = req["full_threshold"].as<float>();   changed = true; }
  if (req.containsKey("sleep_filling_sec")) { g_sleepFillingSec = req["sleep_filling_sec"].as<uint16_t>(); changed = true; }
  if (req.containsKey("sleep_full_sec"))    { g_sleepFullSec    = req["sleep_full_sec"].as<uint16_t>();    changed = true; }
  if (req.containsKey("sleep_normal_sec"))  { g_sleepNormalSec  = req["sleep_normal_sec"].as<uint16_t>();  changed = true; }
  if (req.containsKey("max_pump_run_sec"))  { g_maxPumpRunSec   = req["max_pump_run_sec"].as<uint32_t>();  changed = true; }
  if (req.containsKey("stale_timeout_sec")) { g_staleTimeoutSec = req["stale_timeout_sec"].as<uint32_t>(); changed = true; }
  if (req.containsKey("min_safe_dist_cm"))  { g_minSafeDistCm   = req["min_safe_dist_cm"].as<float>();    changed = true; }
  if (req.containsKey("max_daily_cycles"))  { g_maxDailyCycles  = req["max_daily_cycles"].as<uint8_t>();  changed = true; }
  if (req.containsKey("calibrate_mode")) {
    bool newMode = req["calibrate_mode"].as<bool>();
    if (newMode && !g_calibrateMode) {
      calMinDist = 9999.0f;
      calMaxDist = -9999.0f;
      calPacketCount = 0;
      calValid = false;
      saveCalibration();
      Serial.println("🔄 Calibration mode STARTED — bounds reset");
    } else if (!newMode && g_calibrateMode) {
      Serial.println("🛑 Calibration mode STOPPED");
    }
    g_calibrateMode = newMode;
    changed = true;
  }
  if (req.containsKey("buzzer_enabled")) {
    g_buzzerEnabled = req["buzzer_enabled"].as<bool>();
    changed = true;
  }
  if (req.containsKey("buzzer_on_full")) {
    g_buzzerOnFull = req["buzzer_on_full"].as<bool>();
    changed = true;
  }
  if (req.containsKey("buzzer_on_rx")) {
    g_buzzerOnRx = req["buzzer_on_rx"].as<bool>();
    changed = true;
  }
  if (req.containsKey("buzzer_on_pump")) {
    g_buzzerOnPump = req["buzzer_on_pump"].as<bool>();
    changed = true;
  }
  if (req.containsKey("auto_mode")) {
    g_autoModeEnabled = req["auto_mode"].as<bool>();
    changed = true;
    Serial.println(g_autoModeEnabled ? "🤖 Auto mode ENABLED" : "🖐️ Manual mode ENABLED");
  }
  if (req.containsKey("reset_calibration")) {
    if (req["reset_calibration"].as<bool>()) {
      calMinDist = DEFAULT_DIST_FULL;
      calMaxDist = DEFAULT_DIST_EMPTY;
      calPacketCount = 0;
      calValid = false;
      g_calibrateMode = false;
      saveCalibration();
      Serial.println("🔄 Calibration reset to hardcoded defaults");
      changed = true;
    }
  }
  if (req.containsKey("reset_cycles")) {
    if (req["reset_cycles"].as<bool>()) {
      dailyCycles = 0;
      dayWindowStart = millis();
      Serial.println("🔄 Daily cycle counter reset to 0 via API");
    }
  }
  if (req.containsKey("calibration") && req["calibration"].is<JsonObject>()) {
    JsonObject cal = req["calibration"];
    if (cal.containsKey("min_dist") && cal.containsKey("max_dist")) {
      calMinDist = cal["min_dist"].as<float>();
      calMaxDist = cal["max_dist"].as<float>();
      calValid = true;
      saveCalibration();
      Serial.println("🔄 Calibration restored from manual payload");
    }
  }
  if (req.containsKey("factory_reset")) {
    if (req["factory_reset"].as<bool>()) {
      handleFactoryReset();
      return;
    }
  }
  if (changed) saveSettings();
  httpServer.send(200, "application/json", "{\"ok\":true}");
}

void handleFactoryReset() {
  addCorsHeaders();
  if (httpServer.method() == HTTP_OPTIONS) { httpServer.send(204); return; }
  g_lowThreshold    = LOW_WATER_THRESHOLD;
  g_fullThreshold   = FULL_WATER_THRESHOLD;
  g_sleepFillingSec = SLEEP_FILLING_SEC;
  g_sleepFullSec    = SLEEP_FULL_SEC;
  g_sleepNormalSec  = SLEEP_NORMAL_SEC;
  g_maxPumpRunSec   = 30 * 60;
  g_staleTimeoutSec = 480;
  g_minSafeDistCm   = MIN_SAFE_DIST_CM;
  g_maxDailyCycles  = MAX_DAILY_CYCLES;
  g_calibrateMode   = false;
  g_buzzerEnabled   = true;
  g_buzzerOnFull    = true;
  g_buzzerOnRx      = false;
  g_buzzerOnPump    = false;
  dailyCycles       = 0;
  saveSettings();

  calMinDist = DEFAULT_DIST_FULL;
  calMaxDist = DEFAULT_DIST_EMPTY;
  calPacketCount = 0;
  calValid = false;
  saveCalibration();

  g_apPass = AP_PASSWORD; // Reset AP password to "hometank@123"
  g_homeSsid = "";
  g_homePass = "";
  g_homeWifiConfigured = false;
  saveWifiSettings();

  // Send HTTP 200 response FIRST before teardown so mobile app receives confirmation
  httpServer.send(200, "application/json", "{\"ok\":true,\"factory_reset\":true,\"reboot\":true}");
  delayMs(500);

  // Immediately apply default softAP password so hotspot switches right now
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASSWORD);

  Serial.println("💥 FACTORY RESET COMPLETED — rebooting with out-of-box defaults");
  delayMs(500);
  ESP.restart();
}

void handleResetSettings() {
  addCorsHeaders();
  if (httpServer.method() == HTTP_OPTIONS) { httpServer.send(204); return; }
  g_lowThreshold    = LOW_WATER_THRESHOLD;
  g_fullThreshold   = FULL_WATER_THRESHOLD;
  g_sleepFillingSec = SLEEP_FILLING_SEC;
  g_sleepFullSec    = SLEEP_FULL_SEC;
  g_sleepNormalSec  = SLEEP_NORMAL_SEC;
  g_maxPumpRunSec   = 30 * 60;
  g_staleTimeoutSec = 480;
  g_minSafeDistCm   = MIN_SAFE_DIST_CM;
  g_maxDailyCycles  = MAX_DAILY_CYCLES;
  g_calibrateMode   = false;
  g_buzzerEnabled   = true;
  g_buzzerOnFull    = true;
  g_buzzerOnRx      = false;
  g_buzzerOnPump    = false;
  saveSettings();
  Serial.println("🔄 Settings reset to defaults");
  httpServer.send(200, "application/json", "{\"ok\":true}");
}

void handleBuzzerTest() {
  addCorsHeaders();
  if (httpServer.method() == HTTP_OPTIONS) { httpServer.send(204); return; }
  
  if (g_buzzerEnabled) {
    String type = httpServer.arg("type");
    if (type == "full") {
      playBeethoven(true);
    } else if (type == "rx") {
      ledcWriteTone(BUZZER_PIN, 2000); delayMs(50); ledcWriteTone(BUZZER_PIN, 0);
    } else if (type == "pump") {
      pumpRunningBeep(true);
    } else {
      // Default / alarm test beep
      ledcWriteTone(BUZZER_PIN, 2500); delayMs(150);
      ledcWriteTone(BUZZER_PIN, 0);    delayMs(80);
      ledcWriteTone(BUZZER_PIN, 2500); delayMs(150);
      ledcWriteTone(BUZZER_PIN, 0);
    }
  }
  httpServer.send(200, "application/json", "{\"ok\":true}");
}

void setupHttpServer() {
  httpServer.on("/",                  HTTP_GET,     handleRoot);
  httpServer.on("/api/ping",          HTTP_GET,     handlePing);
  httpServer.on("/api/ping",          HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/device-info",   HTTP_GET,     handleDeviceInfo);
  httpServer.on("/api/device-info",   HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/status",        HTTP_GET,     handleStatus);
  httpServer.on("/api/status",        HTTP_OPTIONS, handleOptions);
  httpServer.on("/data",              HTTP_GET,     handleStatus);
  httpServer.on("/data",              HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/relay",         HTTP_POST,    handleRelay);
  httpServer.on("/api/relay",              HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/buzzer",        HTTP_POST,    handleBuzzerTest);
  httpServer.on("/api/buzzer",        HTTP_GET,     handleBuzzerTest);
  httpServer.on("/api/buzzer",        HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/settings",           HTTP_GET,     handleGetSettings);
  httpServer.on("/api/settings",           HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/settings",           HTTP_POST,    handlePostSettings);
  httpServer.on("/api/settings/reset",     HTTP_POST,    handleResetSettings);
  httpServer.on("/api/settings/reset",     HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/factory_reset",      HTTP_POST,    handleFactoryReset);
  httpServer.on("/api/factory_reset",      HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/wifi/scan",          HTTP_GET,     handleScanWifi);
  httpServer.on("/api/wifi/scan",          HTTP_OPTIONS, handleOptions);
  httpServer.on("/api/wifi",               HTTP_GET,     handleGetWifi);
  httpServer.on("/api/wifi",               HTTP_POST,    handlePostWifi);
  httpServer.on("/api/wifi",               HTTP_OPTIONS, handleOptions);
  httpServer.onNotFound(handleRoot);
  httpServer.begin();
}

// ══════════════════════════════════════════════════════════════
//  SETUP
// ══════════════════════════════════════════════════════════════

void setup() {
  ledcAttach(BUZZER_PIN, 2000, 8);
  Serial.begin(115200);
  delay(300);

  // Load EEPROM calibration FIRST
  loadCalibration();

  // Load runtime settings
  loadSettings();

  // Load WiFi credentials (must be before setupWifi)
  loadWifiSettings();

  VextON();
  delay(100);

  display.init();
  display.clear();
  display.display();
  display.setContrast(255);
  display.screenRotate(ANGLE_0_DEGREE);

  drawSplash();

  pinMode(RELAY_PIN, OUTPUT);
  setRelay(false);

  buildDeviceID();
  setupWifi();
  setupHttpServer();

  Serial.print("PWA AP: ");  Serial.print(AP_SSID);
  Serial.print("  IP: ");    Serial.println(localIP);
  Serial.println("📡 GROUND CONTROL START (final.ino — calibrated)");
  Serial.printf("   Unit ID: %u (Hardcoded pairing)\n", UNIT_ID);
  Serial.printf("   Cal valid: %s  FULL=%.1fcm  EMPTY=%.1fcm\n",
                calValid ? "YES" : "NO (defaults)", calMinDist, calMaxDist);

  if (!initLoRa()) {
    drawLoRaError();
    while (true) delay(1000);
  }

  Serial.println("✅ GROUND CONTROL READY — listening...");

  display.clear();
  display.setFont(ArialMT_Plain_10);
  display.setTextAlignment(TEXT_ALIGN_CENTER);
  display.drawString(64, 12, "AP: HomeTank [ID:" + String(UNIT_ID) + "]");
  display.drawString(64, 26, localIP);
  display.drawString(64, 40, calValid ? "Cal: EEPROM OK" : "Cal: DEFAULTS");
  if (g_homeWifiConnected)
    display.drawString(64, 52, "Home: " + g_homeIp);
  else
    display.drawString(64, 52, "Waiting for top...");
  display.display();
}

// ══════════════════════════════════════════════════════════════
//  LOOP
// ══════════════════════════════════════════════════════════════

void loop() {
  serviceHttp();

  // ── Home WiFi reconnect watchdog (every 60 s) ────────────────
  if (g_homeWifiConfigured && (millis() - g_lastHomeCheckMs >= 60000UL)) {
    g_lastHomeCheckMs = millis();
    if (WiFi.status() != WL_CONNECTED) {
      Serial.println("Home WiFi lost — reconnecting...");
      g_homeWifiConnected = false;
      WiFi.begin(g_homeSsid.c_str(), g_homePass.c_str());
      unsigned long t = millis();
      while (WiFi.status() != WL_CONNECTED && millis() - t < 8000UL) {
        delay(200); serviceHttp();
      }
      if (WiFi.status() == WL_CONNECTED) {
        g_homeWifiConnected = true;
        g_homeIp = WiFi.localIP().toString();
        Serial.println("Home WiFi restored: " + g_homeIp);
      }
    } else {
      g_homeWifiConnected = true;
      g_homeIp = WiFi.localIP().toString();
    }
  }

  // Mark top as offline after stale timeout
  if (tank.lastRxMs > 0 && (millis() - tank.lastRxMs) > (g_staleTimeoutSec * 1000UL))
    tank.online = false;

  // ── Run safety watchdog every loop iteration ─────────────────
  checkSafety();

  if (!loraRxFlag) {
    static unsigned long lastDisplayMs = 0;
    if (millis() - lastDisplayMs >= DISPLAY_IDLE_MS) {
      lastDisplayMs = millis();
      updateDisplay();
    }
    return;
  }

  loraRxFlag = false;
  String received;
  int state = radio.readData(received);

  if (state != RADIOLIB_ERR_NONE) {
    Serial.print("❌ RX read err: "); Serial.println(state);
    beginLoRaListen();
    return;
  }

  float rssi = radio.getRSSI();
  float snr  = radio.getSNR();

  Serial.println("\n------ RECEIVED ------");
  Serial.println(received);
  Serial.print("RSSI: "); Serial.println(rssi);
  Serial.print("SNR : "); Serial.println(snr);

  if (g_buzzerEnabled && g_buzzerOnRx) {
    ledcWriteTone(BUZZER_PIN, 2000);
    delayMs(50);
    ledcWriteTone(BUZZER_PIN, 0);
  }

  uint16_t rxUnitID = 0, id = 0;
  float dist = 0, topPct = 0, temp = 0, hum = 0, bat = 0, sol = 0;

  if (!parseTelemetry(received, rxUnitID, id, dist, topPct, temp, hum, bat, sol)) {
    Serial.println("❌ Bad packet");
    beginLoRaListen();
    return;
  }

  if (rxUnitID != UNIT_ID) {
    Serial.printf("⚠️ Ignored packet from Unit ID %u (Ours: %u)\n", rxUnitID, UNIT_ID);
    beginLoRaListen();
    return;
  }

  // ─── Recalculate pct using our EEPROM-calibrated values ─────
  float pct = distToCalPct(dist);
  Serial.printf("DIST: %.1fcm  topPct: %.1f%%  calPct: %.1f%%\n", dist, topPct, pct);

  tank = { rxUnitID, id, dist, pct, temp, hum, bat, sol, rssi, snr, true, true, millis() };

  // ─── Calibration Mode bypass ────────────────────────────────
  if (g_calibrateMode) {
    calPacketCount++;
    bool updated = false;
    
    if (dist > 0 && dist < calMinDist) {
      calMinDist = dist;
      Serial.printf("   ✅ NEW MIN → %.1f cm (tank FULL direction)\n", calMinDist);
      updated = true;
    }
    
    if (dist > 0 && (dist > calMaxDist || calMaxDist == 9999.0f || calMaxDist == -9999.0f)) {
      calMaxDist = dist;
      Serial.printf("   ✅ NEW MAX → %.1f cm (tank EMPTY direction)\n", calMaxDist);
      updated = true;
    }
    
    if (updated) {
      calValid = true;
      saveCalibration();
      Serial.println("   💾 EEPROM updated");
    }

    if (relayState) setRelay(false); // force pump off

    updateDisplay();

    bool ok = sendCommandUntilAck("SLEEP", id, g_sleepNormalSec);
    Serial.println(ok ? "✅ Delivered: SLEEP (cal)" : "⚠️ No ACK: SLEEP (cal)");
    
    beginLoRaListen();
    return;
  }

  Serial.println("------ PARSED ------");
  Serial.printf("UnitID:%u  PktID:%.0u  Dist:%.1fcm  Pct:%.1f%%  (cal)\n", rxUnitID, id, dist, pct);
  Serial.printf("Temp:%.1fC  Hum:%.0f%%  Bat:%.2fV  Sol:%.2fV\n", temp, hum, bat, sol);

  String action; uint16_t sleepSec = 0;
  chooseCommand(pct, action, sleepSec);

  updateDisplay();

  bool ok = sendCommandUntilAck(action, id, sleepSec);
  Serial.println(ok ? "✅ Delivered: " + action : "⚠️ No ACK: " + action);

  if (ok) {
    updateDisplay();
    if (action == "FILLING") {
      pumpRunningBeep();
    } else if (action == "FULL") {
      Serial.println("🎼 FULL reached");
      playBeethoven();
    }
  }

  beginLoRaListen();
}
