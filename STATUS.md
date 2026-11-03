# Status

Stand: 2026-11-03. Ein Target (`ScreenDim`, Developer ID, ohne Sandbox, Open Source);
DDC/CI über `IOAVService` ist wieder drin und Standard je Monitor, Gamma/Overlay sind
Rückfall oder Wahl. Eingebautes Display per Software; Steuerung über `DisplayServices` und
eingebauter Lichtsensor bleiben entfernt. Baut ohne Warnungen, Paket-Tests grün.

## Offene Hardware-Tests

Auf echter Hardware noch nicht geprüft. Die Tests decken nur die Logik ab.

### Mac Studio + JapanNext 6K (USB-C/Thunderbolt)
- [ ] DDC/CI: Picker zeigt „DDC/CI“ und ist Standard; Regler stellt die
      Hintergrundbeleuchtung; nach „Gamma“ kein I2C-Verkehr mehr (Diagnose), nach „DDC/CI“
      neuer Kanal und gespeicherter Wert.
- [ ] DDC-Rückfall: DDC/CI im Monitor-Menü aus → Hinweis „antwortet leer“, Software dimmt,
      „Erneut prüfen“ holt DDC zurück.
- [ ] Gamma-Dimmung bei 100 %, 50 %, 0 % (Untergrenze 10 %), Farben bleiben kalibriert.
- [ ] Umschalter auf Overlay: deckt Menüleiste, alle Spaces und Vollbild-Apps ab,
      Mausklicks gehen durch, kein Fokuswechsel.
- [ ] Signiert (Developer ID, Hardened Runtime): Gamma-Tabelle, Tastenkürzel, Login-Item
      und `IOAVService` funktionieren.

### Dock-Betrieb (StarTech TB4, Realtek-MST)
- [ ] Gespeicherte Werte: Wechsel direkt ↔ Dock ohne doppelte Abdunklung.

### Aufwachen
- [ ] Nach dem Ruhezustand: Software-Dimmung wieder aktiv (Gamma und Overlay), kein
      dauerhaftes Flackern.

### Hotplug und Umkonfiguration
- [ ] Monitor ab- und wieder anstecken: Kanal und Werte kommen zurück.
- [ ] Auflösungswechsel: keine Kurven-Rücksetzung auf anderen Displays, Overlay passt
      seine Größe an.

### Schreibtisch-Sensor (ESP32)
- [x] Firmware 0.1.0 auf ESP32-S3 (8 MB Flash, 8 MB PSRAM) geflasht: startet, Kopplungscode
      bleibt über Neustarts, ohne Radar „Anwesenheit: ja“, UART still (2026-11-03).
- [ ] WLAN einrichten (Captive Portal oder web.esphome.io), danach `dns-sd -B _screendim._tcp`.
- [ ] RGB-LED: pulsiert sie blau nach kurzem BOOT? Sonst `led_pin` (GPIO38 statt 48).
- [ ] HMMD anschließen (OT2 → GPIO4, TX → GPIO18, RX → GPIO17, 3,3 V): Anwesenheit im
      Log, UART-Rohdaten ansehen und daraus Entfernung und Abfallverzögerung machen.
- [ ] Lichtsensor (`sensor/Ambient Light`) fehlt in der Firmware noch.
- [ ] Bonjour-Suche zeigt den Sensor (Hostname, Firmware); macOS fragt einmal nach dem
      lokalen Netzwerk.
- [ ] Kopplung im Kopplungsfenster automatisch; danach 401 → BOOT kurz drücken → Code kommt;
      manuelle Eingabe; neuer Code (BOOT 10 s) → „Kopplung verloren – neu koppeln“.
- [ ] SSE: IDs im echten Strom prüfen (`binary_sensor-presence` bzw. `binary_sensor/Presence`),
      Ping-Abstand (Annahme ≤ 10 s; Bildschirme gehen nach 30 s Stille wieder an).
- [ ] Abwesenheit: Bildschirme schwarz, Mausbewegung weckt; Sensor ausstecken → wieder an.
- [ ] Lux → Helligkeit: Kurve 10 lx → 20 %, 1000 lx → 100 % am Schreibtisch prüfen.
- [ ] Demo-Modus: Banner, Menüeintrag, Symbol; nach Neustart aus.

- [ ] ESP32 bei ruhigem Licht: Lebenszeichen mindestens alle 45 s? Sonst gilt der Sensor
      als ausgefallen und die Lichtregelung stoppt.

## Offene Punkte für die Veröffentlichung (GitHub, Developer ID)

- [ ] **Lizenz:** `LICENSE` fehlt noch (Wahl offen, z. B. MIT).
- [ ] **Sensor-Links:** `SensorLinks.flashPage` ist ein Platzhalter
      (`screendim.example.com`).

- [ ] **App-Icon:** Slot `AppIcon` in `ScreenDim/Resources/Assets.xcassets` ist leer
      (Icon kommt von Andreas).
- [ ] **Team-ID und Signatur:** `DEVELOPMENT_TEAM` ist leer, Signatur ad hoc. Release:
      Developer ID Application + Notarisierung (`notarytool`), Verteilung als DMG oder ZIP
      über GitHub Releases; Update-Weg (z. B. Sparkle) offen.
- [ ] **Englische Texte** gegenlesen (`Localizable.xcstrings`).
- [x] **Eingebautes Display:** per Software (Gamma/Overlay) regelbar; die
      Hintergrundbeleuchtung bleibt bei den Helligkeitstasten.
- [ ] Gamma-Dimmung des eingebauten Displays mit True Tone und Night Shift auf echter
      Hardware prüfen.
- [ ] **Aufräumen in `ScreenDimKit`:** Lichtquelle „eingebaut“ (`LightSource` mit
      `builtIn…`, `LuxFilter`-Zweig, Fabrik `makeBuiltInLightSensor`) ist ohne Sensor toter
      Code, ebenso `makeBuiltInControl`, solange die App nichts hereinreicht.
- [ ] Alte Test-Plists `ScreenDimTests.*.plist` in `~/Library/Preferences` (37 Stück, aus
      Testläufen vor dem Umbau) können gelöscht werden; neue entstehen nicht mehr.
