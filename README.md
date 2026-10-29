# ScreenDim

Helligkeit aller Displays aus der Menüleiste regeln: ein Slider pro Monitor, einer für
alle, dazu ⌃⌥↑ / ⌃⌥↓ für alle Monitore in 10-%-Schritten.

## Varianten

- **ScreenDim (Mac App Store):** läuft in der Sandbox und nutzt nur öffentliche API.
  Externe Monitore werden per Software abgedunkelt: Gamma-Kurve oder halbtransparentes
  Overlay, pro Monitor wählbar. Die Hintergrundbeleuchtung bleibt, wie sie ist. Das
  eingebaute Display regelst du wie gewohnt mit den Helligkeitstasten.
- **ScreenDim Direct (Developer ID):** regelt die Hintergrundbeleuchtung externer Monitore
  per DDC/CI und das eingebaute Display direkt. Wo DDC nicht durchkommt (manche Docks und
  Adapter), dimmt sie per Software. Mit Diagnose-Fenster für DDC-Probleme.

## Voraussetzungen

macOS 15 oder neuer, Apple Silicon. Zum Bauen: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Bauen

```bash
xcodegen generate
```

```bash
xcodebuild -project ScreenDim.xcodeproj -scheme "ScreenDim" -destination 'generic/platform=macOS' -derivedDataPath /tmp/screendim-dd CODE_SIGNING_ALLOWED=NO build
```

```bash
xcodebuild -project ScreenDim.xcodeproj -scheme "ScreenDim Direct" -destination 'generic/platform=macOS' -derivedDataPath /tmp/screendim-dd CODE_SIGNING_ALLOWED=NO build
```

Die App-Store-Variante auf private API prüfen:

```bash
scripts/check-mas-binary.sh /tmp/screendim-dd/Build/Products/Debug/ScreenDim.app
```

## Tests

```bash
cd ScreenDimKit && swift test --scratch-path /tmp/screendim-kit-build
```

Die Tests brauchen weder die App noch Hardware.

## Aufbau

- `ScreenDimKit/`: Swift-Paket mit der Logik (DDC-Protokoll, Display-Verwaltung,
  Software-Dimmung, Speicher).
- `ScreenDim/`: die App (SwiftUI-Menü, Tastenkürzel, Login-Item). `ScreenDim/Direct/`
  enthält die private API und gehört nur zur Direct-Variante.
- `project.yml`: Projektbeschreibung für XcodeGen.

Weitere Details stehen in `CLAUDE.md`. Offene Punkte stehen in `STATUS.md`, Änderungen in `CHANGELOG.md`.
