# Changelog

## Unveröffentlicht (1.0, Build 1)

### Geändert
- Nur noch ein Target „ScreenDim“, verteilt per Developer ID und Notarisierung statt
  über den Mac App Store, ohne Sandbox, Open Source. DDC/CI über `IOAVService` ist wieder
  drin: Externe Monitore regelt die App an ihrer Hintergrundbeleuchtung, sobald ein
  DDC-Kanal gefunden wird; Gamma und Overlay dimmen nur als Rückfall oder auf Wunsch.
  Der Picker je Monitor (Einstellungen → Allgemein) bietet „DDC/CI“, „Gamma“ und
  „Overlay“; Gamma oder Overlay statt DDC/CI heißt kein I2C-Verkehr zu diesem Monitor
  (ersetzt den früheren globalen Schalter). Kommt DDC nicht durch, steht der Grund unter
  dem Monitor, mit „Erneut prüfen“. Das Fenster „Diagnose …“ (Kanal, Link, letzte
  I2C-Ergebnisse, Test-Read und -Write) ist zurück.
- Entfernt bleiben die Steuerung des eingebauten Displays über `DisplayServices` und
  der eingebaute Lichtsensor; ihr Code steht in der Git-Historie. `check-mas-binary.sh`
  und die App-Review-Notizen sind weg.

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
- Einstellungsfenster (Abschnitt „Sensor“).
- Das eingebaute Display lässt sich per Software dimmen (Gamma oder
  Overlay, gemerkt pro Display). Allgemein: Displays ohne Steuerkanal dimmt die Software.
- Lichtquelle: Schreibtisch-Sensor oder aus (Wahl in den Einstellungen, sobald der Sensor
  verbunden ist). Fällt der Sensor aus (getrennt, 45 s ohne Ereignis), stoppt die
  Lichtregelung. Ersetzt den Schalter „Helligkeit ans Umgebungslicht anpassen“.
- Fenster „Sensor-Diagnose“ (Einstellungen → „Sensor-Diagnose …“): aktuelle Messung von
  Schreibtisch-Sensor bzw. Demo, welche Quelle gerade Anwesenheit und Licht liefert,
  zuletzt gesetzte Helligkeit und ein Protokoll der Ereignisse und Quellwechsel mit ihrer
  Wirkung.
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
- Overlay-Dimmung als zweiter Weg neben Gamma: randloses Fenster über Menüleiste, allen
  Spaces und Vollbild-Apps. Greift automatisch, wenn die Gamma-Tabelle eines Displays
  nicht nutzbar ist; Umschalter „Gamma/Overlay“ pro Monitor, gemerkt pro Monitor.
- Privacy-Manifest (UserDefaults CA92.1, kein Tracking, keine erhobenen Daten),
  Asset-Katalog mit leerem AppIcon-Slot, String-Katalog Deutsch/Englisch.
- Logik als lokales Swift-Paket `ScreenDimKit`; Tests per `swift test`.

### Behoben
- DDC/CI: Auf Apple Silicon kommt der erste I2C-Write nach einem
  Read beim Monitor nicht an (gemessen: W-R-W-R bleibt Null-Message, W-W-R antwortet;
  ein einzelner Set-VCP nach einem Read ging verloren). Jetzt geht nach jedem Read ein
  Vorlauf-Write voraus (`DDCTiming.primeAfterRead`, Abstand 10 ms).
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
  Reset der Hysterese. Jetzt echte Startwerte, Überblendung auf allen automatischen
  Wegen und Quellwahl nach Ereignissen.

## 1.0 (Entwicklung)
- DDC/CI-Helligkeit für externe Monitore, eingebautes Display, Master-Slider,
  Tastenkürzel, Start bei Login.
- DDC-Diagnose und Software-Dimmung (Gamma) für Monitore am Dock.
