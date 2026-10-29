# App Review Notes – ScreenDim

## Deutsch

- ScreenDim braucht keine Hardware. Alle Kernfunktionen laufen ohne Zusatzgerät:
  Helligkeit externer Monitore per Software-Dimmung (Gamma oder Overlay), Regler für
  alle Monitore, Tastenkürzel ⌃⌥↑/↓, Start bei Login.
- Der optionale Schreibtisch-Sensor ist ein Open-Source-Bastelprojekt (ESP32). Wir
  verkaufen keine Hardware; der Sensor ist nicht Teil des Kaufs.
- Testen ohne Hardware: Menüleisten-Symbol → „Einstellungen …“ → Abschnitt „Demo-Modus
  (simulierter Sensor)“ einschalten. Er simuliert Anwesenheit (20 s da, 8 s weg) und
  Umgebungslicht. Ist niemand „da“, werden die Bildschirme schwarz; Maus oder Tastatur
  weckt sie sofort. „Simulieren: weg“ schaltet nach 3 s aus. Solange der Demo-Modus
  läuft, zeigen ein Banner im Einstellungsfenster, ein Eintrag im Menü und ein anderes
  Menüleisten-Symbol „Demo-Modus aktiv“. Nach einem Neustart der App ist er aus.
- Demovideo des echten Sensors: <URL>
- Lokales Netzwerk: nur zum Finden und Verbinden des eigenen Sensors (Bonjour
  `_screendim._tcp`, HTTP im LAN). Ohne eingeschalteten Sensor greift die App nicht aufs
  Netzwerk zu. Keine Daten verlassen das Gerät, keine Telemetrie.

## English

- ScreenDim does not require any hardware. All core features work without an add-on
  device: brightness of external displays via software dimming (gamma or overlay), a
  slider for all displays, keyboard shortcuts ⌃⌥↑/↓, launch at login.
- The optional desk sensor is an open-source DIY project (ESP32). We do not sell
  hardware; the sensor is not part of the purchase.
- Testing without hardware: menu bar icon → “Settings…” → turn on “Demo mode (simulated
  sensor)”. It simulates presence (20 s present, 8 s away) and ambient light. When nobody
  is “present”, the screens go black; mouse or keyboard input wakes them immediately.
  “Simulate: away” turns them off after 3 s. While demo mode is on, a banner in the
  Settings window, an item in the menu and a different menu bar icon show “Demo mode
  active”. It is off again after the app relaunches.
- Demo video of the real sensor: <URL>
- Local network: used only to find and connect to the user's own sensor (Bonjour
  `_screendim._tcp`, HTTP on the LAN). Without the sensor enabled the app does not use
  the network. No data leaves the device, no telemetry.
