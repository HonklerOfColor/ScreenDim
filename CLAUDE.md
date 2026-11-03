# ScreenDim

macOS-Menüleisten-App (`LSUIElement`), die die Helligkeit aller Displays regelt.
Swift 6, SwiftUI, macOS 15+, Apple Silicon. Sprache in Code-Kommentaren, UI-Quelltexten
und Doku: Deutsch.

## Ein Target

`ScreenDim` (Bundle-ID `com.andreastrabi.ScreenDim`), Mac App Store, Sandbox, nur
öffentliche API. Externe Monitore dimmt die App per Software (Gamma oder Overlay); das
eingebaute Display lässt sich ebenso per Software dimmen, seine Hintergrundbeleuchtung
regelt macOS (Helligkeitstasten).

- Keine private API im Projekt. `ScreenDimKit` enthält keine Namen wie `IOAVService` oder
  `DisplayServices` als Zeichenkette. Nach jedem Build: `scripts/check-mas-binary.sh
  <ScreenDim.app>` muss mit Exit 0 enden. Der Hinweis auf `_dlsym` kommt aus clangs
  Laufzeit für Verfügbarkeitsprüfungen (SwiftUI) und ist kein Treffer.
- Die frühere Variante „ScreenDim Direct“ (Developer ID, DDC/CI über `IOAVService`,
  eingebautes Display über `DisplayServices`, eingebauter Lichtsensor) wurde am
  2026-11-03 entfernt; ihr Code steht in der Git-Historie (bis Commit `b3ca76a`).
  Den eingebauten Lichtsensor als Lichtquelle gibt es nicht; `docs/EingebauterLichtsensor.md`
  bleibt als Messprotokoll.
- Noch in `ScreenDimKit`, aber von der App nicht mehr genutzt: der DDC-Stack (`DDC/`,
  Kanal-Fabriken und Probe im `DisplayManager`, `isDDCEnabled`) und die Lichtquelle
  „eingebaut“ im `SensorController` (`makeBuiltInLightSensor`, `LightSource` mit
  `builtIn…`, `LuxFilter`-Zweig). Ohne Fabriken bekommt kein Monitor einen Kanal
  (`DDCState.noChannel`), alles läuft über Software-Dimmung; ohne eingebauten Sensor
  wirkt jede `LightSource` außer „aus“ wie „nur Schreibtisch“.

## Architektur

- `ScreenDimKit/` (lokales Swift-Paket, Logik ohne UI):
  - `DDC/`: Paketaufbau (DDC/CI 1.1), `DDCService` (eine serielle Queue je Monitor,
    Deadline, Sperre bei Hängern, höchstens 3 offene Aufrufe), `LatestValueThrottle`,
    `I2CTransport` (nur das Protokoll). Von der App nicht genutzt, siehe oben.
  - `Display/`: `DisplayManager` (Zustand, Routing der Software-Dimmung; die
    DDC-Teile sind ohne Fabriken inaktiv), `DisplayDiscovery` (CoreGraphics; die App
    ruft sie mit `scanRegistry: false`), `BrightnessStore` (DDC- und Software-Wert
    getrennt, Verfahren je Monitor), `SoftwareDimming` mit `GammaDimmer` und
    `OverlayDimmer`, `ScreenBlanker`, `DisplayDiagnostics`.
  - `Sensor/`: optionaler Schreibtisch-Sensor. `SensorController` (Einstellungen, Kopplung,
    Quelle, Abwesenheit → `DisplayManager.setScreensBlanked`, Lux → Helligkeit),
    `SensorSource` mit `SSESensorSource` (Digest, SSE, Backoff) und
    `SimulatedSensorSource` (Demo), `SensorBrowser` (NWBrowser), `SensorKeychain`,
    `PairingCode`, `SSEParser`/`ESPHomeEvents`, `PresenceGate`, `SensorDebug`
    (Protokoll für das Fenster „Sensor-Diagnose“, läuft nur, solange es offen ist).
    Jeder Monitor folgt seinem Lichtprofil (`LightCurve`: Lux-Stützpunkte, je Monitor
    abschaltbar); Licht und Anwesenheit kommen vom ESP32 (oder der Demo).
- Lichtregelung:
  - Alle automatischen Wege laufen über `DisplayManager.fadeBrightness` (Licht 2 s,
    Rückfall/Aufwachen 0,5 s), Start beim echten Wert. Nur `setBrightness`
    (Regler, Tasten) setzt sofort und pausiert die Lichtregelung des Monitors.
  - Lux des ESP32 durchgereicht, Hysterese 3 Punkte gegen das laufende Ziel.
    Schreibtisch-Sensor frisch durch jedes Ereignis (45 s).
  - Je Auftrag ein `BrightnessJob` mit Grund: Protokoll der Sensor-Diagnose und
    `log.info`, Kategorie `light`.
- `ScreenDim/` (App): `App/` (Einstieg), `UI/`, `System/` (Tastenkürzel, Login-Item),
  `Resources/` (Asset-Katalog, String-Katalog, Privacy-Manifest).

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
- Tests nur im Paket: `cd ScreenDimKit && swift test --scratch-path /tmp/screendim-kit-build`.
  Kein `xcodebuild test`, kein Simulator. Tests benutzen keine UserDefaults-Suites, sondern
  `MemoryPreferences` aus `TestDoubles.swift`: `cfprefsd` legt Suite-Plists in
  ~/Library/Preferences asynchron an, auch nach `removePersistentDomain`.
- Danach `scripts/check-mas-binary.sh` auf das gebaute `ScreenDim.app`.
- App nicht ungefragt starten. Kein Netzwerk, kein `git push`. Commits nur nach Freigabe.
- Keine Timer oder Polling, wo Notifications reichen. Version nur auf Anweisung ändern.

## Lokalisierung

`ScreenDim/Resources/Localizable.xcstrings`, Quelle Deutsch, dazu Englisch. SwiftUI-Literale
extrahiert Xcode. Texte aus `ScreenDimKit` laufen über `String(localized:)` mit dem
Haupt-Bundle; ihre Schlüssel stehen von Hand im Katalog (`extractionState: manual`).
Schlüsselbildung: `Int` → `%lld`, `String` → `%@`, ein `%` neben einer Interpolation → `%%`.

## Hardware-Erfahrungen (DDC/CI, aus der Direct-Zeit)

Die App spricht kein DDC/CI mehr; die Befunde bleiben für den DDC-Stack im Paket.

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
