# Arduino-WifiLora32-heltec
Water tank automation  dual lora 32 
<img width="669" height="149" alt="image" src="https://github.com/user-attachments/assets/da0ae39f-53ba-4cb8-a0e8-b004f0bae474" />
<img width="291" height="248" alt="image" src="https://github.com/user-attachments/assets/6516fd7a-b17c-446e-a579-f2a418c8871b" />

<img width="384" height="272" alt="image" src="https://github.com/user-attachments/assets/b16aca0b-028b-44b2-a77d-375c540fec8a" />
<img width="478" height="135" alt="image" src="https://github.com/user-attachments/assets/e3a3455c-85aa-4779-9068-bdb1be9b5a34" />


## 🛠️ Arduino IDE Setup & Installation Guide

### 1. Board Manager Setup (Preferences)
To compile for the Heltec WiFi LoRa 32 V3 board, you must add Heltec's board package to Arduino IDE:

1. Open Arduino IDE and navigate to **File** → **Preferences** (or `Ctrl` + `,` on Windows).
2. In the **Additional Boards Manager URLs** field, paste the following URL:
   ```text
   https://resource.heltec.cn/download/package_heltec_esp32_index.json
   ```
   *(If there are already other URLs, separate them with a comma or new line).*
3. Click **OK**.
4. Navigate to **Tools** → **Board** → **Boards Manager...** (or `Ctrl` + `Shift` + `B`).
5. Search for `Heltec ESP32` and install **Heltec ESP32 Series Dev-boards**.
6. Select your board under **Tools** → **Board** → **Heltec ESP32 Series Dev-boards** → **WiFi LoRa 32(V3) / Wireless_Stick_Lite(V3)** (or **Heltec WiFi LoRa 32 (V3)**).

---

### 2. Required Libraries
Install the following required libraries via **Tools** → **Manage Libraries...** (`Ctrl` + `Shift` + `I`):

| Library Name | Author | Purpose | Used In |
| :--- | :--- | :--- | :--- |
| **RadioLib** | Jan Gromeš | SX1262 LoRa radio communication | Both Top & Bottom |
| **Heltec ESP32 Dev-Boards** | Heltec Automation | OLED Display driver (`HT_SSD1306Wire.h`) | Both Top & Bottom |
| **DHT sensor library** | Adafruit | DHT22 temperature & humidity sensor | Top Node |
| **ArduinoJson** | Benoit Blanchon | JSON serialization for web PWA API | Bottom Node |

> [!TIP]
> When installing **Heltec ESP32 Dev-Boards** or **DHT sensor library**, if Arduino IDE prompts you to install missing dependencies (such as Adafruit Unified Sensor), click **Install All**.

---

### 3. Multi-Unit Production Pairing (Unit ID System)
For production deployments where multiple tank systems operate within LoRa radio range, a hardcoded pairing system prevents RF cross-talk:

- In both `top code/top/final/final/final.ino` and `bottomfinal/sketch_apr1h/final/final/final.ino`, locate the configuration definition:
  ```cpp
  #define UNIT_ID 1001
  ```
- **Important**: Both the Top node and Bottom node for a single tank system **must** share the exact same `UNIT_ID`.
- When manufacturing or installing Unit 2, change `#define UNIT_ID 1002` in both files before flashing. For Unit 3, use `1003`, and so on (supported range: `1` to `65535`).
