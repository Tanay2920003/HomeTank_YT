# HomeTank — Dual LoRa Water Tank Automation

Wireless water tank monitor and pump controller built on the **Heltec WiFi LoRa 32 V3** (SX1262).  
Two ESP32 nodes communicate over LoRa: a **Top Node** inside the tank measures water level + temperature, and a **Bottom Node** controls the pump and serves a Flutter companion app over Wi-Fi.

---

## 📸 Hardware

<img width="400" alt="HomeTank top node installed on tank" src="https://github.com/user-attachments/assets/1cedfdd4-d706-4c1f-b871-279b65e63edc" />

<img width="800" alt="Concrete roof installation" src="https://github.com/user-attachments/assets/92b1540f-d9f7-4b7f-ba38-5122524cf5f6" />

<img width="400" alt="App screenshot — tank level view" src="https://github.com/user-attachments/assets/24b57b5f-6475-49c6-836e-cc71a3cff4df" />

<img width="800" alt="PCB and enclosure" src="https://github.com/user-attachments/assets/be0c0dec-ec70-4c6b-9f77-2830164ca05d" />

---

## 📱 App UI

<table>
  <tr>
    <td align="center"><img width="220" alt="LoRa radio stats" src="https://github.com/user-attachments/assets/da0ae39f-53ba-4cb8-a0e8-b004f0bae474" /></td>
    <td align="center"><img width="220" alt="Connection mode selector" src="https://github.com/user-attachments/assets/6516fd7a-b17c-446e-a579-f2a418c8871b" /></td>
    <td align="center"><img width="220" alt="Wi-Fi settings" src="https://github.com/user-attachments/assets/b16aca0b-028b-44b2-a77d-375c540fec8a" /></td>
    <td align="center"><img width="220" alt="Tank level dashboard" src="https://github.com/user-attachments/assets/e3a3455c-85aa-4779-9068-bdb1be9b5a34" /></td>
  </tr>
</table>

---

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
