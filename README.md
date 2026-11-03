# ScreenDim

Helligkeit aller Displays aus der Menüleiste regeln: ein Slider pro Monitor, einer für
alle, dazu ⌃⌥↑ / ⌃⌥↓ für alle Monitore in 10-%-Schritten.

ScreenDim läuft in der Sandbox und nutzt nur öffentliche API (Mac App Store). Monitore
werden per Software abgedunkelt: Gamma-Kurve oder halbtransparentes Overlay, pro Monitor
wählbar. Die Hintergrundbeleuchtung bleibt, wie sie ist; die des eingebauten Displays
regelst du wie gewohnt mit den Helligkeitstasten. Optional regelt ein Schreibtisch-Sensor
(ESP32) die Helligkeit nach dem Umgebungslicht und schaltet die Bildschirme bei
Abwesenheit ab.

## Voraussetzungen

macOS 15 oder neuer, Apple Silicon. Zum Bauen: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Bauen

```bash
xcodegen generate
```

```bash
xcodebuild -project ScreenDim.xcodeproj -scheme "ScreenDim" -destination 'generic/platform=macOS' -derivedDataPath /tmp/screendim-dd CODE_SIGNING_ALLOWED=NO build
```

Das Binary auf private API prüfen:

```bash
scripts/check-mas-binary.sh /tmp/screendim-dd/Build/Products/Debug/ScreenDim.app
```

## Tests

```bash
cd ScreenDimKit && swift test --scratch-path /tmp/screendim-kit-build
```

Die Tests brauchen weder die App noch Hardware.

## Aufbau

- `ScreenDimKit/`: Swift-Paket mit der Logik (Display-Verwaltung, Software-Dimmung,
  Sensor, Speicher).
- `ScreenDim/`: die App (SwiftUI-Menü, Einstellungen, Tastenkürzel, Login-Item).
- `project.yml`: Projektbeschreibung für XcodeGen.

Weitere Details stehen in `CLAUDE.md`. Offene Punkte stehen in `STATUS.md`, Änderungen in `CHANGELOG.md`.
