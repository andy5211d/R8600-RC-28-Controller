// MainSketch.pde
// Main UI sketch: Frequency + Step boxes only, logs stay in IDE console
// Updated: loads config.json and frequencies.json, passes freqs into CIVComms/RC28Comm
// Uses parseFreq() + sendSetFrequency() for preset keys
// Now working with two json files for config.  


import java.util.concurrent.CopyOnWriteArrayList;
import processing.serial.*;
import org.hid4java.*;
import java.lang.reflect.Method;

CopyOnWriteArrayList<String> logs = new CopyOnWriteArrayList<String>();
RC28Comm rc28Comm;
CIVComms civWin;

JSONObject config;
JSONObject freqs;

void setup() {
  size(400, 600);
  textFont(createFont("Consolas", 14));
  textAlign(LEFT, TOP);

  logs = new CopyOnWriteArrayList<String>();

  // --- Load configuration ---
  try {
    config = loadJSONObject("config.json");
  } catch (Exception e) {
    config = new JSONObject();
    config.setString("comPort", "COM3");
    config.setInt("baudRate", 9600);
    config.setString("hidDevice", "RC-28");
    saveJSONObject(config, "config.json");
    println("Created default config.json");
  }

  // --- Load frequency presets ---
  try {
    freqs = loadJSONObject("frequencies.json");
  } catch (Exception e) {
    freqs = new JSONObject();
    freqs.setString("F1_short", "145.500");
    freqs.setString("F1_long", "433.500");
    freqs.setString("F2_short", "7.100");
    freqs.setString("F2_long", "14.200");
    saveJSONObject(freqs, "frequencies.json");
    println("Created default frequencies.json");
  }

  // Initialise CIVComms first so RC28Comm can call into it immediately
  civWin = new CIVComms(this, logs,
                        config.getString("comPort"),
                        config.getInt("baudRate"),
                        freqs);

  // Pass CIVComms + freqs into RC28Comm
  rc28Comm = new RC28Comm(logs, civWin, freqs, config.getString("hidDevice"), config);

  println("Setup complete. CIVComms and RC28Comm initialised.");
}

void draw() {
  background(20);

  // Poll HID
  rc28Comm.poll();

  // Poll CIVComms port
  civWin.readSerial();

  // Draw the Frequency + Step UI
  civWin.drawUI();
}

void keyPressed() {
  if (key == 'c') logs.clear();

  if (civWin != null) {
    if (key == 'm') {         // read mode/filter
      civWin.sendQueryMode("Keyboard Mode Query");
    }
    if (key == 'f') {         // read frequency
      civWin.sendQueryFrequency("Keyboard Freq Query");
    }
    if (key == 's') {         // try read step (may depend on firmware)
      civWin.sendQueryStep("Keyboard Step Query");
    }

    // Preset keys: use parseFreq() + sendSetFrequency()
    if (key == '1') {
      int target = civWin.parseFreq(freqs.getString("F1_short"));
      civWin.sendSetFrequency("Keyboard F1 Short", target);
    }
    if (key == '2') {
      int target = civWin.parseFreq(freqs.getString("F1_long"));
      civWin.sendSetFrequency("Keyboard F1 Long", target);
    }
    if (key == '3') {
      int target = civWin.parseFreq(freqs.getString("F2_short"));
      civWin.sendSetFrequency("Keyboard F2 Short", target);
    }
    if (key == '4') {
      int target = civWin.parseFreq(freqs.getString("F2_long"));
      civWin.sendSetFrequency("Keyboard F2 Long", target);
    }
  }
}

void exit() {
  if (rc28Comm != null && rc28Comm.rc28 != null) {
    rc28Comm.rc28.close();
  }
  super.exit();
}
