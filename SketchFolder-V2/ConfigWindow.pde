// ConfigWindow.pde
// Separate UI window for editing COM port, baud rate, and HID device
// Saves settings to config.json
// Pre-determined frequencies for F1 and F2 in a seperate frequency.json(not handled in this code)
// This works

import processing.core.*;

public class ConfigWindow extends PApplet {
  String comPort = "COM3";
  int baudRate   = 9600;
  String hidDevice = "RC-28";

  public void settings() {
    size(400, 250);
  }

  public void setup() {
    surface.setTitle("Configuration");
    // Try to load existing config.json
    try {
      JSONObject cfg = loadJSONObject("config.json");
      comPort        = cfg.getString("comPort");
      baudRate       = cfg.getInt("baudRate");
      hidDevice      = cfg.getString("hidDevice");
    } catch (Exception e) {
      println("[ConfigWindow] No existing config.json, using defaults");
    }
  }

  public void draw() {
    background(240);
    fill(0);
    textSize(14);
    text("COM Port: "   + comPort, 20, 50);
    text("Baud Rate: "  + baudRate, 20, 80);
    text("HID Device: " + hidDevice, 20, 110);

    text("Press 'p'/'P' to cycle COM ports", 20, 150);
    text("Press '+' or '-' to change baud", 20, 170);
    text("Press 'h'/'H' to edit HID string", 20, 190);
    text("Press 's' to save settings", 20, 210);
  }

  public void keyPressed() {
    if (key == 'p') {
      // Example: cycle through a few common COM ports
      if (comPort.equals("COM3")) comPort = "COM4";
      else if (comPort.equals("COM4")) comPort = "COM5";
      else comPort = "COM3";
    }
    if (key == '+') baudRate += 1200;
    if (key == '-') baudRate = max(1200, baudRate - 1200);
    if (key == 'h' || key == 'H') {
      // For simplicity, toggle between RC-28 and generic string
      if (hidDevice.equals("RC-28")) hidDevice = "Icom RC-28 REMOTE ENCODER";
      else hidDevice = "RC-28";
    }
    if (key == 's') {
      JSONObject cfg = new JSONObject();
      cfg.setString("comPort", comPort);
      cfg.setInt("baudRate", baudRate);
      cfg.setString("hidDevice", hidDevice);
      saveJSONObject(cfg, "config.json");
      
      println("[ConfigWindow] Settings saved to config.json");
    }
  }
}
