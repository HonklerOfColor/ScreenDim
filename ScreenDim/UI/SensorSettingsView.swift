import ScreenDimKit
import SwiftUI

/// Einstellungsfenster. Bisher nur der Abschnitt „Sensor“.
struct SettingsView: View {
    let sensor: SensorController

    var body: some View {
        Form {
            if sensor.isDemoActive {
                DemoBanner(sensor: sensor)
            }
            SensorSection(sensor: sensor)
            DemoSection(sensor: sensor)
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Link("Bau dir deinen eigenen Sensor (ca. 30 €, 15 min)", destination: SensorLinks.flashPage)
                    Text("Die Hardware ist nicht im Kauf enthalten. Der Sensor ist optional; ScreenDim funktioniert vollständig ohne ihn.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420)
    }
}

private struct DemoBanner: View {
    let sensor: SensorController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks.fill")
            Text("Demo-Modus aktiv: Anwesenheit und Licht sind simuliert.")
                .fontWeight(.semibold)
            Spacer()
            Button("Beenden") { sensor.setDemoActive(false) }
        }
        .padding(8)
        .background(.yellow.opacity(0.35), in: .rect(cornerRadius: 6))
    }
}

private struct SensorSection: View {
    let sensor: SensorController
    @State private var browser = SensorBrowser()

    private var needsPairing: Bool {
        sensor.isEnabled && !sensor.isDemoActive && (sensor.pairedHostname == nil || sensor.status == .pairingRequired)
    }

    var body: some View {
        Section("Sensor") {
            Toggle("Schreibtisch-Sensor verwenden", isOn: Binding(get: { sensor.isEnabled }, set: { sensor.setEnabled($0) }))
                .disabled(sensor.isDemoActive)
            if sensor.isDemoActive {
                Text("Während des Demo-Modus ist der echte Sensor getrennt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if sensor.isEnabled {
                if let host = sensor.pairedHostname {
                    LabeledContent("Gekoppelt mit") {
                        Text(verbatim: host).textSelection(.enabled)
                    }
                    LabeledContent("Status") { SensorStatusLabel(sensor: sensor) }
                    if sensor.status == .connected {
                        SensorReadings(sensor: sensor)
                        Toggle("Helligkeit ans Umgebungslicht anpassen", isOn: Binding(
                            get: { sensor.adjustsBrightness }, set: { sensor.adjustsBrightness = $0 }
                        ))
                    }
                    Button("Entkoppeln", role: .destructive) { sensor.unpair() }
                }
                if needsPairing {
                    PairingView(sensor: sensor, browser: browser)
                }
            }
        }
        .onChange(of: needsPairing, initial: true) { _, needed in
            if needed { browser.start() } else { browser.stop() }
        }
        .onDisappear { browser.stop() }
    }
}

struct SensorStatusLabel: View {
    let sensor: SensorController

    var body: some View {
        switch sensor.status {
        case .off: Label("Aus", systemImage: "circle")
        case .demo: Label("Demo-Modus aktiv", systemImage: "theatermasks.fill").foregroundStyle(.orange)
        case .notPaired: Label("Nicht gekoppelt", systemImage: "link.badge.plus")
        case .searching: Label("Suche …", systemImage: "antenna.radiowaves.left.and.right")
        case .connected: Label("Verbunden", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .pairingRequired:
            Label("Kopplung verloren – neu koppeln", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct SensorReadings: View {
    let sensor: SensorController

    var body: some View {
        LabeledContent("Anwesenheit") {
            switch sensor.presence {
            case true?: Text("Da")
            case false?: Text("Weg")
            case nil: Text(verbatim: "–")
            }
        }
        LabeledContent("Umgebungslicht") {
            if let lux = sensor.lux {
                Text("\(Int(lux.rounded())) lx").monospacedDigit()
            } else {
                Text(verbatim: "–")
            }
        }
    }
}

/// Liste gefundener Sensoren und der Ablauf der Kopplung.
private struct PairingView: View {
    let sensor: SensorController
    let browser: SensorBrowser
    @State private var manualCode = ""
    @State private var manualCodeInvalid = false

    var body: some View {
        if browser.isLocalNetworkDenied {
            Label("Kein Zugriff aufs lokale Netzwerk. Erlaube ihn unter Systemeinstellungen › Datenschutz & Sicherheit › Lokales Netzwerk.",
                  systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if browser.sensors.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Suche Sensoren im Netzwerk …").foregroundStyle(.secondary)
            }
        }
        ForEach(browser.sensors) { found in
            HStack {
                VStack(alignment: .leading) {
                    Text(verbatim: found.name)
                    Text(verbatim: [found.hostname, found.firmware.map { "fw \($0)" }].compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if sensor.pairing.sensor == found {
                    Button("Abbrechen") { sensor.cancelPairing() }
                } else {
                    Button("Koppeln") {
                        manualCode = ""
                        manualCodeInvalid = false
                        sensor.beginPairing(with: found)
                    }
                }
            }
        }
        pairingState
    }

    @ViewBuilder
    private var pairingState: some View {
        switch sensor.pairing {
        case .idle:
            EmptyView()
        case .requesting:
            progress("Frage den Sensor nach dem Code …")
        case .waitingForButton:
            Label("Drück kurz die BOOT-Taste am Sensor (LED blinkt).", systemImage: "hand.point.up.left.fill")
            progress("Warte auf den Sensor …")
        case .verifying:
            progress("Prüfe den Code …")
        case .failed(_, let failure):
            Label(failureText(failure), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let found = sensor.pairing.sensor {
                Button("Erneut versuchen") { sensor.beginPairing(with: found) }
            }
        }
        if sensor.pairing.acceptsManualCode {
            HStack {
                TextField("Code, z. B. ABCD-EFGH", text: $manualCode)
                    .font(.body.monospaced())
                    .onSubmit(submit)
                    .onChange(of: manualCode) { manualCodeInvalid = false }
                Button("Prüfen", action: submit)
                    .disabled(manualCode.isEmpty)
            }
            if manualCodeInvalid {
                Text("Der Code hat 8 Zeichen aus 0–9 und A–Z (ohne I, L, O, U).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func submit() {
        manualCodeInvalid = !sensor.submitCode(manualCode)
    }

    private func progress(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func failureText(_ failure: SensorController.PairingFailure) -> LocalizedStringKey {
        switch failure {
        case .wrongCode: "Falscher Code."
        case .timeout: "Der Sensor antwortet nicht (Zeitüberschreitung)."
        case .unreachable: "Sensor nicht erreichbar. Ist er im selben WLAN?"
        case .noCodeReceived: "Kein Code erhalten. Drück kurz BOOT und versuch es erneut oder gib den Code ein."
        case .keychain(let status): "Code ließ sich nicht im Schlüsselbund sichern (\(Int(status)))."
        }
    }
}

private struct DemoSection: View {
    let sensor: SensorController

    var body: some View {
        Section {
            Toggle("Demo-Modus (simulierter Sensor)", isOn: Binding(get: { sensor.isDemoActive }, set: { sensor.setDemoActive($0) }))
            Text("Simuliert Anwesenheit und Umgebungslicht, ganz ohne Hardware. Ist nach dem nächsten Start wieder aus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if sensor.isDemoActive {
                SensorReadings(sensor: sensor)
                HStack {
                    Button("Simulieren: weg") { sensor.simulateAway() }
                    Button("Simulieren: zurück") { sensor.simulateBack() }
                }
                Text("Die Bildschirme gehen nach 3 s aus. Maus oder Tastatur weckt sie sofort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Licht von Hand", isOn: Binding(
                    get: { sensor.demoLux != nil },
                    set: { sensor.setDemoLux($0 ? sensor.lux ?? 300 : nil) }
                ))
                if let lux = sensor.demoLux {
                    Slider(value: Binding(get: { lux }, set: { sensor.setDemoLux($0.rounded()) }), in: 0...1000) {
                        Text("Lux")
                    }
                }
                Stepper(value: schedule(\.presentFor), in: 5...300, step: 5) {
                    Text("Da: \(seconds(sensor.demoSchedule.presentFor)) s")
                }
                Stepper(value: schedule(\.awayFor), in: 5...300, step: 1) {
                    Text("Weg: \(seconds(sensor.demoSchedule.awayFor)) s")
                }
            }
        }
    }

    private func schedule(_ keyPath: WritableKeyPath<SimulationSchedule, Duration>) -> Binding<Int> {
        Binding(
            get: { seconds(sensor.demoSchedule[keyPath: keyPath]) },
            set: { value in
                var schedule = sensor.demoSchedule
                schedule[keyPath: keyPath] = .seconds(value)
                sensor.setDemoSchedule(schedule)
            }
        )
    }

    private func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }
}
