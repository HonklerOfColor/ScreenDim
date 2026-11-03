# Status

Stand: 2026-11-03. Ein Target (`ScreenDim`, App Store); die Direct-Variante und der
eingebaute Lichtsensor sind entfernt. Baut ohne Warnungen, Paket-Tests grün,
`check-mas-binary.sh`: OK (Debug).

## Offene Hardware-Tests

Auf echter Hardware noch nicht geprüft. Die Tests decken nur die Logik ab.

### Mac Studio + JapanNext 6K (USB-C/Thunderbolt)
- [ ] Gamma-Dimmung bei 100 %, 50 %, 0 % (Untergrenze 10 %), Farben bleiben kalibriert.
- [ ] Umschalter auf Overlay: deckt Menüleiste, alle Spaces und Vollbild-Apps ab,
      Mausklicks gehen durch, kein Fokuswechsel.
- [ ] Sandbox: Prüfen, ob Gamma-Tabelle, Tastenkürzel und Login-Item in der signierten
      Sandbox-App funktionieren.

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

## Offene Punkte für die Einreichung

- [ ] **Sensor-Links:** `SensorLinks.flashPage` ist ein Platzhalter
      (`screendim.example.com`); Videolink in `docs/AppReviewNotes.md` fehlt.

- [ ] **App-Icon:** Slot `AppIcon` in `ScreenDim/Resources/Assets.xcassets` ist leer
      (Icon kommt von Andreas).
- [ ] **Team-ID und Signatur:** `DEVELOPMENT_TEAM` ist leer, Signatur ad hoc. App Store:
      Apple Distribution + Provisioning-Profil.
- [ ] **Englische Texte** gegenlesen (`Localizable.xcstrings`).
- [x] **Eingebautes Display:** per Software (Gamma/Overlay) regelbar; die
      Hintergrundbeleuchtung bleibt bei den Helligkeitstasten.
- [ ] Gamma-Dimmung des eingebauten Displays mit True Tone und Night Shift auf echter
      Hardware prüfen.
- [ ] **Aufräumen in `ScreenDimKit`:** DDC-Stack und Lichtquelle „eingebaut“ sind ohne
      Direct-Variante toter Code (siehe `CLAUDE.md`).
- [ ] Alte Test-Plists `ScreenDimTests.*.plist` in `~/Library/Preferences` (37 Stück, aus
      Testläufen vor dem Umbau) können gelöscht werden; neue entstehen nicht mehr.
