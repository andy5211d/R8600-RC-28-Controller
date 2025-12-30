// CIVComms.pde
// IC-R8600 EU firmware comms with knob modes, auto-step detection, and Mode display
// Unified frequency: sketch always mirrors radio
// Sketch Step vs Radio Step displayed side-by-side
// KnobMode (from A_KnobMode.pde): FREQ (default), STEP, RXMODE
// TX short: FREQ→STEP, STEP/RXMODE→FREQ
// TX long:  FREQ→RXMODE, STEP/RXMODE→FREQ
// Knob sensitivity: knobDivider = 3 (only every 3rd tick acts)

import processing.serial.*;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.LinkedList;
import java.util.HashMap;

class CIVComms {
  final PApplet app;
  Serial port;
  LinkedList<Byte> rxBuffer = new LinkedList<Byte>();
  CopyOnWriteArrayList<String> logs;

  // CI-V addresses
  final int DEST = 0x96; // radio
  final int SRC  = 0xE0; // PC

  // Unified frequency model:
  // currentFreqHz is always "the one true frequency", matching the radio.
  int currentFreqHz = 0;
  int lastBroadcastFreqHz = -1;   // used only for auto-step detection

  // Sketch Step index (user-controlled, into activeStepTable)
  int stepIndex = 2;   // start at 100 Hz

  // Radio's actual step in Hz (from CI-V and auto-step)
  int radioStepHz = -1;

  boolean userActionPending = false;

  String currentMode = "Unknown";
  String currentFilter = "";

  // Exact digits used for display (from radio RX or from TX BCD)
  String rawFreqString = "";

  // Global European step sequence (Hz values)
  int[] stepHzEU = {
    1, 10, 100, 1000, 5000, 6250, 8330, 9000,
    10000, 12500, 20000, 25000, 30000,
    50000, 100000, 200000, 500000
  };

  // Active step table (for future mode-dependent behaviour; currently same as stepHzEU)
  int[] activeStepTable = stepHzEU;

  // Placeholder for future mode→step mapping (not yet populated)
  HashMap<String, int[]> modeStepMap = new HashMap<String, int[]>();

  // Knob mode: which window the knob controls (enum is defined in A_KnobMode.pde)
  KnobMode knobMode = KnobMode.FREQ;

  // RX mode cycling table
  String[] rxModeNames = { "FM", "AM", "USB", "LSB", "WFM", "CW", "DV" };
  int[]    rxModeBytes = { 0x05, 0x02, 0x01, 0x00, 0x06, 0x03, 0x07 };
  int currentModeIndex = -1; // index into rxModeNames / rxModeBytes (if known)

  // Knob sensitivity: only every Nth tick acts
  int knobDivider = 3;  // you chose B → one-third sensitivity
  int knobCount   = 0;

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
      initialiseFromRadio(); // query radio state at startup
    } catch (Exception e) {
      log("[CIV] Error opening port: " + e.getMessage());
    }
  }

  // Query radio state on startup
  void initialiseFromRadio() {
    sendQueryFrequency("Startup Frequency");
    sendQueryStep("Startup Step");
    sendQueryMode("Startup Mode");
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

  // Section 2
  // --- CI-V frame handler ---
  void handleFrame(byte[] frame) {
    if (frame == null || frame.length < 5) return;
    int cmd  = frame[4] & 0xFF;
    String hexStr = toHex(frame);
    String breakdown = "RX: " + hexStr + " | Cmd=" + String.format("%02X", cmd);

    // -------------------------------
    // FREQUENCY RESPONSE / BROADCAST
    // -------------------------------
    if ((cmd == 0x03 || cmd == 0x00) && frame.length >= 10) {

      // Extract BCD bytes (5..end-2)
      byte[] freqBytes = java.util.Arrays.copyOfRange(frame, 5, frame.length - 1);

      // Decode raw digits exactly as radio sends them
      rawFreqString = decodeCIVFrequencyString(freqBytes);

      // Convert to integer Hz
      int newFreq = 0;
      try { newFreq = Integer.parseInt(rawFreqString); } catch (Exception ignore) {}

      // ---------------------------------------------------------
      // AUTO‑STEP DETECTION (restored original behaviour)
      // Always run auto‑step on every broadcast, just like before
      // ---------------------------------------------------------
      if (lastBroadcastFreqHz > 0) {
        int diff = Math.abs(newFreq - lastBroadcastFreqHz);

        int bestIndex = findBestStepIndex(diff);
        if (bestIndex >= 0) {
          radioStepHz = stepHzEU[bestIndex];
          log("[AutoStep] Broadcast diff=" + diff + " Hz → radio step ≈ " + radioStepHz + " Hz");
        } else {
          log("[AutoStep] Broadcast diff=" + diff + " Hz not within tolerance");
        }
      }

      // Unified frequency: sketch always mirrors radio
      currentFreqHz = newFreq;
      lastBroadcastFreqHz = newFreq;

      log("RX Freq=" + rawFreqString + " (raw digits)");
      userActionPending = false;
      return;
    }

    // -------------------------------
    // MODE + FILTER
    // -------------------------------
    if ((cmd == 0x01 || cmd == 0x04) && frame.length >= 7) {
      int modeByte = frame[5] & 0xFF;
      currentMode = decodePrimaryModeEU(modeByte);
      currentModeIndex = modeByteToIndex(modeByte);

      if (frame.length >= 8 && (frame[6] & 0xFF) != 0xFD) {
        int filterByte = frame[6] & 0xFF;
        currentFilter = decodeCIVFilterEU(filterByte);
      }

      updateActiveStepTableForMode();

      breakdown += " | Mode=" + currentMode;
      if (!currentFilter.isEmpty()) breakdown += " (" + currentFilter + ")";
      log(breakdown);
      return;
    }

    // -------------------------------
    // RADIO STEP (read‑only)
    // R8600 does NOT broadcast step changes directly.
    // We keep this handler for completeness.
    // -------------------------------
    if (cmd == 0x05 && frame.length >= 6) {

      // Step code is ALWAYS the last byte before FD
      int stepCode = frame[frame.length - 2] & 0xFF;

      radioStepHz = stepCodeToHz(stepCode);

      breakdown += " | Step=" + decodeStepEU(stepCode);
      log(breakdown);
      return;
    }

    // Unknown / unhandled
    log(breakdown);
  }

  // --- Logging helper ---
  void log(String s) {
    if (logs != null) logs.add(s);
    app.println(s);
  }

  // --- Hex formatting ---
  String toHex(byte[] frame) {
    StringBuilder hex = new StringBuilder();
    for (byte b : frame) hex.append(String.format("%02X ", b & 0xFF));
    return hex.toString().trim();
  }

  // --- Decode CI-V BCD frequency into raw digit string ---
  String decodeCIVFrequencyString(byte[] freqBytes) {
    StringBuilder digits = new StringBuilder();
    for (int i = freqBytes.length - 1; i >= 0; i--) {
      int b = freqBytes[i] & 0xFF;
      digits.append((b >> 4) & 0x0F);
      digits.append(b & 0x0F);
    }
    while (digits.length() > 1 && digits.charAt(0) == '0')
      digits.deleteCharAt(0);
    return digits.toString();
  }

  // --- Encode frequency to BCD ---
  byte[] encodeFrequencyBCD(int freqHz) {
    String s = String.format("%010d", freqHz);
    byte[] bcd = new byte[5];
    for (int i = 0; i < 5; i++) {
      int hi = s.charAt(i * 2)   - '0';
      int lo = s.charAt(i * 2 + 1) - '0';
      bcd[4 - i] = (byte)((hi << 4) | lo);
    }
    return bcd;
  }

  // --- Send CI-V frame ---
  void sendFrame(String label, byte[] frame) {
    if (port != null) {
      port.write(frame);
      log("TX (" + label + "): " + toHex(frame));
    }
  }

  // --- Send Set Frequency ---
  void sendSetFrequency(String label, int freqHz) {
    byte[] bcd = encodeFrequencyBCD(freqHz);

    // Keep display in sync
    rawFreqString = decodeCIVFrequencyString(bcd);

    byte[] frame = new byte[5 + bcd.length + 1];
    frame[0] = (byte)0xFE;
    frame[1] = (byte)0xFE;
    frame[2] = (byte)DEST;
    frame[3] = (byte)SRC;
    frame[4] = (byte)0x00; // set frequency
    System.arraycopy(bcd, 0, frame, 5, bcd.length);
    frame[frame.length - 1] = (byte)0xFD;

    sendFrame(label, frame);

    currentFreqHz = freqHz;
  }

  // --- Send Set Mode ---
  void sendSetMode(String label, int modeByte) {
    byte[] frame = new byte[7];
    frame[0] = (byte)0xFE;
    frame[1] = (byte)0xFE;
    frame[2] = (byte)DEST;
    frame[3] = (byte)SRC;
    frame[4] = (byte)0x06;
    frame[5] = (byte)modeByte;
    frame[6] = (byte)0xFD;
    sendFrame(label, frame);
  }

  // --- Query helpers ---
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

  // --- Decode mode ---
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

  // --- Decode filter ---
  String decodeCIVFilterEU(int filterByte) {
    switch (filterByte) {
      case 0x00: return "Wide";
      case 0x01: return "Narrow";
      case 0x02: return "Mid";
      case 0x03: return "Auto";
      default:   return "Unknown(" + String.format("%02X", filterByte) + ")";
    }
  }

  // --- Decode step ---
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

  // --- Mode-specific step table (future) ---
  void updateActiveStepTableForMode() {
    int[] table = modeStepMap.get(currentMode);
    if (table == null || table.length == 0) {
      activeStepTable = stepHzEU;
      return;
    }

    int currentStepHz = activeStepTable[stepIndex];
    int bestIndex = 0;
    int bestError = Integer.MAX_VALUE;

    for (int i = 0; i < table.length; i++) {
      int err = Math.abs(table[i] - currentStepHz);
      if (err < bestError) {
        bestError = err;
        bestIndex = i;
      }
    }

    activeStepTable = table;
    stepIndex = bestIndex;
    log("[ModeStep] Mode=" + currentMode + " → active step table updated");
  }

  // --- Convert step code to Hz ---
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

  // --- Auto-step detection (radio-only) ---
  int findBestStepIndex(int diff) {
    if (diff <= 0) return -1;

    int bestIndex = -1;
    int bestError = Integer.MAX_VALUE;

    for (int i = 0; i < stepHzEU.length; i++) {
      int err = Math.abs(stepHzEU[i] - diff);
      if (err < bestError) {
        bestError = err;
        bestIndex = i;
      }
    }

    if (bestIndex < 0) return -1;

    int bestStep = stepHzEU[bestIndex];
    int err = Math.abs(bestStep - diff);

    if (bestStep > 0 && err * 10 <= bestStep)
      return bestIndex;

    return -1;
  }


  // Section 3
  // ---------------------------------------------------------
  // TX short/long press → knobMode state machine
  // ---------------------------------------------------------
  void handleTXShortPress() {
    if (knobMode != KnobMode.FREQ) {
      knobMode = KnobMode.FREQ;
      log("[KnobMode] Short TX → return to Frequency Mode");
    } else {
      knobMode = KnobMode.STEP;
      log("[KnobMode] Short TX → Step Adjust Mode (knob controls Sketch Step)");
    }
  }

  void handleTXLongPress() {
    if (knobMode != KnobMode.FREQ) {
      knobMode = KnobMode.FREQ;
      log("[KnobMode] Long TX → return to Frequency Mode");
    } else {
      knobMode = KnobMode.RXMODE;
      log("[KnobMode] Long TX → RX Mode Adjust Mode (knob controls RX Mode)");
    }
  }

  // ---------------------------------------------------------
  // RC-28 knob handling with sensitivity divider
  // ---------------------------------------------------------
  void handleKnobCW() {
    knobCount++;
    if (knobCount % knobDivider != 0) return;  // sensitivity control

    userActionPending = true;

    switch (knobMode) {
      case FREQ:
        currentFreqHz += activeStepTable[stepIndex];
        sendSetFrequency("Knob CW", currentFreqHz);
        break;

      case STEP:
        stepIndex = (stepIndex + 1) % activeStepTable.length;
        log("[StepAdjust] Step now " + activeStepTable[stepIndex] + " Hz");
        break;

      case RXMODE:
        cycleModeForward();
        break;
    }
  }

  void handleKnobCCW() {
    knobCount++;
    if (knobCount % knobDivider != 0) return;  // sensitivity control

    userActionPending = true;

    switch (knobMode) {
      case FREQ:
        currentFreqHz = max(0, currentFreqHz - activeStepTable[stepIndex]);
        sendSetFrequency("Knob CCW", currentFreqHz);
        break;

      case STEP:
        stepIndex = (stepIndex - 1 + activeStepTable.length) % activeStepTable.length;
        log("[StepAdjust] Step now " + activeStepTable[stepIndex] + " Hz");
        break;

      case RXMODE:
        cycleModeBackward();
        break;
    }
  }

  // ---------------------------------------------------------
  // RX Mode cycling
  // ---------------------------------------------------------
  int modeByteToIndex(int modeByte) {
    for (int i = 0; i < rxModeBytes.length; i++) {
      if (rxModeBytes[i] == modeByte) return i;
    }
    return -1;
  }

  void cycleModeForward() {
    if (rxModeNames.length == 0) return;
    if (currentModeIndex < 0) currentModeIndex = 0;

    currentModeIndex = (currentModeIndex + 1) % rxModeNames.length;

    int modeByte = rxModeBytes[currentModeIndex];
    currentMode = rxModeNames[currentModeIndex];

    sendSetMode("Knob RXMODE CW", modeByte);
    log("[RXMode] Now " + currentMode);
  }

  void cycleModeBackward() {
    if (rxModeNames.length == 0) return;
    if (currentModeIndex < 0) currentModeIndex = 0;

    currentModeIndex = (currentModeIndex - 1 + rxModeNames.length) % rxModeNames.length;

    int modeByte = rxModeBytes[currentModeIndex];
    currentMode = rxModeNames[currentModeIndex];

    sendSetMode("Knob RXMODE CCW", modeByte);
    log("[RXMode] Now " + currentMode);
  }

  // ---------------------------------------------------------
  // F1 / F2 preset handling
  // ---------------------------------------------------------
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

  // ---------------------------------------------------------
  // Frequency string → Hz (integer, no floats)
  // ---------------------------------------------------------
  int parseFreq(String s) {
    if (s == null) {
      log("[CIV] Invalid frequency string: null");
      return currentFreqHz;
    }

    s = s.trim();
    if (s.isEmpty()) {
      log("[CIV] Invalid frequency string: empty");
      return currentFreqHz;
    }

    int mhzPart = 0;
    int fracPart = 0;
    int fracDigits = 0;

    int dotIndex = s.indexOf('.');
    try {
      if (dotIndex < 0) {
        mhzPart = Integer.parseInt(s);
      } else {
        String left = s.substring(0, dotIndex);
        String right = s.substring(dotIndex + 1);

        if (!left.isEmpty()) mhzPart = Integer.parseInt(left);

        right = right.replaceAll("[^0-9]", "");
        if (!right.isEmpty()) {
          if (right.length() > 6) right = right.substring(0, 6);
          fracDigits = right.length();
          fracPart = Integer.parseInt(right);
        }
      }
    } catch (Exception e) {
      log("[CIV] Invalid frequency string: " + s);
      return currentFreqHz;
    }

    int hz = mhzPart * 1_000_000;
    if (fracDigits > 0) {
      int scale = 1;
      for (int i = 0; i < (6 - fracDigits); i++) scale *= 10;
      hz += fracPart * scale;
    }

    return hz;
  }

  // Section 4
  // ---------------------------------------------------------
  // UI drawing
  // ---------------------------------------------------------
  void drawUI() {
    app.background(0); // black background

    boolean freqActive = (knobMode == KnobMode.FREQ);
    boolean stepActive = (knobMode == KnobMode.STEP);
    boolean modeActive = (knobMode == KnobMode.RXMODE);

    // ---------------------------------------------------------
    // FREQUENCY BOX
    // ---------------------------------------------------------
    app.fill(freqActive ? app.color(40, 60, 120) : 30);
    app.stroke(freqActive ? app.color(0, 200, 255) : 200);
    app.rect(50, 50, 300, 80);

    app.fill(255);
    app.textAlign(PApplet.CENTER, PApplet.CENTER);
    app.textSize(24);
    app.text("Frequency", 200, 70);

    String freqDisplay = formatFrequencyFromRadio(rawFreqString);
    app.textSize(32);
    app.text(freqDisplay, 200, 110);

    // ---------------------------------------------------------
    // STEP PANEL (Sketch + Radio)
    // Only the Sketch box highlights in STEP mode
    // ---------------------------------------------------------

    // Sketch Step box (left)
    app.fill(stepActive ? app.color(40, 60, 120) : 30);
    app.stroke(stepActive ? app.color(0, 200, 255) : 200);
    app.rect(50, 150, 140, 80);

    app.fill(255);
    app.textSize(20);
    app.text("Sketch", 120, 170);
    app.textSize(28);
    app.text(activeStepTable[stepIndex] + " Hz", 120, 205);

    // Radio Step box (right) — NEVER highlighted
    app.fill(30);
    app.stroke(200);
    app.rect(210, 150, 140, 80);

    app.fill(255);
    app.textSize(20);
    app.text("Radio", 280, 170);
    app.textSize(28);
    String radioStepDisplay = (radioStepHz > 0 ? (radioStepHz + " Hz") : "Unknown");
    app.text(radioStepDisplay, 280, 205);

    // ---------------------------------------------------------
    // MODE BOX
    // ---------------------------------------------------------
    app.fill(modeActive ? app.color(40, 60, 120) : 30);
    app.stroke(modeActive ? app.color(0, 200, 255) : 200);
    app.rect(50, 250, 300, 80);

    app.fill(255);
    app.textSize(24);
    app.text("Mode", 200, 270);

    String modeDisplay = currentMode;
    if (!currentFilter.isEmpty()) modeDisplay += " / " + currentFilter;

    app.textSize(28);
    app.text(modeDisplay, 200, 300);
  }

  // ---------------------------------------------------------
  // Frequency formatting (raw digits → MHz/kHz/Hz)
  // ---------------------------------------------------------
  String formatFrequencyFromRadio(String s) {
    if (s == null || s.isEmpty()) return "";

    int len = s.length();

    if (len > 6) {
      return s.substring(0, len - 6) + "." + s.substring(len - 6) + " MHz";
    } else if (len > 3) {
      return s.substring(0, len - 3) + "." + s.substring(len - 3) + " kHz";
    } else {
      return s + " Hz";
    }
  }
}
