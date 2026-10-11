#include <EEPROM.h>

// For ESP32, EEPROM is emulated in flash memory. 
// We define a maximum size (up to 4096 bytes) to clear.
#define EEPROM_SIZE 4096 

void setup() {
  Serial.begin(115200);
  delay(1000); // Give serial monitor time to open
  
  Serial.println("\nStarting EEPROM wipe...");

  // Initialize EEPROM with predefined size
  if (!EEPROM.begin(EEPROM_SIZE)) {
    Serial.println("Failed to initialise EEPROM");
    return;
  }

  // Iterate through all bytes and write 0
  for (int i = 0; i < EEPROM_SIZE; i++) {
    EEPROM.write(i, 0);
    // Print progress every 512 bytes
    if (i % 512 == 0) {
      Serial.printf("Wiped %d bytes...\n", i);
    }
  }
  
  // Commit changes to flash
  EEPROM.commit();
  
  Serial.println("EEPROM wiped successfully!");
}

void loop() {
  // Nothing to do here
}
