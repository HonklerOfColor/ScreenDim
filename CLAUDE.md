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
    (Protokoll für das Fenster „Sensor-Diagnose“, läuft nur, solange es offen ist). Lichtquelle wählbar
    (`LightSource`); den eingebauten Lichtsensor reicht Direct per Fabrik
    (`makeBuiltInLightSensor`, Quelle `Direct/BuiltInLightSensor.swift`).
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
