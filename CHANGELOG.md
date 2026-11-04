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
- Monitor ignorieren: Der Picker je Monitor (Einstellungen → Allgemein) hat den Punkt
  „Ignorieren“, etwa für einen Beamer. Der Monitor bekommt dann keinen DDC-Kanal (kein
  I2C-Verkehr) und keine Software-Dimmung; Licht, Leerlauf, Abwesenheit, „Alle Monitore“
  und Tastenkürzel lassen ihn aus, Menü und Tab „Licht“ zeigen ihn nicht. Die
  Hintergrundbeleuchtung bleibt, wie sie steht. Gemerkt pro Monitor; gespeicherte Werte
  und Verfahren gelten wieder, sobald er nicht mehr ignoriert wird.
- Weniger Arbeit im Hintergrund: Die IORegistry wird nur noch durchlaufen, wenn sich die
  Display-Menge geändert hat oder neu gesucht wird (vorher bei jeder Umkonfiguration, rund
  13 ms auf dem Hauptthread). Der Wechsel des Verfahrens eines Monitors betrifft nur noch
  diesen Monitor statt alle neu zu prüfen. Das Overlay ändert je Überblendungsschritt nur
  die Deckkraft. Gespeicherte Werte werden nur geschrieben, wenn sie sich ändern. Tab
  „Licht“ und Diagnose-Fenster rendern nicht mehr bei jedem Überblendungsschritt; das Menü
  fragt beim Öffnen nicht mehr den Login-Status ab. Bleibt der Sensor weg, versucht die App
  nach zehn Fehlversuchen nur noch alle zwei Minuten eine Verbindung.
- Abdunkeln bei Inaktivität (Einstellungen → Allgemein, Standard: aus): Nach 1–120 min
  ohne Maus und Tastatur gehen alle Monitore auf höchstens die gewählte Helligkeit
  (0–50 %), auch während ein Video läuft. Jede Eingabe, Regler und Tastenkürzel bringen
  sie sofort zurück. Gedeckelt wird nur die Ausgabe; eingestellte und gespeicherte Werte
  und die Lichtregelung bleiben.
- Screenshots im README (`docs/screenshots/`).
- Sensor-Firmware `Firmware/screendim-desk.yaml` (ESPHome 2026.10, ESP32-S3, Waveshare
  HMMD mmWave): Anwesenheit über OT2 an GPIO4 (ohne Radar „anwesend“), Kopplungscode
  im NVS, BOOT kurz = Kopplungsfenster 2 min, BOOT 10 s = neuer Code, Digest-Login,
  mDNS `_screendim._tcp`, WLAN per Captive Portal oder Improv. UART des Radars wird
  vorerst nur mitgeloggt.
- Lichtsensor in der Firmware: VEML7700 per I2C (SDA GPIO8, SCL GPIO9, Adresse 0x10),
  `sensor/Ambient Light` in Lux, gemeldet bei 3 % Änderung, sonst alle 30 s. Ohne Modul
  läuft der Rest weiter.
- Nachbau des Sensors: Stückliste (ESP32-S3-DevKitC-1 N8R8, Waveshare HMMD mmWave
  Sensor, VEML7700-Modul) und Schaltplan `Firmware/schaltplan.svg` in
  `Firmware/README.md`, Verweis im README.
- Sensor auf dem Seeed Studio XIAO ESP32S3: Schaltplan `Firmware/schaltplan-xiao.svg`
  (Radar an D8–D10 neben 3V3/GND, VEML7700 an D4/D5) und Firmware
  `Firmware/screendim-desk-xiao.yaml`, die `screendim-desk.yaml` einbindet und nur Board,
  Pins und LED ändert (einfarbige Nutzer-LED an GPIO21). Die LED-Anzeigen stehen dafür in
  eigenen Skripten.
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
- Schreibtisch-Sensor: Ein nicht lesbarer Schlüsselbund (gesperrt, Zugriff verweigert)
  galt als „nicht gekoppelt“ und verlangte eine Neukopplung, die den Code überschrieb.
  Jetzt eigener Status „Schlüsselbund nicht lesbar“; Code und Hostname bleiben.
- Kopplung von Hand: Ließ sich der angezeigte Code gerade nicht abrufen, wurde der
  getippte Code ungeprüft gespeichert (im offenen Kopplungsfenster nimmt der Sensor jedes
  Passwort an). Jetzt bricht die Kopplung dann ab.
- Lichtkurve: Ein Stützpunkt „NaN“ (im Lux-Feld tippbar) brachte die App zum Absturz.
- Regler: Jedes Mausereignis beim Ziehen erzeugte einen Auftrag „manual“ (Log, Protokoll
  der Sensor-Diagnose, Pause der Lichtregelung, UserDefaults-Write). Jetzt gilt der Wert
  beim Ziehen sofort, gespeichert und gemeldet wird einmal beim Loslassen.
- DDC-Diagnose: Nach einem erfolgreichen Test-Read stand „Bereit“ neben „reagiert nicht“,
  weil der Monitor in der Software-Dimmung blieb. Jetzt übernimmt DDC wieder wie nach der
  Prüfung. Ein gescheiterter Test-Write gilt nicht mehr als zuletzt gesendeter Wert.
- Wird ein Monitor abgezogen, wanderten sein Overlay und sein Schwarzfenster bis zum
  Refresh (1,5 s) auf einen anderen Bildschirm. Jetzt verschwinden sie sofort.
- Die 10-s-Grenze für das Alter einer Abwesenheitsmeldung war wirkungslos (das Alter
  wurde direkt vor der Prüfung auf 0 gesetzt); entfernt.
- Firmware: Im Kopplungsfenster fiel das Passwort ganz weg, auch für Weboberfläche und
  OTA-Update. Jetzt ist dort nur der Code ohne Login abrufbar (eigener Handler), alles
  andere bleibt hinter dem Digest-Login.
- Gamma-Dimmung: Scheiterte ein Write, nachdem ein Display schon gedimmt war, blieb seine
  Kurve skaliert stehen, und das Overlay dimmte obendrauf (doppelt dunkel, bis zum
  nächsten ColorSync-Reset). Jetzt kommt die gemerkte Originalkurve zurück, sobald sich
  das Display wieder beschreiben lässt.
- Baugleiche Monitore ohne Seriennummer (viele melden 0) teilten sich Helligkeit,
  Verfahren und DDC-Wahl, und der Monitor-Picker im Tab „Licht“ konnte den zweiten nicht
  wählen. Jetzt bekommt jeder Zwilling einen eigenen Schlüssel (nach Lage in der
  Anordnung; der linke behält den bisherigen), und der Picker geht über die Display-ID.
- Schreibtisch-Sensor: Antwortete der Sensor mit 200 und schloss den Strom sofort
  (Sendestau, Socket-Limit), verband die App im Sekundentakt neu. Als Verbindung zählt
  erst die erste SSE-Nachricht; vorher wächst die Pause (1 s → 30 s) weiter.
- Schreibtisch-Sensor: Jede neue Quelle (Koppeln, Demo, Ein/Aus) legte eine `URLSession`
  an, die nie invalidiert wurde. Jetzt gibt es eine Session je Strom, am Ende invalidiert.
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
