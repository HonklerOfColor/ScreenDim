# ScreenDim

macOS-Menüleisten-App (`LSUIElement`), die die Helligkeit aller Displays regelt.
Swift 6, SwiftUI, macOS 15+, Apple Silicon. Sprache in Code-Kommentaren, UI-Quelltexten
und Doku: Deutsch. Open Source auf GitHub.

## Ein Target, Developer ID

`ScreenDim` (Bundle-ID `com.andreastrabi.ScreenDim`), ohne Sandbox, Hardened Runtime,
Verteilung per Developer ID und Notarisierung. Kein App Store: DDC/CI auf Apple Silicon
geht nur über `IOAVService`, und das ist private API (Review-Richtlinie 2.5.1).

- Externe Monitore regelt die App per DDC/CI (Hintergrundbeleuchtung des Monitors); das
  ist der Standard, sobald ein DDC-Kanal (`DCPAVServiceProxy`) gefunden wird. Kommt DDC
  nicht durch (Null-Antwort, Timeout, I/O-Fehler), dimmt automatisch die Software (Gamma
  oder Overlay). Der Nutzer wählt je Monitor DDC/CI, Gamma, Overlay oder Ignorieren
  (`BrightnessMethod`); Gamma/Overlay statt DDC/CI heißt: kein Kanal, kein I2C-Verkehr.
  Ignorieren (`DDCState.ignored`, etwa für einen Beamer): kein Kanal, keine
  Software-Dimmung, kein Licht, kein Leerlauf, kein Schwarzschalten. Ist ein Monitor
  ignoriert, schlafen die Displays bei Abwesenheit nicht (der Ruhezustand träfe alle);
  die übrigen werden schwarz.
- Das eingebaute Display lässt sich per Software dimmen; seine Hintergrundbeleuchtung
  regelt macOS (Helligkeitstasten). Die frühere Steuerung über `DisplayServices` und der
  eingebaute Lichtsensor (IOHIDEventSystem) sind entfernt; ihr Code steht in der
  Git-Historie (bis Commit `b3ca76a`), `docs/EingebauterLichtsensor.md` bleibt als
  Messprotokoll. Die Fabriken `makeBuiltInControl` und `isAutoBrightnessEnabled` gibt es
  noch; die App reicht nichts herein. Die Reste des Lichtsensors in `SensorController`,
  `LightSourceSelector` und der Sensor-Diagnose sind entfernt; gespeicherte Altwerte von
  `LightSource` werden zu `deskSensorOnly`.
- Private API nur in der App (`ScreenDim/System/IOAVServiceTransport.swift`, geladen per
  `dlsym`). `ScreenDimKit` enthält keine private API und keine Namen wie `IOAVService`
  als Zeichenkette; die Kanäle kommen über die Fabrik `makeExternalControl` herein, damit
  die Paket-Tests ohne Hardware laufen.

## Architektur

- `ScreenDimKit/` (lokales Swift-Paket, Logik ohne UI):
  - `DDC/`: Paketaufbau (DDC/CI 1.1), `DDCService` (eine serielle Queue je Monitor,
    Deadline, Sperre bei Hängern, höchstens 3 offene Aufrufe, Vorlauf-Write nach jedem
    Read), `LatestValueThrottle`, `I2CTransport` (nur das Protokoll), `DDCDiagnostics`.
  - `Display/`: `DisplayManager` (Zustand, Kanal-Cache über Refreshes, Probe in bis zu
    drei Runden, Routing der Software-Dimmung, `setBrightnessMethod`), `DisplayDiscovery`
    (CoreGraphics und IORegistry: Framebuffer ↔ `DCPAVServiceProxy`, DisplayPort-Links),
    `BrightnessStore` (DDC- und Software-Wert getrennt, Verfahren und DDC-Wahl je
    Monitor), `BrightnessMethod`, `SoftwareDimming` mit `GammaDimmer` und
    `OverlayDimmer`, `ScreenBlanker`, `DisplayDiagnostics`, `IdleDimmer` (Leerlauf-Dimmung,
    Standard aus), `DisplaySleep` (Display-Ruhezustand von macOS: `pmset displaysleepnow`,
    Wecken per `IOPMAssertionDeclareUserActivity`; öffentliche API).
  - `Sensor/`: optionaler Schreibtisch-Sensor. `SensorController` (Einstellungen, Kopplung,
    Quelle, Abwesenheit in zwei Stufen, Lux → Helligkeit),
    `SensorSource` mit `SSESensorSource` (Digest, SSE, Backoff) und
    `SimulatedSensorSource` (Demo), `SensorBrowser` (NWBrowser), `SensorKeychain`,
    `PairingCode`, `SSEParser`/`ESPHomeEvents`, `PresenceGate`, `SensorDebug`
    (Protokoll für das Fenster „Sensor-Diagnose“, läuft nur, solange es offen ist).
    Jeder Monitor folgt seinem Lichtprofil (`LightCurve`: Lux-Stützpunkte, je Monitor
    abschaltbar); Licht und Anwesenheit kommen vom ESP32 (oder der Demo). `LightSource`
    ist nur noch `deskSensorOnly` oder `off`.
- Lichtregelung:
  - Alle automatischen Wege laufen über `DisplayManager.fadeBrightness` (Licht 2 s,
    Prüfung/Rückfall/Aufwachen 0,5 s), Start beim echten Wert (DDC: zuletzt bestätigter
    Write, kein Read). Nur `setBrightness` (Regler, Tasten) setzt sofort und pausiert die
    Lichtregelung des Monitors.
  - Lux des ESP32 durchgereicht, Hysterese 3 Punkte gegen das laufende Ziel. Werte
    außerhalb 0…200 000 lx verwirft `SensorController` (Log `notice`).
    Schreibtisch-Sensor frisch durch jedes Ereignis (45 s).
  - Je Auftrag ein `BrightnessJob` mit Grund: Protokoll der Sensor-Diagnose und
    Log `notice` (auch Licht-Aufträge), Kategorie `light`. Codes und Passwörter nie loggen.
- Leerlauf-Dimmung (`IdleDimmer`): Nach der gewählten Zeit ohne Eingabe (Zeit seit der
  letzten Eingabe laut `CGEventSource`, ein Schlaf bis zum Ablauf, kein Takt) deckelt
  `DisplayManager.beginDim(.idle, …)` nur die Ausgabe; `brightness`, gespeicherte Werte und
  Lichtregelung laufen weiter. DDC schreibt nur geänderte Ausgaben. Maus weckt sofort
  (Event-Monitor), Tasten über eine Prüfung je Sekunde, nur solange abgedunkelt ist (ohne
  Bedienungshilfen-Freigabe sieht kein Event-Monitor fremde Tasten). Schlafen die
  Bildschirme, ruht alles; nach ihrem Aufwachen kommt die Helligkeit 2 s später zurück.
  Es zählen nur Eingaben: Auch bei laufendem Video (Zusicherungen gegen den Display-Ruhezustand)
  wird abgedunkelt. Meldet der Sensor die Rückkehr, zählt das wie eine Eingabe
  (`SensorController.onArrival` → `IdleDimmer.noteActivity`, verdrahtet in der App).
- Abwesenheit (`SensorController`; Sensor meldet „weg“, seit 2 s keine Eingabe): Stufe 1
  deckelt die Ausgabe (`beginDim(.absence, …)`; je Grund ein eigener Deckel, es gilt der
  niedrigste). Stufe 2 nach `absenceOffDelay` (Standard 5 min, „nie“, mindestens 30 s;
  ein gespeichertes „sofort“ wird 30 s) schickt
  alle Displays in den Ruhezustand von macOS, nicht per DDC `0xD6` (monitorabhängig, oft
  nur per Taste wieder an, Dock-Hänger). Vorher prüft sie, ob es seit dem Abdunkeln eine
  Eingabe gab (Tasten ohne Bedienungshilfen, Kürzel). Die Rückkehr weckt die Displays;
  Helligkeit erst nach `screensDidWake` und 2 s, denn DDC an schlafende Monitore scheitert.
  Schlafen sie schon (macOS), wird nichts gedimmt, die Rückkehr weckt sie trotzdem. Jeder
  Wechsel von „abwesend“ zu „anwesend“ weckt schlafende Displays, auch ohne Abwesenheit
  von ScreenDim (etwa nach „Eingabe gewinnt“); die erste Meldung nach dem Verbinden nicht.
  Wachen die Displays während einer Abwesenheit auf (etwa durch eine Mitteilung) und
  meldet der verbundene Sensor danach weiter „abwesend“, beginnt die Abwesenheit von vorn,
  außer eine Eingabe kurz vor oder nach dem Aufwachen (`PresenceGate.inputGrace`) hat sie
  geweckt. Schalter „Bei Abwesenheit reagieren“ (`reactsToAbsence`, Standard an): aus,
  schaltet die Anwesenheit nichts (kein Abdunkeln, Ausschalten, Wecken, `onArrival`).
- `ScreenDim/` (App): `App/` (Einstieg, Fabrik für DDC), `UI/` (Menü, Einstellungen,
  Sensor-Diagnose, DDC-Diagnose), `System/` (Tastenkürzel, Login-Item, `IOAVService`),
  `Resources/` (Asset-Katalog, String-Katalog, Privacy-Manifest).
- `Firmware/` (ESPHome, ESP32-S3 + Waveshare HMMD mmWave + VEML7700 per I2C):
  `screendim-desk.yaml`, Kopplungscode und Auth-Umschaltung in `screendim_pairing.h`,
  Stückliste und Schaltplan (`schaltplan.svg`, von Hand geschriebenes SVG) in
  `README.md`. Variante Seeed Studio XIAO ESP32S3: `screendim-desk-xiao.yaml` bindet
  `screendim-desk.yaml` als Paket ein und ersetzt Board, Pins, LED und die Skripte
  `led_pairing`/`led_new_code` (per `!remove`), Schaltplan `schaltplan-xiao.svg`.
  Muss zu `SensorProtocol` passen (Entitätsnamen, mDNS-TXT, Nutzer `screendim`).
  Anwesenheit: Textzeilen des Radars (UART-Debugger als Empfänger, `ON`/`OFF`,
  `Range <cm>`) bis „Max Distance“ (Template-Number, Standard 120 cm), mit Hysterese:
  „abwesend“ erst ab Max Distance + 20 cm (`presence_distance_hysteresis`, Zustand in der
  global `distance_within`), „anwesend“ wieder ab Max Distance; schweigt der UART,
  gilt OT2. YAML
  prüfen: `esphome config` für beide Dateien. ESPHome im venv
  `~/.venvs/esphome`, Build immer mit `ESPHOME_DATA_DIR=/tmp/screendim-esphome` (nicht in
  iCloud). Zwischen USB-Resets mindestens 60 s laufen lassen, sonst zählt Safe Mode mit
  (10 schnelle Neustarts). Zustandswechsel loggt ESPHome 2026.10 nur auf VERBOSE.

Software-Dimmung: Gamma ist Standard. Lässt sich die Gamma-Tabelle eines Displays nicht
lesen oder setzen, dimmt automatisch das Overlay; der Nutzer kann pro Monitor umschalten.
Kurven komplett neu (mit ColorSync-Reset) nur bei geänderter Display-Menge oder nach dem
Aufwachen; bei reinen Umkonfigurationen (Auflösung) wird nur das betroffene Display neu
geschrieben.

## Build-Regeln

- Projektänderungen nur über `project.yml`, danach `xcodegen generate`. Das `.xcodeproj`
  und `Config/*.plist` sind generiert und nicht im Git.
- `xcodegen generate` nur, wenn das Projekt in Xcode geschlossen ist. Lädt Xcode 27 ein
  offenes Projekt neu, hält es `ScreenDimKit/.swiftpm/xcode` für ein Projekt, öffnet das
  Paket als Ordner und meldet „Missing package product 'ScreenDimKit'“. Abhilfe: Xcode
  beenden (⌘Q), `ScreenDimKit/.swiftpm` löschen, Projekt neu öffnen.
- Builds nur generisch, DerivedData außerhalb von iCloud:
  ```
  xcodebuild -project ScreenDim.xcodeproj -scheme "ScreenDim" -destination 'generic/platform=macOS' -derivedDataPath /tmp/screendim-dd CODE_SIGNING_ALLOWED=NO build
  ```
  Muss ohne Warnungen bauen (Warnungen sind Fehler). Die Logzeile von
  `appintentsmetadataprocessor` („Metadata extraction skipped“) ist keine Diagnose.
- `xcodebuild` gleicht den String-Katalog nicht ab; das macht nur ein Build in Xcode.
  Neue Texte bis dahin von Hand in `Localizable.xcstrings` eintragen (mit Englisch).
- Tests nur im Paket: `cd ScreenDimKit && swift test --scratch-path /tmp/screendim-kit-build`.
  Kein `xcodebuild test`, kein Simulator. Tests benutzen keine UserDefaults-Suites, sondern
  `MemoryPreferences` aus `TestDoubles.swift`: `cfprefsd` legt Suite-Plists in
  ~/Library/Preferences asynchron an, auch nach `removePersistentDomain`.
- App nicht ungefragt starten. Kein Netzwerk, kein `git push`. Commits nur nach Freigabe.
- Keine Timer oder Polling, wo Notifications reichen. Version nur auf Anweisung ändern.

## Lokalisierung

`ScreenDim/Resources/Localizable.xcstrings`, Quelle Deutsch, dazu Englisch. SwiftUI-Literale
extrahiert Xcode. Texte aus `ScreenDimKit` laufen über `String(localized:)` mit dem
Haupt-Bundle; ihre Schlüssel stehen von Hand im Katalog (`extractionState: manual`).
Schlüsselbildung: `Int` → `%lld`, `String` → `%@`, ein `%` neben einer Interpolation → `%%`,
zwei Interpolationen → `%1$@`, `%2$@`.

## Hardware-Erfahrungen (DDC/CI)

- Monitore hinter dem StarTech-TB4-Dock (Realtek-MST-Hub, OUI 00 E0 4C) sind für DDC
  unzuverlässig. Der S34CG50 blieb nach einem doppelten Set-VCP-Write (10 ms Abstand)
  im Kernel hängen (Aufrufe blockierten etwa 8 s). Deshalb: nie schnell hintereinander
  abfragen, `writeRepeats` bei 1 lassen.
- Direkt am Mac (JapanNext 6K per TB4, U28E590 per USB-C→DP, 2026-11-03): Der erste
  I2C-Write nach einem Read kommt nicht an. W-R-W-R bleibt Null-Message (mit dem Rest
  der vorigen Antwort im Puffer), W-W-R antwortet immer, auch mit 160 ms Abstand; ein
  einzelner Set-VCP nach einem Read geht verloren. Deshalb der Vorlauf-Write
  (`DDCTiming.primeAfterRead`). Mess-Werkzeug: eigenes Swift-CLI mit `IOAVService`.
- JapanNext 6K (6720×3780): über USB-C→DP (Sabrent-Adapter) nur Null-Messages, außer
  einmal beim Einstecken vor dem EDID; über HDMI und über Thunderbolt-4-Kabel an seinem
  USB-C-Eingang geht DDC/CI (TB4: Antwort sofort in Runde 1). Nach dem Einstecken per
  HDMI etwa 5 s Zufallsbytes (`checksumMismatch`), daher die dritte Probe-Runde.
- In zsh ist `log` ein Builtin; immer `/usr/bin/log show|stream` verwenden.
- Codesign im iCloud-Ordner scheitert an FinderInfo-xattrs; DerivedData daher unter `/tmp`.
