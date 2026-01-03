// RC28Comm.pde
// Encapsulates HID communication and decoding for Icom RC-28 Remote Encoder
// Uses reflection for open(), isOpen(), read() to avoid PDE parser issues
// Extended constructor: logs, civ, freqs, hidDeviceName, config
// This code does not have control of the Encoder LEDs!
// This works! 

import org.hid4java.*;
import java.util.concurrent.CopyOnWriteArrayList;
import java.lang.reflect.Method;

class RC28Comm {
  // Defaults (overridden by config if provided)
  int VENDOR_ID  = 0x0C26;
  int PRODUCT_ID = 0x001E;

  HidServices hidServices;
  HidDevice rc28;
  CopyOnWriteArrayList<String> logs;
  RC28Decoder decoder;

  JSONObject freqs;
  JSONObject config;
  String hidDeviceName;

  RC28Comm(CopyOnWriteArrayList<String> logs, CIVComms civ, JSONObject freqs, String hidDeviceName, JSONObject config) {
    this.logs = logs;
    this.freqs = freqs;
    this.config = config;
    this.hidDeviceName = hidDeviceName != null ? hidDeviceName : "Icom RC-28";

    // Allow config to override VID/PID
    if (config != null) {
      if (config.hasKey("vendorId"))  VENDOR_ID  = parseId(config.getString("vendorId"));
      if (config.hasKey("productId")) PRODUCT_ID = parseId(config.getString("productId"));
    }

    this.decoder = new RC28Decoder(civ, logs, freqs, config);
    setupHID();
  }

  void setupHID() {
    try {
      HidServicesSpecification spec = new HidServicesSpecification();
      spec.setAutoShutdown(true);
      spec.setScanInterval(500);
      spec.setPauseInterval(5000);
      spec.setDataReadInterval(50);

      hidServices = HidManager.getHidServices(spec);

      for (HidDevice d : hidServices.getAttachedHidDevices()) {
        logs.add("Found: VID=" + String.format("%04X", d.getVendorId()) +
                 " PID=" + String.format("%04X", d.getProductId()) +
                 " Product=" + d.getProduct());
        boolean vidpidMatch = (d.getVendorId() == VENDOR_ID && d.getProductId() == PRODUCT_ID);
        boolean nameMatch = (hidDeviceName != null && d.getProduct() != null && d.getProduct().contains(hidDeviceName));
        if (vidpidMatch || nameMatch) {
          rc28 = d;
        }
      }

      if (rc28 != null) {
        try {
          Method m = rc28.getClass().getMethod("open");
          m.invoke(rc28);
          logs.add("[RC-28 open() invoked via reflection]");
        } catch (Throwable t) {
          logs.add("[RC-28 open reflect error: " + t.getClass().getSimpleName() + " - " + t.getMessage() + "]");
        }
      } else {
        logs.add("[RC-28 not found]");
      }

      hidServices.start();
      logs.add("[HID services started]");
    } catch (Throwable t) {
      logs.add("[HID setup error: " + t.getClass().getSimpleName() + " - " + t.getMessage() + "]");
    }
  }

  int parseId(String s) {
    try {
      if (s == null) return -1;
      s = s.trim();
      if (s.startsWith("0x") || s.startsWith("0X")) {
        return Integer.parseInt(s.substring(2), 16);
      } else {
        return Integer.parseInt(s);
      }
    } catch (Exception e) {
      logs.add("[Config parse error for ID: " + s + "]");
      return -1;
    }
  }

  void poll() {
    if (rc28 == null) return;

    boolean isOpen = false;
    try {
      Method isOpenM = rc28.getClass().getMethod("isOpen");
      Object r = isOpenM.invoke(rc28);
      if (r instanceof Boolean) isOpen = ((Boolean) r).booleanValue();
    } catch (Throwable t) {
      // If isOpen() is missing, assume open to avoid blocking reads
      isOpen = true;
    }

    if (!isOpen) return;

    byte[] buffer = new byte[64];
    int len = 0;
    try {
      Method readM = rc28.getClass().getMethod("read", byte[].class, int.class);
      Object r = readM.invoke(rc28, buffer, 100);
      if (r instanceof Integer) len = ((Integer) r).intValue();
    } catch (Throwable t) {
      logs.add("[Read reflect error: " + t.getClass().getSimpleName() + " - " + t.getMessage() + "]");
    }

    if (len > 0) {
      StringBuilder sb = new StringBuilder();
      for (int i = 0; i < len; i++) {
        sb.append(String.format("%02X ", buffer[i]));
      }
      logs.add("[RC28 raw] " + sb.toString().trim());
      decoder.decode(buffer, len);
    }
  }
}

// --- Decoder class ---
class RC28Decoder {
  CIVComms civ;
  CopyOnWriteArrayList<String> logs;
  JSONObject freqs;
  JSONObject config;

  long f1Down = -1;
  long f2Down = -1;
  long txDown = -1;

  int longPressThreshold = 500;
  int maskF1 = 0x02, maskF2 = 0x04, maskTX = 0x01;
  int knobCW = 0x01, knobCCW = 0x02;

  RC28Decoder(CIVComms civ, CopyOnWriteArrayList<String> logs, JSONObject freqs, JSONObject config) {
    this.civ = civ;
    this.logs = logs;
    this.freqs = freqs;
    this.config = config;

    if (config != null) {
      if (config.hasKey("longPressThreshold")) longPressThreshold = config.getInt("longPressThreshold");
      if (config.hasKey("buttons")) {
        JSONObject b = config.getJSONObject("buttons");
        if (b.hasKey("F1")) maskF1 = b.getInt("F1");
        if (b.hasKey("F2")) maskF2 = b.getInt("F2");
        if (b.hasKey("TX")) maskTX = b.getInt("TX");
      }
      if (config.hasKey("knob")) {
        JSONObject k = config.getJSONObject("knob");
        if (k.hasKey("CW"))  knobCW  = k.getInt("CW");
        if (k.hasKey("CCW")) knobCCW = k.getInt("CCW");
      }
    }
  }

  void decode(byte[] buffer, int len) {
    if (len <= 0) return;

    // Adjust offsets if your raw logs show differences
    int dir = buffer[3] & 0xFF;
    if (dir == knobCW) {
      logs.add("[Knob] CW step");
      civ.handleKnobCW();
    } else if (dir == knobCCW) {
      logs.add("[Knob] CCW step");
      civ.handleKnobCCW();
    }

    int buttons = buffer[5] & 0xFF;
    boolean f1Now = (buttons & maskF1) == 0;
    boolean f2Now = (buttons & maskF2) == 0;
    boolean txNow = (buttons & maskTX) == 0;

    handleButton("F1", f1Now);
    handleButton("F2", f2Now);
    handleButton("Tx", txNow);

    // Optional: JSON-driven frequency presets
    // If freqs contains "F1_short"/"F1_long", "F2_short"/"F2_long", you can apply in handleButton via CIVComms
  }

  void handleButton(String name, boolean pressed) {
    long now = millis();

    if ("F1".equals(name)) {
      if (pressed && f1Down == -1) f1Down = now;
      if (!pressed && f1Down != -1) {
        long duration = now - f1Down;
        boolean longPress = duration >= longPressThreshold;
        logs.add("[F1] " + (longPress ? "Long" : "Short") + " press (" + duration + "ms)");
        if (freqs != null) {
          String key = longPress ? "F1_long" : "F1_short";
          if (freqs.hasKey(key)) civ.sendSetFrequency("F1", civ.parseFreq(freqs.getString(key)));
        }
        civ.handleF1(longPress);
        f1Down = -1;
      }
    } else if ("F2".equals(name)) {
      if (pressed && f2Down == -1) f2Down = now;
      if (!pressed && f2Down != -1) {
        long duration = now - f2Down;
        boolean longPress = duration >= longPressThreshold;
        logs.add("[F2] " + (longPress ? "Long" : "Short") + " press (" + duration + "ms)");
        if (freqs != null) {
          String key = longPress ? "F2_long" : "F2_short";
          if (freqs.hasKey(key)) civ.sendSetFrequency("F2", civ.parseFreq(freqs.getString(key)));
        }
        civ.handleF2(longPress);
        f2Down = -1;
      }
    } else if ("Tx".equals(name)) {
      if (pressed && txDown == -1) txDown = now;
      if (!pressed && txDown != -1) {
        long duration = now - txDown;
        logs.add("[Tx] press (" + duration + "ms)");
        civ.handleTX();
        txDown = -1;
      }
    }
  }
}
