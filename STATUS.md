# Status

Stand: 2026-10-29. Beide Targets bauen ohne Warnungen, 111 Tests grün,
`check-mas-binary.sh` auf das App-Store-Binary: OK (Debug).

## Offene Hardware-Tests

Auf echter Hardware noch nicht geprüft. Die Tests decken nur die Logik ab.

### Mac Studio + JapanNext 6K (USB-C/Thunderbolt)
- [ ] **Direct:** Diagnose-Fenster öffnen, „Test: Read 0x10“ und „Test: Write 0x10 =
      aktueller Wert“. Erwartet: Read liefert Wert/Maximum, Write ändert die
      Hintergrundbeleuchtung, Zustand „Bereit“.
- [ ] **Direct:** Slider zügig ziehen: kein Hänger, Monitor folgt dem letzten Wert.
- [ ] **App Store:** Gamma-Dimmung bei 100 %, 50 %, 0 % (Untergrenze 10 %), Farben
      bleiben kalibriert.
- [ ] **App Store:** Umschalter auf Overlay: deckt Menüleiste, alle Spaces und
      Vollbild-Apps ab, Mausklicks gehen durch, kein Fokuswechsel.
- [ ] **App Store:** Sandbox. Prüfen, ob Gamma-Tabelle, Tastenkürzel und Login-Item
      in der signierten Sandbox-App funktionieren.

### Dock-Betrieb (StarTech TB4, Realtek-MST)
- [ ] Direct: Monitore am Dock fallen ohne Hänger auf Software-Dimmung zurück; Hinweis
      „DDC kommt über das Dock nicht durch“.
- [ ] Gespeicherte Werte: Wechsel direkt ↔ Dock ohne doppelte Abdunklung.

### Aufwachen
- [ ] Nach dem Ruhezustand: Software-Dimmung wieder aktiv (Gamma und Overlay), DDC-Werte
      wiederhergestellt, kein dauerhaftes Flackern.

### Hotplug und Umkonfiguration
- [ ] Monitor ab- und wieder anstecken: Kanal und Werte kommen zurück.
- [ ] Auflösungswechsel: keine Kurven-Rücksetzung auf anderen Displays, Overlay passt
      seine Größe an.

### Schreibtisch-Sensor (ESP32)
- [ ] Bonjour-Suche zeigt den Sensor (Hostname, Firmware); macOS fragt einmal nach dem
      lokalen Netzwerk (MAS und Direct).
- [ ] Kopplung im Kopplungsfenster automatisch; danach 401 → BOOT kurz drücken → Code kommt;
      manuelle Eingabe; neuer Code (BOOT 10 s) → „Kopplung verloren – neu koppeln“.
- [ ] SSE: IDs im echten Strom prüfen (`binary_sensor-presence` bzw. `binary_sensor/Presence`),
      Ping-Abstand (Annahme ≤ 10 s; Bildschirme gehen nach 30 s Stille wieder an).
- [ ] Abwesenheit: Bildschirme schwarz, Mausbewegung weckt; Sensor ausstecken → wieder an.
- [ ] Lux → Helligkeit: Kurve 10 lx → 20 %, 1000 lx → 100 % am Schreibtisch prüfen.
- [ ] Demo-Modus: Banner, Menüeintrag, Symbol; nach Neustart aus.

### Eingebauter Lichtsensor (nur Direct, Prototyp)
Machbarkeit und Messungen: `docs/EingebauterLichtsensor.md`.
- [ ] MacBook: Lichtquelle „Nur eingebauter Lichtsensor“; Lux bei Tageslicht und Lampe,
      externe Monitore folgen, eingebautes Display bleibt bei macOS. Faktor/Kurve kalibrieren.
- [ ] MacBook mit ESP32, „Schreibtisch-Sensor, sonst eingebauter“: ESP32 trennen → „Aktiv:
      Eingebauter Lichtsensor“ mit Grund; wieder verbinden → nach ≥ 5 s zurück.
- [ ] Deckel zu (Clamshell): „Deckel zu“, ESP32 springt ein bzw. Monitore bleiben;
      aufklappen → wieder Werte.
- [ ] ESP32 bei ruhigem Licht: kommt Lux mindestens alle 10 s? Sonst springt der
      eingebaute Sensor ungewollt ein.
- [ ] Mac Studio: nur „Schreibtisch-Sensor“ und „Aus“.

## Offene Punkte für die Einreichung

- [ ] **Sensor-Links:** `SensorLinks.flashPage` ist ein Platzhalter
      (`screendim.example.com`); Videolink in `docs/AppReviewNotes.md` fehlt.

- [ ] **App-Icon:** Slot `AppIcon` in `ScreenDim/Resources/Assets.xcassets` ist leer
      (Icon kommt von Andreas).
- [ ] **Team-ID und Signatur:** `DEVELOPMENT_TEAM` ist leer, Signatur ad hoc. App Store:
      Apple Distribution + Provisioning-Profil. Direct: Developer ID + Notarisierung.
- [ ] **Englische Texte** gegenlesen (`Localizable.xcstrings`).
- [x] **Eingebautes Display in der App-Store-Variante:** per Software (Gamma/Overlay)
      regelbar; die Hintergrundbeleuchtung bleibt bei den Helligkeitstasten.
- [ ] **App Store:** Gamma-Dimmung des eingebauten Displays mit True Tone und Night Shift
      auf echter Hardware prüfen.
- [ ] Alte Test-Plists `ScreenDimTests.*.plist` in `~/Library/Preferences` (37 Stück, aus
      Testläufen vor dem Umbau) können gelöscht werden; neue entstehen nicht mehr.
