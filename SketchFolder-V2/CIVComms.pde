// CIVComms.pde
// IC-R8600 EU firmware comms with hybrid knob logic, auto-step detection, and Mode display
// Updated: F1/F2 pre-determined frequencies and COM port now use JSON presets
// This works

import processing.serial.*;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.LinkedList;

class CIVComms {
  final PApplet app;
  Serial port;
  LinkedList<Byte> rxBuffer = new LinkedList<Byte>();
  CopyOnWriteArrayList<String> logs;

  // CI-V addresses
  final int DEST = 0x96; // radio
  final int SRC  = 0xE0; // PC

  // Local state
  int currentFreqHz = 0;
  int lastBroadcastFreqHz = -1;
  int stepIndex = 2;   // start at 100 Hz
  boolean userActionPending = false;

  String currentMode = "Unknown";
  String currentFilter = "";

  // European step sequence (Hz values)
  int[] stepHzEU = {
    1, 10, 100, 1000, 5000, 6250, 8330, 9000,
    10000, 12500, 20000, 25000, 30000,
    50000, 100000, 200000, 500000
  };

  // Reference to frequency presets
  JSONObject freqs;

  CIVComms(PApplet app, CopyOnWriteArrayList<String> logs, String portName, int baud, JSONObject freqs) {
    this.app = app;
    this.logs = logs;
    this.freqs = freqs;
    try {
      port = new Serial(app, portName, baud);
      port.clear();
      log("[CIV] Opened " + portName + " at " + baud + " baud");
      initialiseFromRadio(); // query frequency at startup
    } catch (Exception e) {
      log("[CIV] Error opening port: " + e.getMessage());
    }
  }

  // Query radio frequency on startup
  void initialiseFromRadio() {
    sendQueryFrequency("Startup Frequency");
  }

  // Manual polling (call from draw())
  void readSerial() {
    if (port == null) return;
    while (port.available() > 0) {
      byte b = (byte)port.read();
      rxBuffer.add(b);
      if ((b & 0xFF) == 0xFD) { // end of frame
        byte[] frame = new byte[rxBuffer.size()];
        for (int i = 0; i < rxBuffer.size(); i++) frame[i] = rxBuffer.get(i);
        handleFrame(frame);
        rxBuffer.clear();
      }
    }
  }

  void handleFrame(byte[] frame) {
    if (frame == null || frame.length < 5) return;
    int cmd  = frame[4] & 0xFF;
    String hexStr = toHex(frame);
    String breakdown = "RX: " + hexStr + " | Cmd=" + String.format("%02X", cmd);

    if ((cmd == 0x03 || cmd == 0x00) && frame.length >= 11) {
      byte[] freqBytes = java.util.Arrays.copyOfRange(frame, 5, frame.length - 1);
      String freqStr = decodeCIVFrequencyString(freqBytes);
      int newFreq = 0;
      try { newFreq = Integer.parseInt(freqStr); } catch (Exception ignore) {}

      // Auto step detection if no RC-28 action
      if (!userActionPending && lastBroadcastFreqHz > 0) {
        int diff = Math.abs(newFreq - lastBroadcastFreqHz);
        int exactIndex = findExactStepIndex(diff);
        if (exactIndex >= 0) {
          stepIndex = exactIndex;
          log("[AutoStep] Broadcast diff=" + diff + " Hz → step=" + stepHzEU[stepIndex] + " Hz");
        } else {
          log("[AutoStep] Broadcast diff=" + diff + " Hz not in step table, ignored");
        }
      }

      currentFreqHz = newFreq;
      lastBroadcastFreqHz = newFreq;
      log("RX Freq=" + currentFreqHz + " Hz");
      userActionPending = false;
      return;
    }

    if ((cmd == 0x01 || cmd == 0x04) && frame.length >= 7) {
      int modeByte = frame[5] & 0xFF;
      currentMode = decodePrimaryModeEU(modeByte);

      if (frame.length >= 8 && (frame[6] & 0xFF) != 0xFD) {
        int filterByte = frame[6] & 0xFF;
        currentFilter = decodeCIVFilterEU(filterByte);
      }

      breakdown += " | Mode=" + currentMode;
      if (!currentFilter.isEmpty()) breakdown += " (" + currentFilter + ")";
      log(breakdown);
      return;
    }

    if (cmd == 0x05 && frame.length >= 6) {
      int stepCode = frame[5] & 0xFF;
      breakdown += " | Step=" + decodeStepEU(stepCode);
      syncStepIndex(stepCode);
      log(breakdown);
      return;
    }

    log(breakdown);
  }

  // --- Helpers ---
  void log(String s) {
    if (logs != null) logs.add(s);
    app.println(s);
  }

  String toHex(byte[] frame) {
    StringBuilder hex = new StringBuilder();
    for (byte b : frame) hex.append(String.format("%02X ", b & 0xFF));
    return hex.toString().trim();
  }

  String decodeCIVFrequencyString(byte[] freqBytes) {
    StringBuilder digits = new StringBuilder();
    for (int i = freqBytes.length - 1; i >= 0; i--) {
      int b = freqBytes[i] & 0xFF;
      digits.append((b >> 4) & 0x0F);
      digits.append(b & 0x0F);
    }
    while (digits.length() > 1 && digits.charAt(0) == '0') digits.deleteCharAt(0);
    return digits.toString();
  }

  byte[] encodeFrequencyBCD(int freqHz) {
    String s = String.format("%010d", freqHz);
    byte[] bcd = new byte[5];
    for (int i=0; i<5; i++) {
      int hi = s.charAt(i*2)-'0';
      int lo = s.charAt(i*2+1)-'0';
      bcd[4-i] = (byte)((hi<<4)|lo);
    }
    return bcd;
  }

  void sendFrame(String label, byte[] frame) {
    if (port != null) {
      port.write(frame);
      log("TX (" + label + "): " + toHex(frame));
    }
  }

  void sendSetFrequency(String label, int freqHz) {
    byte[] bcd = encodeFrequencyBCD(freqHz);
    byte[] frame = new byte[5 + bcd.length + 1];
    frame[0]=(byte)0xFE; frame[1]=(byte)0xFE;
    frame[2]=(byte)DEST; frame[3]=(byte)SRC;
    frame[4]=(byte)0x00; // set frequency
    System.arraycopy(bcd,0,frame,5,bcd.length);
    frame[frame.length-1]=(byte)0xFD;
    sendFrame(label, frame);
  }

  // Query helpers
  void sendQueryFrequency(String label) {
    byte[] frame = { (byte)0xFE,(byte)0xFE,(byte)DEST,(byte)SRC,(byte)0x03,(byte)0xFD };
    sendFrame(label, frame);
  }

  void sendQueryMode(String label) {
    byte[] frame = { (byte)0xFE,(byte)0xFE,(byte)DEST,(byte)SRC,(byte)0x04,(byte)0xFD };
    sendFrame(label, frame);
  }

  void sendQueryStep(String label) {
    byte[] frame = { (byte)0xFE,(byte)0xFE,(byte)DEST,(byte)SRC,(byte)0x05,(byte)0xFD };
    sendFrame(label, frame);
  }

  // --- Decode tables ---
  String decodePrimaryModeEU(int modeByte) {
    switch (modeByte) {
      case 0x00: return "LSB";
      case 0x01: return "USB";
      case 0x02: return "AM";
      case 0x03: return "CW";
      case 0x04: return "RTTY";
      case 0x05: return "FM";
      case 0x06: return "WFM";
      case 0x07: return "DV";
      case 0x0A: return "AM-N";
      case 0x0B: return "FM-N";
      case 0x0C: return "D-STAR Data";
      case 0x0D: return "P25";
      case 0x0E: return "NXDN-N";
      case 0x11: return "S-AM(d)";
      case 0x18: return "dPMR";
      case 0x19: return "NXDN-VN";
      default:   return "Unknown(" + String.format("%02X", modeByte) + ")";
    }
  }

  String decodeCIVFilterEU(int filterByte) {
    switch (filterByte) {
      case 0x00: return "Wide";
      case 0x01: return "Narrow";
      case 0x02: return "Mid";
      case 0x03: return "Auto";
      default:   return "Unknown(" + String.format("%02X", filterByte) + ")";
    }
  }

  String decodeStepEU(int stepCode) {
    switch (stepCode) {
      case 0x00: return "1 Hz";
      case 0x01: return "10 Hz";
      case 0x02: return "100 Hz";
      case 0x03: return "1 kHz";
      case 0x04: return "5 kHz";
      case 0x05: return "6.25 kHz";
      case 0x06: return "8.33 kHz";
      case 0x07: return "9 kHz";
      case 0x08: return "10 kHz";
      case 0x09: return "12.5 kHz";
      case 0x0A: return "20 kHz";
      case 0x0B: return "25 kHz";
      case 0x0C: return "30 kHz";
      case 0x0D: return "50 kHz";
      case 0x0E: return "100 kHz";
      case 0x0F: return "200 kHz";
      case 0x10: return "500 kHz";
      default:   return "Unknown step (" + String.format("%02X", stepCode) + ")";
    }
  }

  void syncStepIndex(int stepCode) {
    int hz = stepCodeToHz(stepCode);
    for (int i = 0; i < stepHzEU.length; i++) {
      if (stepHzEU[i] == hz) { stepIndex = i; return; }
    }
    log("[CIV] Step sync: radio reported code " + String.format("%02X", stepCode));
  }

  int stepCodeToHz(int code) {
    switch (code) {
      case 0x00: return 1;
      case 0x01: return 10;
      case 0x02: return 100;
      case 0x03: return 1000;
      case 0x04: return 5000;
      case 0x05: return 6250;
      case 0x06: return 8330;
      case 0x07: return 9000;
      case 0x08: return 10000;
      case 0x09: return 12500;
      case 0x0A: return 20000;
      case 0x0B: return 25000;
      case 0x0C: return 30000;
      case 0x0D: return 50000;
      case 0x0E: return 100000;
      case 0x0F: return 200000;
      case 0x10: return 500000;
      default:   return -1;
    }
  }

  int findExactStepIndex(int diff) {
    for (int i = 0; i < stepHzEU.length; i++) {
      if (stepHzEU[i] == diff) return i;
    }
    return -1; // no exact match
  }

  // --- RC-28 controls (hybrid knob logic) ---
  void handleTX() {
    userActionPending = true;
    stepIndex = (stepIndex + 1) % stepHzEU.length;
    log("[Step] Now using " + stepHzEU[stepIndex] + " Hz");
  }

  void handleKnobCW() {
    userActionPending = true;
    int stepHz = stepHzEU[stepIndex];
    int target = currentFreqHz + stepHz;
    sendSetFrequency("Knob CW", target);
    currentFreqHz = target; // local update for smooth stepping
  }

  void handleKnobCCW() {
    userActionPending = true;
    int stepHz = stepHzEU[stepIndex];
    int target = Math.max(0, currentFreqHz - stepHz);
    sendSetFrequency("Knob CCW", target);
    currentFreqHz = target; // local update for smooth stepping
  }

  // Updated: use JSON presets instead of hardcoded values
  void handleF1(boolean longPress) {
    userActionPending = true;
    int target = parseFreq(freqs.getString(longPress ? "F1_long" : "F1_short"));
    sendSetFrequency("F1", target);
    currentFreqHz = target;
  }

  void handleF2(boolean longPress) {
    userActionPending = true;
    int target = parseFreq(freqs.getString(longPress ? "F2_long" : "F2_short"));
    sendSetFrequency("F2", target);
    currentFreqHz = target;
  }

  // Helper to parse MHz string into Hz integer
  int parseFreq(String s) {
    try {
      double mhz = Double.parseDouble(s);
      return (int)(mhz * 1_000_000);
    } catch (Exception e) {
      log("[CIV] Invalid frequency string: " + s);
      return currentFreqHz;
    }
  }

  // --- UI drawing ---
  void drawUI() {
    app.background(0); // black background

    // Frequency box
    app.fill(30);
    app.stroke(200);
    app.rect(50, 50, 300, 80);
    app.fill(255);
    app.textAlign(PApplet.CENTER, PApplet.CENTER);
    app.textSize(24);
    app.text("Frequency", 200, 70);

    String freqDisplay = formatFrequency(currentFreqHz);
    app.textSize(32);
    app.text(freqDisplay, 200, 110);

    // Step box
    app.fill(30);
    app.stroke(200);
    app.rect(50, 150, 300, 80);
    app.fill(255);
    app.textSize(24);
    app.text("Step", 200, 170);

    String stepDisplay = stepHzEU[stepIndex] + " Hz";
    app.textSize(32);
    app.text(stepDisplay, 200, 210);

    // Mode box
    app.fill(30);
    app.stroke(200);
    app.rect(50, 250, 300, 80);
    app.fill(255);
    app.textSize(24);
    app.text("Mode", 200, 270);

    String modeDisplay = currentMode;
    if (!currentFilter.isEmpty()) modeDisplay += " / " + currentFilter;
    app.textSize(28);
    app.text(modeDisplay, 200, 300);
  }

  String formatFrequency(int freqHz) {
    if (freqHz >= 1000000) {
      double mhz = freqHz / 1e6;
      return String.format("%.6f MHz", mhz);
    } else {
      double khz = freqHz / 1e3;
      return String.format("%.3f kHz", khz);
    }
  }
}
