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
- Lichtquelle mit Vorrang: Schreibtisch-Sensor zuerst (Standard), eingebauter Lichtsensor
  zuerst, nur einer von beiden oder aus. Fällt die bevorzugte Quelle aus (getrennt, 45 s
  ohne Ereignis, Deckel zu), springt die andere ein; zurück frühestens nach 5 s. Der
  eingebaute Sensor ist nur in Direct verfügbar (Prototyp). Einstellungen
  zeigen die aktive Quelle mit Grund; die App-Store-Variante nennt, dass der Lichtsensor
  nur in ScreenDim Direct geht. Ersetzt den Schalter „Helligkeit ans Umgebungslicht
  anpassen“. Details: `docs/EingebauterLichtsensor.md`.
- Fenster „Sensor-Diagnose“ (Einstellungen → „Sensor-Diagnose …“): aktuelle Messung von
  Schreibtisch-Sensor bzw. Demo und eingebautem Lichtsensor, welche Quelle gerade
  Anwesenheit und Licht liefert (und ob als Rückfall), zuletzt gesetzte Helligkeit und ein
  Protokoll der Ereignisse und Quellwechsel mit ihrer Wirkung. Solange es offen ist, liest
  der eingebaute Sensor mit.
- Helligkeit je Monitor nach Licht: eigene Kurve aus bis zu acht Lux-Stützpunkten,
  dazwischen logarithmisch, je Monitor abschaltbar; Diagramm mit aktuellem Licht.
  Das eingebaute Display folgt standardmäßig nicht. Einstellungen in zwei Tabs („Sensor“,
  „Helligkeit“), ohne Scrollen.
- Lichtregelung ohne Sprünge: Alle automatischen Änderungen blenden über (Licht 2 s,
  Prüfung, Software-Rückfall, Aufwachen und Umstecken 0,5 s), vom echten Wert aus.
  Lux des eingebauten Sensors geglättet (`LuxFilter`: Median, EMA im Log-Raum, großer
  Sprung sofort), Hysterese 3 Punkte. Regler und Tastenkürzel wirken sofort und pausieren
  die Lichtregelung dieses Monitors (5 min oder bis das Licht sich verdoppelt bzw.
  halbiert).
- Sensor-Diagnose: je Helligkeitsauftrag ein Eintrag mit Grund, Start (gemerkt/echt), Ziel
  und Dauer; dazu `log.info` in der Kategorie `light`.
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
- Lichtregelung: Kam der erste Lux-Wert, während ein Monitor noch per DDC geprüft wurde,
  übernahm er ihn nicht, die Hysterese hielt ihn aber für gesetzt. Nach der Prüfung blieb
  der Monitor auf seinem gespeicherten Wert, bis sich das Licht um mehr als 5 % änderte.
  Jetzt holt der Monitor den Wert direkt nach der Prüfung nach.
- Helligkeit sprang zeitweise: ScreenDim und die Auto-Helligkeit von macOS regelten das
  eingebaute Display gleichzeitig; Überblendungen begannen beim gemerkten statt beim
  echten Wert; Prüfung, Software-Rückfall und Refresh setzten Werte hart; der
  Schreibtisch-Sensor galt bei ruhigem Licht als ausgefallen, die Quelle wechselte samt
  Reset der Hysterese. Jetzt ein Schreiber (Direct erkennt die Auto-Helligkeit; eine
  fremde Änderung wird übernommen und pausiert die Regelung 60 s), echte Startwerte,
  Überblendung auf allen automatischen Wegen und Quellwahl nach Ereignissen.

## 1.0 (Entwicklung)
- DDC/CI-Helligkeit für externe Monitore, eingebautes Display, Master-Slider,
  Tastenkürzel, Start bei Login.
- DDC-Diagnose und Software-Dimmung (Gamma) für Monitore am Dock.
