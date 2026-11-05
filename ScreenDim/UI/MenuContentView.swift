import ScreenDimKit
import SwiftUI

/// Fenster der Menüleiste, aufs Wesentliche reduziert: oben die Helligkeit als Regler im
/// Stil des Kontrollzentrums, darunter drei Zeilen. Alles Technische (Login, Dimmverfahren,
/// Tastenkürzel) steht in den Einstellungen.
struct MenuContentView: View {
    let manager: DisplayManager
    let sensor: SensorController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sensor.isDemoActive {
                DemoBanner(sensor: sensor, title: "Demo-Modus aktiv")
            }

            brightnessCard

            if !manager.hotKeysAvailable {
                Label("Tastenkürzel ⌃⌥↑/↓ sind von einer anderen App belegt", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
            }

            MenuDivider()

            VStack(spacing: 0) {
                sensorRow
                Button { showSettings() } label: {
                    MenuRowLabel("Einstellungen …", systemImage: "gearshape", shortcut: "⌘,")
                }
                .keyboardShortcut(",")
            }
            .buttonStyle(MenuRowStyle())

            MenuDivider()

            Button { NSApplication.shared.terminate(nil) } label: {
                MenuRowLabel("Beenden", systemImage: "power", shortcut: "⌘Q")
            }
            .keyboardShortcut("q")
            .buttonStyle(MenuRowStyle())
        }
        .padding(6)
        .frame(width: 300)
        .onAppear {
            // Kein Login-Status hier (synchroner XPC-Aufruf): Das Menü zeigt ihn nicht.
            Task { await manager.syncBuiltInBrightness() }
        }
    }

    // MARK: - Helligkeit

    /// Eine Karte für alle Regler: bei mehreren Monitoren zuerst „Alle Monitore“, dann je
    /// Monitor sein Name und sein Regler. Ignorierte Monitore fehlen; an ihnen gibt es
    /// nichts zu regeln. Angezeigt wird, was die Monitore gerade ausgeben, live auch beim
    /// Abdunkeln (Leerlauf, Abwesenheit) und bei der Lichtregelung; Ziehen setzt den Wert.
    /// Neben dem obersten Regler schaltet ein Knopf zwischen automatisch und manuell, sofern
    /// ein Sensor (oder die Demo) etwas regeln kann.
    private var brightnessCard: some View {
        let monitors = manager.monitors.filter { !$0.isIgnored }
        return VStack(alignment: .leading, spacing: 12) {
            if manager.monitors.isEmpty {
                Label("Kein Display gefunden", systemImage: "display.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else if monitors.isEmpty {
                Label("Alle Monitore werden ignoriert", systemImage: "display")
                    .foregroundStyle(.secondary)
            } else {
                if monitors.count > 1 {
                    BrightnessControl(
                        title: String(localized: "Alle Monitore"),
                        systemImage: "sun.max.fill",
                        value: Binding(get: { manager.masterOutputBrightness }, set: { manager.setAllBrightness($0, interactive: true) }),
                        onEnded: { manager.endInteractiveBrightness() },
                        isEnabled: monitors.contains(where: \.isAdjustable)
                    ) {
                        modeButton
                    }
                }
                ForEach(monitors) { monitor in
                    BrightnessControl(
                        title: monitor.name,
                        systemImage: monitor.isBuiltIn ? "laptopcomputer" : "display",
                        value: Binding(
                            get: { manager.outputBrightness(for: monitor.id) ?? monitor.brightness },
                            set: { manager.setBrightness($0, for: monitor.id, interactive: true) }
                        ),
                        onEnded: { manager.endInteractiveBrightness(for: monitor.id) },
                        isEnabled: monitor.isAdjustable
                    ) {
                        // Nur ein Monitor: Der Knopf steht neben seinem Regler.
                        if monitors.count == 1 { modeButton }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }

    /// Ohne Sensor und Demo regelt nichts automatisch; dann gibt es nichts umzuschalten.
    @ViewBuilder
    private var modeButton: some View {
        if sensor.isEnabled || sensor.isDemoActive {
            ModeButton(isManual: sensor.isManualMode) { sensor.setManualMode(!sensor.isManualMode) }
        }
    }

    // MARK: - Zeilen

    /// Mit Sensor: sein Zustand. Ohne: der Weg zur Einrichtung. Beides öffnet die Einstellungen.
    @ViewBuilder
    private var sensorRow: some View {
        if sensor.isEnabled && !sensor.isDemoActive {
            Button { showSettings() } label: {
                MenuRowLabel("Schreibtisch-Sensor", systemImage: "sensor") {
                    SensorStatusLabel(sensor: sensor)
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
            }
        } else {
            Button { showSettings() } label: {
                MenuRowLabel("Schreibtisch-Sensor einrichten …", systemImage: "sensor")
            }
            .help("Hilfe: optionalen Anwesenheits- und Lichtsensor koppeln oder den Demo-Modus testen")
        }
    }

    /// Menüleisten-App: Das Fenster käme sonst hinter anderen Apps hoch.
    private func showSettings() {
        openSettings()
        NSApplication.shared.activate()
    }
}

// MARK: - Helligkeitsregler

/// Name und Wert in einer Zeile, darunter der Regler, rechts daneben optional ein Knopf.
/// `value` setzt beim Ziehen jeden Zwischenwert; `onEnded` meldet das Loslassen (speichern,
/// Auftrag).
private struct BrightnessControl<Accessory: View>: View {
    /// Schon lokalisiert bzw. Monitorname.
    let title: String
    let systemImage: String
    @Binding var value: Double
    let onEnded: () -> Void
    let isEnabled: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Gerundet: Beim Überblenden liegen die Werte zwischen ganzen Prozent.
                Text(verbatim: "\(Int(value.rounded())) %")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .opacity(contentOpacity)
            HStack(spacing: 8) {
                BrightnessBar(value: $value, onEnded: onEnded, systemImage: systemImage)
                    .accessibilityLabel(Text("Helligkeit \(title)"))
                    .disabled(!isEnabled)
                    .opacity(contentOpacity)
                // Bleibt bedienbar, auch während die Monitore noch geprüft werden.
                accessory
            }
        }
    }

    private var contentOpacity: Double { isEnabled ? 1 : 0.5 }
}

/// Runder Knopf wie im Kontrollzentrum: in Akzentfarbe, solange Licht und Anwesenheit die
/// Helligkeit regeln; grau mit Hand, wenn der Wert vom Regler dauerhaft gilt.
private struct ModeButton: View {
    let isManual: Bool
    let toggle: () -> Void

    private static let size: CGFloat = 28

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isManual ? "hand.point.up.left.fill" : "sensor.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isManual ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                .frame(width: Self.size, height: Self.size)
                .background(isManual ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.tint), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(isManual
            ? Text("Manuell: Die Helligkeit bleibt, wie du sie einstellst; nichts dunkelt ab oder schaltet aus. Klicken schaltet auf automatisch.")
            : Text("Automatisch: Umgebungslicht und Anwesenheit regeln die Helligkeit. Klicken schaltet auf manuell."))
        .accessibilityLabel(Text("Automatische Helligkeit"))
        .accessibilityValue(isManual ? Text("Aus") : Text("An"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// Regler wie im Kontrollzentrum: eine Kapsel, deren weiße Füllung die Helligkeit zeigt,
/// links das Symbol. Ziehen oder Klicken setzt den Wert, Pfeiltasten über die
/// Bedienungshilfen.
private struct BrightnessBar: View {
    @Binding var value: Double
    let onEnded: () -> Void
    let systemImage: String
    @Environment(\.isEnabled) private var isEnabled

    private static let height: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.fill.secondary)
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    .frame(width: max(Self.height, width * value / 100))
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.7))
                    .frame(width: Self.height, height: Self.height)
            }
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled, width > 0 else { return }
                        value = (gesture.location.x / width * 100).rounded().clamped(to: 0...100)
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        onEnded()
                    }
            )
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value)) %"))
        .accessibilityAdjustableAction { direction in
            let step = DisplayManager.hotKeyStep
            switch direction {
            case .increment: value = (value + step).clamped(to: 0...100)
            case .decrement: value = (value - step).clamped(to: 0...100)
            @unknown default: return
            }
            onEnded()
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Menü-Bausteine

/// Inhalt einer Menüzeile: Symbol in fester Spalte, Titel, rechts Kürzel oder Zustand.
private struct MenuRowLabel<Trailing: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var trailing: Trailing

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            Spacer(minLength: 8)
            trailing
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

extension MenuRowLabel where Trailing == Text? {
    init(_ title: LocalizedStringKey, systemImage: String, shortcut: String? = nil) {
        self.init(title, systemImage: systemImage) {
            shortcut.map { Text(verbatim: $0) }
        }
    }
}

/// Wie ein Menüeintrag: beim Überfahren hinterlegt, beim Drücken etwas dunkler.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    Color.primary.opacity(highlight),
                    in: .rect(cornerRadius: 6)
                )
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
        }

        private var highlight: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.16 }
            return isHovered ? 0.08 : 0
        }
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 8)
    }
}
