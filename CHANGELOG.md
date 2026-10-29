# Changelog

## Unveröffentlicht (1.0, Build 1)

### Neu
- Optionaler Schreibtisch-Sensor (ESP32/ESPHome, DIY): Suche per Bonjour
  (`_screendim._tcp`), Kopplung mit Code (automatisch im Kopplungsfenster, sonst BOOT-Taste
  oder Eingabe), Digest-Login, SSE-Strom mit Neuverbindung (1 s → 30 s). Abwesenheit
  schaltet die Bildschirme schwarz (nur bei verbundenem Sensor und frischem Ereignis;
  Eingaben wecken sofort), Umgebungslicht regelt die Helligkeit. Code im Schlüsselbund,
  Hostname in UserDefaults. Standard: aus.
- Demo-Modus mit simuliertem Sensor für Nutzer ohne Hardware und für App Review; Banner,
  Menüeintrag und eigenes Menüleisten-Symbol, nach dem Start immer aus (außer
  `-ScreenDimDemo YES`).
- Einstellungsfenster (Abschnitt „Sensor“), App-Review-Notizen in `docs/AppReviewNotes.md`.
- App-Store-Variante: Das eingebaute Display lässt sich per Software dimmen (Gamma oder
  Overlay, gemerkt pro Display). Allgemein: Displays ohne Steuerkanal dimmt die Software.
- Zwei Varianten aus einer Codebasis: „ScreenDim“ für den Mac App Store (Sandbox, ohne
  private API, Software-Dimmung) und „ScreenDim Direct“ (Developer ID, DDC/CI).
- Overlay-Dimmung als zweiter Weg neben Gamma: randloses Fenster über Menüleiste, allen
  Spaces und Vollbild-Apps. Greift automatisch, wenn die Gamma-Tabelle eines Displays
  nicht nutzbar ist; Umschalter „Gamma/Overlay“ pro Monitor, gemerkt pro Monitor.
- `scripts/check-mas-binary.sh` prüft ein gebautes App-Store-Binary auf private API.
- Privacy-Manifest (UserDefaults CA92.1, kein Tracking, keine erhobenen Daten),
  Asset-Katalog mit leerem AppIcon-Slot, String-Katalog Deutsch/Englisch.
- Logik als lokales Swift-Paket `ScreenDimKit`; Tests per `swift test`.

### Behoben
- DDCService: Zulassung und Eintrag eines Aufrufs liefen in zwei getrennten Locks;
  gleichzeitige Aufrufe konnten `maxPendingCalls` überschreiten.
- DDCService: Feuerte der Deadline-Timer eines wartenden Aufrufs vor dem des hängenden,
  bekam der wartende `.timeout` statt `.hung`. Die Erkennung hängt nicht mehr von der
  Reihenfolge der Timer ab.
- Jeder Umkonfigurations-Callback setzte per ColorSync die Gamma-Tabellen aller Displays
  zurück (Flackern, betraf auch andere Apps). Jetzt nur bei geänderter Display-Menge
  oder nach dem Aufwachen; bei Auflösungswechseln wird nur das betroffene Display neu
  geschrieben.
- Tests hinterlassen keine UserDefaults-Plists mehr in `~/Library/Preferences`: Sie
  speichern im RAM (`removePersistentDomain` allein reicht nicht, `cfprefsd` legt die
  leere Plist danach an).
- DDC- und Gamma-Helligkeit werden getrennt gespeichert: Am Dock wurde ein per DDC
  gesetzter Wert zusätzlich als Gamma angewandt (doppelte Abdunklung).
- Registry-Root nach der Monitorsuche freigegeben.

## 1.0 (Entwicklung)
- DDC/CI-Helligkeit für externe Monitore, eingebautes Display, Master-Slider,
  Tastenkürzel, Start bei Login.
- DDC-Diagnose und Software-Dimmung (Gamma) für Monitore am Dock.
