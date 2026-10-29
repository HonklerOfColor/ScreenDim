import ScreenDimKit
import SwiftUI

struct MenuContentView: View {
    let manager: DisplayManager
    let sensor: SensorController
    let loginItem: LoginItem
    @Environment(\.openSettings) private var openSettings
    #if SCREENDIM_DIRECT
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sensor.isDemoActive {
                HStack(spacing: 6) {
                    Image(systemName: "theatermasks.fill")
                    Text("Demo-Modus aktiv")
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Beenden") { sensor.setDemoActive(false) }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .padding(6)
                .background(.yellow.opacity(0.35), in: .rect(cornerRadius: 6))
            }

            if manager.monitors.isEmpty {
                Label("Kein Display gefunden", systemImage: "display.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                if manager.monitors.count > 1 {
                    BrightnessSlider(
                        title: String(localized: "Alle Monitore"),
                        systemImage: "sun.max.fill",
                        value: Binding(get: { manager.masterBrightness }, set: { manager.setAllBrightness($0) }),
                        isEnabled: manager.monitors.contains(where: \.isAdjustable)
                    )
                    .fontWeight(.semibold)
                    Divider()
                }
                ForEach(manager.monitors) { monitor in
                    MonitorRow(monitor: monitor, manager: manager)
                }
            }

            #if !SCREENDIM_DIRECT
            if manager.monitors.contains(where: \.usesSoftwareDimming) {
                Text("Diese Version dimmt externe Monitore per Software. Die Hintergrundbeleuchtung bleibt, wie sie ist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif

            if sensor.isEnabled && !sensor.isDemoActive {
                HStack(spacing: 6) {
                    Text("Sensor:")
                    SensorStatusLabel(sensor: sensor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Bei Login starten", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .toggleStyle(.checkbox)
                if loginItem.needsApproval {
                    Button("In den Systemeinstellungen erlauben …") { loginItem.openSystemSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if let error = loginItem.lastError {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                }
                Group {
                    if manager.hotKeysAvailable {
                        Text("⌃⌥↑ / ⌃⌥↓  alle Monitore ±\(Int(DisplayManager.hotKeyStep).formatted()) %")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tastenkürzel ⌃⌥↑/↓ sind von einer anderen App belegt")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            HStack {
                Button("Einstellungen …") { showSettings() }
                Spacer()
                Button("Schreibtisch-Sensor einrichten …") { showSettings() }
                    .buttonStyle(.link)
                    .help("Hilfe: optionalen Anwesenheits- und Lichtsensor koppeln oder den Demo-Modus testen")
            }
            .font(.caption)

            HStack {
                Button("Monitore neu suchen") { manager.refresh(force: true) }
                #if SCREENDIM_DIRECT
                Button("Diagnose …") {
                    openWindow(id: DiagnosticsView.windowID)
                    NSApplication.shared.activate()
                }
                #endif
                Spacer()
                Button("Beenden") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            loginItem.reload()
            Task { await manager.syncBuiltInBrightness() }
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
        VStack(alignment: .leading, spacing: 4) {
            BrightnessSlider(
                title: monitor.name,
                systemImage: monitor.isBuiltIn ? "laptopcomputer" : "display",
                value: Binding(get: { monitor.brightness }, set: { manager.setBrightness($0, for: monitor.id) }),
                isEnabled: monitor.isAdjustable
            )
            if let connection {
                Label(connection, systemImage: monitor.intermediary == .dock ? "dock.rectangle" : "cable.connector")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if monitor.usesSoftwareDimming && !monitor.isBuiltIn {
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
            case .noChannel where monitor.isBuiltIn:
                #if SCREENDIM_DIRECT
                hint("macOS erlaubt für dieses Display keine Helligkeitssteuerung.", retry: false)
                #else
                hint("Die Helligkeit des eingebauten Displays regelst du mit den Helligkeitstasten.",
                     systemImage: "info.circle", color: .secondary, retry: false)
                #endif
            default:
                // Externe Monitore mit DDC-Fehler laufen per Software-Dimmung (oben).
                EmptyView()
            }
        }
    }

    /// Gamma oder Overlay. Geht Gamma bei diesem Display nicht, dimmt das Overlay.
    private var dimmingPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        switch (monitor.intermediary, monitor.state) {
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            if retry {
                Spacer(minLength: 4)
                Button("Erneut prüfen") { manager.retry(monitor.id) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
    }
}

private struct BrightnessSlider: View {
    /// Schon lokalisiert bzw. Monitorname.
    let title: String
    let systemImage: String
    @Binding var value: Double
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                Spacer()
                Text(verbatim: "\(Int(value)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...100, step: 1)
                .accessibilityLabel(Text("Helligkeit \(title)"))
        }
        .disabled(!isEnabled)
    }
}
