import ScreenDimKit
import SwiftUI

/// Fenster der Menüleiste im Stil des Kontrollzentrums: oben die Helligkeit als Karten,
/// darunter Zeilen wie in einem Menü.
struct MenuContentView: View {
    let manager: DisplayManager
    let sensor: SensorController
    let loginItem: LoginItem
    @Environment(\.openSettings) private var openSettings
    #if SCREENDIM_DIRECT
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sensor.isDemoActive {
                DemoBanner(sensor: sensor, title: "Demo-Modus aktiv")
            }

            brightness

            MenuDivider()

            VStack(spacing: 0) {
                loginRow
                sensorRow
            }
            .buttonStyle(MenuRowStyle())

            MenuDivider()

            VStack(spacing: 0) {
                Button { showSettings() } label: {
                    MenuRowLabel("Einstellungen …", systemImage: "gearshape", shortcut: "⌘,")
                }
                .keyboardShortcut(",")
                Button { manager.refresh(force: true) } label: {
                    MenuRowLabel("Monitore neu suchen", systemImage: "arrow.clockwise")
                }
                #if SCREENDIM_DIRECT
                Button {
                    openWindow(id: DiagnosticsView.windowID)
                    NSApplication.shared.activate()
                } label: {
                    MenuRowLabel("Diagnose …", systemImage: "stethoscope")
                }
                #endif
            }
            .buttonStyle(MenuRowStyle())

            MenuDivider()

            Button { NSApplication.shared.terminate(nil) } label: {
                MenuRowLabel("Beenden", systemImage: "power", shortcut: "⌘Q")
            }
            .keyboardShortcut("q")
            .buttonStyle(MenuRowStyle())
        }
        .padding(8)
        .frame(width: 320)
        .onAppear {
            loginItem.reload()
            Task { await manager.syncBuiltInBrightness() }
        }
    }

    // MARK: - Helligkeit

    private var brightness: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Helligkeit")
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.top, 2)

            if manager.monitors.isEmpty {
                Label("Kein Display gefunden", systemImage: "display.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .menuCard()
            } else {
                if manager.monitors.count > 1 {
                    BrightnessSlider(
                        title: String(localized: "Alle Monitore"),
                        systemImage: "sun.max.fill",
                        value: Binding(get: { manager.masterBrightness }, set: { manager.setAllBrightness($0) }),
                        isEnabled: manager.monitors.contains(where: \.isAdjustable)
                    )
                    .menuCard()
                }
                ForEach(manager.monitors) { monitor in
                    MonitorRow(monitor: monitor, manager: manager)
                        .menuCard()
                }
            }

            footnotes
                .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private var footnotes: some View {
        #if !SCREENDIM_DIRECT
        if manager.monitors.contains(where: \.usesSoftwareDimming) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diese Version dimmt per Software. Die Hintergrundbeleuchtung bleibt, wie sie ist.")
                if manager.monitors.contains(where: { $0.isBuiltIn && $0.usesSoftwareDimming }) {
                    Text("Die des eingebauten Displays regelst du weiter mit den Helligkeitstasten.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        #endif
        Group {
            if manager.hotKeysAvailable {
                Text("⌃⌥↑ / ⌃⌥↓  alle Monitore ±\(Int(DisplayManager.hotKeyStep).formatted()) %")
                    .foregroundStyle(.secondary)
            } else {
                Label("Tastenkürzel ⌃⌥↑/↓ sind von einer anderen App belegt", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    // MARK: - Zeilen

    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })) {
                MenuRowLabel("Bei Login starten", systemImage: "person.crop.circle")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.trailing, 8)
            if loginItem.needsApproval {
                Button("In den Systemeinstellungen erlauben …") { loginItem.openSystemSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, MenuMetrics.textInset)
            }
            if let error = loginItem.lastError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, MenuMetrics.textInset)
            }
        }
    }

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
}

extension MenuContentView {
    /// Menüleisten-App: Das Fenster käme sonst hinter anderen Apps hoch.
    private func showSettings() {
        openSettings()
        NSApplication.shared.activate()
    }
}

private struct MonitorRow: View {
    let monitor: DisplayManager.Monitor
    let manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BrightnessSlider(
                title: monitor.name,
                systemImage: monitor.isBuiltIn ? "laptopcomputer" : "display",
                value: Binding(get: { monitor.brightness }, set: { manager.setBrightness($0, for: monitor.id) }),
                isEnabled: monitor.isAdjustable
            ) {
                if let connection {
                    Label(connection, systemImage: monitor.intermediary == .dock ? "dock.rectangle" : "cable.connector")
                }
            }
            if monitor.usesSoftwareDimming {
                dimmingPicker
            }
            switch monitor.state {
            case .probing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Frage Monitor per DDC/CI ab …")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case _ where monitor.usesSoftwareDimming:
                #if SCREENDIM_DIRECT
                hint(softwareReason, systemImage: "circle.lefthalf.filled", color: .secondary, retry: true)
                #else
                // Ohne DDC ist Software-Dimmung der Normalfall; der Hinweis steht einmal unten.
                EmptyView()
                #endif
            case _ where monitor.isBuiltIn && monitor.state.isFailure:
                hint("Helligkeit lässt sich gerade nicht lesen oder setzen.", retry: true)
            default:
                // Displays ohne Kanal und externe mit DDC-Fehler laufen per Software-Dimmung (oben).
                EmptyView()
            }
        }
    }

    /// Gamma oder Overlay. Geht Gamma bei diesem Display nicht, dimmt das Overlay.
    private var dimmingPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Abdunkeln über", selection: Binding(
                get: { monitor.dimming },
                set: { manager.setDimmingMethod($0, for: monitor.id) }
            )) {
                Text("Gamma").tag(DimmingMethod.gamma)
                Text("Overlay").tag(DimmingMethod.overlay)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .help("Gamma skaliert die Farbkurve des Displays. Overlay legt ein halbtransparentes Fenster darüber.")
            if monitor.gammaUnavailable {
                Text("Gamma-Tabelle nicht nutzbar, Overlay aktiv.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// „Über Dock (Realtek)“; `nil` bei direktem Anschluss.
    private var connection: LocalizedStringKey? {
        guard let intermediary = monitor.intermediary else { return nil }
        return switch (intermediary, monitor.branchVendor) {
        case (.dock, let vendor?): "Über Dock (\(vendor))"
        case (.dock, nil): "Über Dock"
        case (.adapter, let vendor?): "Über Adapter (\(vendor))"
        case (.adapter, nil): "Über Adapter"
        }
    }

    #if SCREENDIM_DIRECT
    private var softwareReason: LocalizedStringKey {
        if monitor.isBuiltIn {
            return "macOS erlaubt für dieses Display keine Helligkeitssteuerung. Software-Dimmung aktiv."
        }
        return switch (monitor.intermediary, monitor.state) {
        case (.dock, _): "DDC kommt über das Dock nicht durch. Software-Dimmung aktiv."
        case (.adapter, _): "DDC kommt über den Adapter nicht durch. Software-Dimmung aktiv."
        case (nil, .nullReply): "Monitor antwortet leer – DDC/CI im Monitor-Menü aus? Software-Dimmung aktiv."
        case (nil, .i2cTimeout): "DDC-Verbindung blockiert. Software-Dimmung aktiv."
        case (nil, .ioError(let status)): "I2C-Fehler \(IOReturnDescription.name(status)). Software-Dimmung aktiv."
        case (nil, .noChannel): "Kein DDC-Kanal gefunden. Software-Dimmung aktiv."
        case (nil, _): "Monitor reagiert nicht auf DDC/CI. Software-Dimmung aktiv."
        }
    }
    #endif

    private func hint(
        _ text: LocalizedStringKey,
        systemImage: String = "exclamationmark.triangle.fill",
        color: Color = .orange,
        retry: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if retry {
                Button("Erneut prüfen") { manager.retry(monitor.id) }
                    .buttonStyle(.link)
                    .padding(.leading, 18)
            }
        }
        .font(.caption)
    }
}

/// Kopf mit rundem Symbol, Name und Wert, darunter der Regler zwischen zwei Sonnen.
private struct BrightnessSlider<Subtitle: View>: View {
    /// Schon lokalisiert bzw. Monitorname.
    let title: String
    let systemImage: String
    @Binding var value: Double
    let isEnabled: Bool
    @ViewBuilder var subtitle: Subtitle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 26, height: 26)
                    .background(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(verbatim: "\(Int(value)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...100, step: 1) {
                Text("Helligkeit \(title)")
            } minimumValueLabel: {
                Image(systemName: "sun.min")
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
            }
            .labelsHidden()
        }
        .disabled(!isEnabled)
    }
}

extension BrightnessSlider where Subtitle == EmptyView {
    init(title: String, systemImage: String, value: Binding<Double>, isEnabled: Bool) {
        self.init(title: title, systemImage: systemImage, value: value, isEnabled: isEnabled) { EmptyView() }
    }
}

// MARK: - Menü-Bausteine

private enum MenuMetrics {
    /// Einzug des Titels einer Menüzeile (Rand, Symbolspalte, Abstand), für Zeilen darunter.
    static let textInset: CGFloat = 8 + 20 + 6
}

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
        .padding(.vertical, 5)
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

private extension View {
    /// Karte wie ein Modul im Kontrollzentrum.
    func menuCard() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }
}
