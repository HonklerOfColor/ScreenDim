# Status

Stand: 2026-10-29. Beide Targets bauen ohne Warnungen, 69 Tests grün,
`check-mas-binary.sh` auf das App-Store-Binary: OK (Debug und Release).

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

## Offene Punkte für die Einreichung

- [ ] **App-Icon:** Slot `AppIcon` in `ScreenDim/Resources/Assets.xcassets` ist leer
      (Icon kommt von Andreas).
- [ ] **Team-ID und Signatur:** `DEVELOPMENT_TEAM` ist leer, Signatur ad hoc. App Store:
      Apple Distribution + Provisioning-Profil. Direct: Developer ID + Notarisierung.
- [ ] **Englische Texte** gegenlesen (`Localizable.xcstrings`).
- [ ] **Eingebautes Display in der App-Store-Variante:** zurzeit nicht regelbar (Hinweis
      auf die Helligkeitstasten). Software-Dimmung auch dafür wäre möglich, ist aber
      nicht entschieden.
- [ ] Alte Test-Plists `ScreenDimTests.*.plist` in `~/Library/Preferences` (37 Stück, aus
      Testläufen vor dem Umbau) können gelöscht werden; neue entstehen nicht mehr.
