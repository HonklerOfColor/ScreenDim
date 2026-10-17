import SwiftUI

struct MenuContentView: View {
    let manager: DisplayManager
    let loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.monitors.isEmpty {
                Label("Kein Display gefunden", systemImage: "display.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                if manager.monitors.count > 1 {
                    BrightnessSlider(
                        title: "Alle Monitore",
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
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text(manager.hotKeysAvailable
                     ? "⌃⌥↑ / ⌃⌥↓  alle Monitore ±\(Int(DisplayManager.hotKeyStep)) %"
                     : "Tastenkürzel ⌃⌥↑/↓ sind von einer anderen App belegt")
                    .font(.caption)
                    .foregroundStyle(manager.hotKeysAvailable ? Color.secondary : Color.orange)
            }

            HStack {
                Button("Monitore neu suchen") { manager.refresh(force: true) }
                Button("Diagnose …") {
                    openWindow(id: DiagnosticsView.windowID)
                    NSApplication.shared.activate()
                }
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
            switch monitor.state {
            case .probing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Frage Monitor per DDC/CI ab …")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case _ where monitor.usesSoftwareDimming:
                hint("\(softwareReason) Software-Dimmung aktiv.", systemImage: "circle.lefthalf.filled", color: .secondary, retry: true)
            case _ where monitor.isBuiltIn && monitor.state.isFailure:
                hint("Helligkeit lässt sich gerade nicht lesen oder setzen.", retry: true)
            case .noChannel where monitor.isBuiltIn:
                hint("macOS erlaubt für dieses Display keine Helligkeitssteuerung.", retry: false)
            default:
                // Externe Monitore mit DDC-Fehler laufen per Software-Dimmung (oben).
                EmptyView()
            }
        }
    }

    /// „Über Dock (Realtek)“; `nil` bei direktem Anschluss.
    private var connection: String? {
        guard let intermediary = monitor.intermediary else { return nil }
        let vendor = monitor.branchVendor.map { " (\($0))" } ?? ""
        return switch intermediary {
        case .dock: "Über Dock\(vendor)"
        case .adapter: "Über Adapter\(vendor)"
        }
    }

    private var softwareReason: String {
        switch (monitor.intermediary, monitor.state) {
        case (.dock, _): "DDC kommt über das Dock nicht durch."
        case (.adapter, _): "DDC kommt über den Adapter nicht durch."
        case (nil, .nullReply): "Monitor antwortet leer – DDC/CI im Monitor-Menü aus?"
        case (nil, .i2cTimeout): "DDC-Verbindung blockiert."
        case (nil, .ioError(let status)): "I2C-Fehler \(IOReturnDescription.name(status))."
        case (nil, .noChannel): "Kein DDC-Kanal gefunden."
        case (nil, _): "Monitor reagiert nicht auf DDC/CI."
        }
    }

    private func hint(_ text: String, systemImage: String = "exclamationmark.triangle.fill", color: Color = .orange, retry: Bool) -> some View {
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
                Text("\(Int(value)) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...100, step: 1)
                .accessibilityLabel("Helligkeit \(title)")
        }
        .disabled(!isEnabled)
    }
}
