# ScreenDim

macOS-Menüleisten-App (`LSUIElement`), die die Helligkeit aller Displays regelt.
Swift 6, SwiftUI, macOS 15+, Apple Silicon. Sprache in Code-Kommentaren, UI-Quelltexten
und Doku: Deutsch.

## Varianten

Eine Codebasis, zwei App-Targets aus `project.yml`:

| Target | Bundle-ID | Verteilung | Helligkeit |
|---|---|---|---|
| `ScreenDim` | `com.andreastrabi.ScreenDim` | Mac App Store, Sandbox | Externe Monitore per Software (Gamma oder Overlay). Eingebautes Display regelt macOS. |
| `ScreenDim Direct` | `com.andreastrabi.ScreenDim.direct` | Developer ID, keine Sandbox | DDC/CI über `IOAVService`, eingebautes Display über `DisplayServices`, Software-Dimmung als Rückfall. |

- Private API steht **nur** in `ScreenDim/Direct/` und `ScreenDim/UI/DiagnosticsView.swift`.
  Das MAS-Target schließt diese Dateien in `project.yml` aus; zusätzlich sind sie in
  `#if SCREENDIM_DIRECT` gekapselt. Das Flag setzt nur das Direct-Target.
- `ScreenDimKit` enthält keine private API und keine Namen wie `IOAVService` oder
  `DisplayServices` als Zeichenkette. Die DDC-Kanäle kommen über Fabriken in den
  `DisplayManager` (`makeExternalControl`, `makeBuiltInControl`).
- Nach jedem MAS-Build: `scripts/check-mas-binary.sh <ScreenDim.app>` muss mit Exit 0 enden.
  Der Hinweis auf `_dlsym` kommt aus clangs Laufzeit für Verfügbarkeitsprüfungen
  (SwiftUI) und ist kein Treffer.

## Architektur

- `ScreenDimKit/` (lokales Swift-Paket, Logik ohne UI):
  - `DDC/`: Paketaufbau (DDC/CI 1.1), `DDCService` (eine serielle Queue je Monitor,
    Deadline, Sperre bei Hängern, höchstens 3 offene Aufrufe), `LatestValueThrottle`,
    `I2CTransport` (nur das Protokoll).
  - `Display/`: `DisplayManager` (Zustand, Kanal-Cache über Refreshes, Probe, Routing
    der Software-Dimmung), `DisplayDiscovery` (CoreGraphics, optional IORegistry),
    `BrightnessStore` (DDC- und Software-Wert getrennt, Verfahren je Monitor),
    `SoftwareDimming` mit `GammaDimmer` und `OverlayDimmer`, `ScreenBlanker`, `DisplayDiagnostics`.
  - `Sensor/`: optionaler Schreibtisch-Sensor. `SensorController` (Einstellungen, Kopplung,
    Quelle, Abwesenheit → `DisplayManager.setScreensBlanked`, Lux → Helligkeit),
    `SensorSource` mit `SSESensorSource` (Digest, SSE, Backoff) und
    `SimulatedSensorSource` (Demo), `SensorBrowser` (NWBrowser), `SensorKeychain`,
    `PairingCode`, `SSEParser`/`ESPHomeEvents`, `PresenceGate`, `SensorDebug`
    (Protokoll für das Fenster „Sensor-Diagnose“, läuft nur, solange es offen ist).
    Lichtquelle mit Vorrang (`LightSource`: Schreibtisch zuerst (Standard), eingebaut
    zuerst, nur Schreibtisch, nur eingebaut, aus); `LightSourceSelector` (rein) wählt nach
    Verfügbarkeit (ESP32: verbunden, letztes Ereignis ≤ 45 s; eingebaut: Deckel offen,
    Wert ≤ 5 s) mit 5 s Wechselsperre. Jeder Monitor folgt seinem Lichtprofil (`LightCurve`:
    Lux-Stützpunkte, je Monitor abschaltbar), gleich aus welcher Quelle; Anwesenheit
    kommt nur vom ESP32. Ohne eingebauten Sensor wirkt jede Wahl außer „aus“ wie „nur
    Schreibtisch“, gespeichert bleibt sie. Den eingebauten Lichtsensor reicht Direct per
    Fabrik (`makeBuiltInLightSensor`, Quelle `Direct/BuiltInLightSensor.swift`).
- Lichtregelung (Details `docs/EingebauterLichtsensor.md`, „Lichtregelung“):
  - Ein Schreiber: Das eingebaute Display regelt ScreenDim nur, wenn sein Profil es will
    (Standard: nein) und macOS-Auto-Helligkeit aus ist (Direct liest sie per
    CoreBrightness, Fabrik `isAutoBrightnessEnabled`). Weicht der echte Wert um > 3 Punkte
    vom eigenen ab: übernehmen, 60 s Pause.
  - Alle automatischen Wege laufen über `DisplayManager.fadeBrightness` (Licht 2 s,
    Prüfung/Rückfall/Aufwachen 0,5 s), Start beim echten Wert (eingebaut: lesen bei
    freier Drossel; DDC: zuletzt bestätigter Write, kein Read). Nur `setBrightness`
    (Regler, Tasten) setzt sofort und pausiert die Lichtregelung des Monitors.
  - Lux über `LuxFilter` (eingebaut: Median 5 + EMA 4 s im Log-Raum; ESP32 durchgereicht),
    Hysterese 3 Punkte gegen das laufende Ziel. Schreibtisch-Sensor frisch durch jedes
    Ereignis (45 s), kein Reset beim Quellwechsel.
  - Je Auftrag ein `BrightnessJob` mit Grund: Protokoll der Sensor-Diagnose und
    `log.info`, Kategorie `light`.
- `ScreenDim/` (App): `App/` (Einstieg, Varianten-Auswahl), `UI/`, `System/` (Tastenkürzel,
  Login-Item), `Direct/` (private API), `Resources/` (Asset-Katalog, String-Katalog,
  Privacy-Manifest).

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
  xcodebuild -project ScreenDim.xcodeproj -scheme "ScreenDim Direct" -destination 'generic/platform=macOS' -derivedDataPath /tmp/screendim-dd CODE_SIGNING_ALLOWED=NO build
  ```
  Beide müssen ohne Warnungen bauen (Warnungen sind Fehler). Die Logzeile von
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

## Hardware-Erfahrungen

- Monitore hinter dem StarTech-TB4-Dock (Realtek-MST-Hub, OUI 00 E0 4C) sind für DDC
  unzuverlässig. Der S34CG50 blieb nach einem doppelten Write im Kernel hängen
  (Aufrufe blockierten etwa 8 s). Deshalb: nie schnell hintereinander abfragen, nicht
  doppelt schreiben.
- In zsh ist `log` ein Builtin; immer `/usr/bin/log show|stream` verwenden.
- Codesign im iCloud-Ordner scheitert an FinderInfo-xattrs; DerivedData daher unter `/tmp`.
