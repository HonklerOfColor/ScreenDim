import SwiftUI

struct MenuContentView: View {
    let manager: DisplayManager
    let loginItem: LoginItem

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
            switch monitor.state {
            case .ready:
                EmptyView()
            case .probing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Frage Monitor per DDC/CI ab …")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .noResponse where monitor.isBuiltIn:
                hint("Helligkeit lässt sich gerade nicht lesen oder setzen.", retry: true)
            case .noResponse:
                hint("Monitor antwortet nicht. DDC/CI im Monitor-Menü aktivieren.", retry: true)
            case .noChannel where monitor.isBuiltIn:
                hint("macOS erlaubt für dieses Display keine Helligkeitssteuerung.", retry: false)
            case .noChannel:
                hint("Kein DDC-Kanal gefunden. Adapter oder Dock lassen DDC evtl. nicht durch.", retry: false)
            }
        }
    }

    private func hint(_ text: String, retry: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
