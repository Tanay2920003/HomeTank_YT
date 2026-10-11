/*
 * ═══════════════════════════════════════════════════════════════
 *  TOP NODE — Tank Sensor  (Heltec WiFi LoRa 32 V3)
 *  Canonical final version. Do NOT modify this file.
 *  Make changes only in the bottom final.ino.
 * ═══════════════════════════════════════════════════════════════
 *
 *  Reads: ultrasonic distance, DHT22 temp/humidity,
 *         battery voltage, solar voltage.
 *  Sends: TANK,<id>,<dist>,<pct>,<temp>,<hum>,<bat>,<sol>
 *  Receives: CMD:<action>:<id>:<sleepSec> from bottom (ground control)
 *  Replies:  ACK:<action>:<id>
 *
 *  Libraries: RadioLib, DHT sensor library
 *  Board:     Heltec WiFi LoRa 32 (V3)
 * ═══════════════════════════════════════════════════════════════
 */

#include <RadioLib.h>
#include <DHT.h>
#include <esp_sleep.h>

// ─── LoRa SX1262 pins (Heltec V3 fixed wiring) ───────────────
#define LORA_NSS   8
#define LORA_DIO1  14
#define LORA_RST   12
#define LORA_BUSY  13

// ─── Sensors / I/O ────────────────────────────────────────────
#define TRIG_PIN   47
#define ECHO_PIN   48
#define DHT_PIN     4
#define BAT_ADC     6
#define SOL_ADC     7
#define VEXT_PIN   36
#define LED_PIN    35

// ─── Tank config ──────────────────────────────────────────────
// NOTE: These are only used as fallback if no EEPROM calibration
//       exists on the bottom device. The bottom final.ino does
//       the actual pct calculation using its own EEPROM values.
//       Top always sends raw dist and a locally-computed pct.
#define TANK_HEIGHT_CM  200
#define TANK_FULL_CM     10

// ─── LoRa config (must match bottom) ─────────────────────────
#define LORA_FREQ   865.0
#define LORA_BW     125.0
#define LORA_SF       9
#define LORA_CR       7
#define LORA_POWER   22
#define LORA_SYNC   0xAB

// ─── Unit ID (Pairing ID for Multi-Unit Production) ──────────
// Must be identical on both Top and Bottom units! (1-65535)
#define UNIT_ID     1001

// How often to send telemetry when the node is awake
#define SEND_INTERVAL_MS   5000UL

// How long to wait for a command after telemetry is sent
#define COMMAND_WINDOW_MS   5000UL

// ─── Retry & Sleep config ────────────────────────────────────
#define MAX_SEND_ATTEMPTS       5     // Max sends without a response before sleeping
#define NO_RESPONSE_SLEEP_SEC 180     // Sleep for 3 minutes (180 s) if no response

SX1262 radio = new Module(LORA_NSS, LORA_DIO1, LORA_RST, LORA_BUSY);
DHT dht(DHT_PIN, DHT22);

RTC_DATA_ATTR uint16_t packetID = 0;  // Preserved across deep sleep
uint8_t sendAttempt = 0;
unsigned long lastSendMs = 0;
float cachedBat = 0;
unsigned long lastBatMs = 0;

// ─── Sensor helpers ──────────────────────────────────────────

float readBatteryVoltage() {
  if (millis() - lastBatMs < 5000UL && cachedBat > 0) return cachedBat;
  pinMode(37, OUTPUT);
  digitalWrite(37, HIGH);
  delay(5);
  uint32_t sum = 0;
  for (int i = 0; i < 16; i++) {
    sum += analogRead(1);
    delayMicroseconds(500);
  }
  float avgAdc = sum / 16.0f;
  // Calibrated against true multimeter reading (3.47V actual vs 3.57V displayed with 5.925f multiplier)
  // Multiplier: 5.925 * (3.47 / 3.57) = 5.759f
  cachedBat = (avgAdc / 4095.0f) * 3.3f * 5.759f;
  digitalWrite(37, LOW);
  lastBatMs = millis();
  return cachedBat;
}

float readSolarVoltage() {
  uint32_t sum = 0;
  for (int i = 0; i < 16; i++) {
    sum += analogRead(SOL_ADC);
    delayMicroseconds(500);
  }
  float raw = sum / 16.0f;
  float voltage = (raw / 4095.0f) * 3.3f;
  // Calibrated against true multimeter reading (0.40V actual vs 0.28V displayed with 6.49f multiplier)
  // Multiplier: 6.49 * (0.40 / 0.28) = 9.27f
  return voltage * 9.27f;
}

float readDistanceCm() {
  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(4);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  long duration = pulseIn(ECHO_PIN, HIGH, 35000UL);
  if (duration == 0) return -1.0f;

  return (duration / 2.0f) * 0.0343f;
}

float distToWaterPct(float distCm) {
  if (distCm < 0) return -1.0f;

  float range = TANK_HEIGHT_CM - TANK_FULL_CM;
  float pct = (1.0f - ((distCm - TANK_FULL_CM) / range)) * 100.0f;
  return constrain(pct, 0.0f, 100.0f);
}

// ─── LoRa helpers ─────────────────────────────────────────────

bool initLoRa() {
  int state = radio.begin(LORA_FREQ);
  if (state != RADIOLIB_ERR_NONE) {
    Serial.print("LoRa init failed, code: ");
    Serial.println(state);
    return false;
  }

  radio.setOutputPower(LORA_POWER);
  radio.setSpreadingFactor(LORA_SF);
  radio.setBandwidth(LORA_BW);
  radio.setCodingRate(LORA_CR);
  radio.setSyncWord(LORA_SYNC);

  return true;
}

void sendTelemetry(uint16_t id,
                   float dist, float pct,
                   float temp, float hum,
                   float bat, float sol) {
  char payload[128];
  snprintf(payload, sizeof(payload),
           "TANK,%u,%u,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f",
           UNIT_ID, id, dist, pct, temp, hum, bat, sol);

  Serial.println("\n📤 DATA SENT");
  Serial.println(payload);

  int state = radio.transmit(payload);
  if (state != RADIOLIB_ERR_NONE) {
    Serial.print("❌ TX failed, code: ");
    Serial.println(state);
  }
}

bool parseCommand(const String& cmd, String& action, uint16_t& unitID, uint16_t& id, uint16_t& sleepSec) {
  // Expected format: CMD:FILLING:1001:13:60 | CMD:FULL:1001:13:300 | CMD:SLEEP:1001:13:300
  if (!cmd.startsWith("CMD:")) return false;

  int p1 = cmd.indexOf(':');               // after CMD
  int p2 = cmd.indexOf(':', p1 + 1);       // after ACTION
  int p3 = cmd.indexOf(':', p2 + 1);       // after UNIT_ID
  int p4 = cmd.indexOf(':', p3 + 1);       // after PACKET_ID

  if (p1 < 0 || p2 < 0 || p3 < 0 || p4 < 0) return false;

  action   = cmd.substring(p1 + 1, p2);
  unitID   = (uint16_t)cmd.substring(p2 + 1, p3).toInt();
  id       = (uint16_t)cmd.substring(p3 + 1, p4).toInt();
  sleepSec = (uint16_t)cmd.substring(p4 + 1).toInt();

  return action.length() > 0 && unitID > 0 && id > 0;
}

void sleepForSeconds(uint16_t sec) {
  if (sec == 0) return;

  Serial.print("💤 Sleeping for ");
  Serial.print(sec);
  Serial.println(" seconds");

  digitalWrite(LED_PIN, LOW);
  radio.standby();
  delay(80);
  radio.sleep();
  esp_deep_sleep((uint64_t)sec * 1000000ULL);
}

// Wait for one command that matches the packet ID we just sent. Returns true if command handled.
bool listenAndHandleCommand(uint16_t expectedID) {
  Serial.println("👂 Listening for control command...");

  unsigned long start = millis();

  while (millis() - start < COMMAND_WINDOW_MS) {
    String cmd;
    int state = radio.receive(cmd);

    if (state == RADIOLIB_ERR_NONE) {
      Serial.println("📩 GOT CMD: " + cmd);

      String action;
      uint16_t rxUnitID = 0;
      uint16_t id = 0;
      uint16_t sleepSec = 0;

      if (!parseCommand(cmd, action, rxUnitID, id, sleepSec)) {
        Serial.println("❌ Invalid command format");
        continue;
      }

      if (rxUnitID != UNIT_ID) {
        Serial.print("⚠️ Command for another Unit ID ignored. Expected: ");
        Serial.print(UNIT_ID);
        Serial.print(", got: ");
        Serial.println(rxUnitID);
        continue;
      }

      if (id != expectedID) {
        Serial.print("⚠️ Stale command ignored. Expected ID ");
        Serial.print(expectedID);
        Serial.print(", got ");
        Serial.println(id);
        continue;
      }

      String ack = "ACK:" + action + ":" + String(UNIT_ID) + ":" + String(id);

      radio.standby();
      delay(80);

      if (radio.transmit(ack) == RADIOLIB_ERR_NONE) {
        Serial.println("📤 " + ack);
      } else {
        Serial.println("❌ ACK send failed");
        continue;
      }

      // Execute sleep as instructed by ground control
      if (sleepSec > 0) {
        delay(150);
        sleepForSeconds(sleepSec);
      }

      return true;
    }

    if (state != RADIOLIB_ERR_RX_TIMEOUT) {
      Serial.print("❌ RX error: ");
      Serial.println(state);
      return false;
    }
  }

  Serial.println("ℹ️ No command received — continuing");
  return false;
}

// ─── SETUP ────────────────────────────────────────────────────

void setup() {
  Serial.begin(115200);
  delay(1000);

  esp_reset_reason_t reason = esp_reset_reason();
  if (reason != ESP_RST_DEEPSLEEP) {
    packetID = 0;
  } else {
    Serial.println("⏰ Woke up from deep sleep");
  }

  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, HIGH);

  pinMode(VEXT_PIN, OUTPUT);
  digitalWrite(VEXT_PIN, LOW);
  delay(150);

  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);

  analogSetAttenuation(ADC_11db);

  dht.begin();
  delay(1500);

  Serial.println("📡 TOP NODE START — final.ino");
  Serial.print("🔐 UNIT ID: ");
  Serial.println(UNIT_ID);

  if (!initLoRa()) {
    Serial.println("❌ LoRa init failed — rebooting in 5s");
    delay(5000);
    ESP.restart();
  }

  radio.standby();
  Serial.println("✅ TOP NODE READY");
}

// ─── LOOP ─────────────────────────────────────────────────────

void loop() {
  if (millis() - lastSendMs >= SEND_INTERVAL_MS) {
    lastSendMs = millis();

    float dist = readDistanceCm();
    float pct  = distToWaterPct(dist);
    float temp = dht.readTemperature();
    float hum  = dht.readHumidity();
    float bat  = readBatteryVoltage();
    float sol  = readSolarVoltage();

    if (isnan(temp)) temp = -99;
    if (isnan(hum))  hum  = -99;

    packetID++;
    sendAttempt++;

    Serial.println("------ DATA ------");
    Serial.print("UNIT ID: "); Serial.println(UNIT_ID);
    Serial.print("PKT ID: ");  Serial.println(packetID);
    Serial.print("ATTEMPT: "); Serial.print(sendAttempt);
    Serial.print(" / ");       Serial.println(MAX_SEND_ATTEMPTS);
    Serial.print("DIST: "); Serial.println(dist);
    Serial.print("PCT: ");  Serial.println(pct);
    Serial.print("TEMP: "); Serial.println(temp);
    Serial.print("HUM: ");  Serial.println(hum);
    Serial.print("BAT: ");  Serial.println(bat);
    Serial.print("SOL: ");  Serial.println(sol);

    sendTelemetry(packetID, dist, pct, temp, hum, bat, sol);

    // After TX, immediately listen for the ground-control command
    radio.standby();
    delay(30);
    bool receivedCmd = listenAndHandleCommand(packetID);

    if (receivedCmd) {
      sendAttempt = 0;
    } else {
      if (sendAttempt >= MAX_SEND_ATTEMPTS) {
        Serial.println("⚠️ No response after 5 attempts — sleeping for 3 minutes");
        sendAttempt = 0;
        sleepForSeconds(NO_RESPONSE_SLEEP_SEC);
      }
    }
  }
}
