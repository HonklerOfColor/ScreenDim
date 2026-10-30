import Charts
import ScreenDimKit
import SwiftUI

/// Einstellungsfenster in zwei Tabs: „Sensor“ (Kopplung, Demo, Diagnose) und
/// „Helligkeit“ (Lichtquelle, Kurven je Monitor). Jeder Tab ist so hoch wie sein Inhalt,
/// gescrollt wird nicht.
struct SettingsView: View {
    let sensor: SensorController
    let manager: DisplayManager

    var body: some View {
        TabView {
            Tab("Sensor", systemImage: "sensor") {
                SettingsPage(sensor: sensor) {
                    SensorSection(sensor: sensor)
                    DemoSection(sensor: sensor)
                    DiagnosticsSection()
                    BuildYourOwnSection()
                }
            }
            Tab("Helligkeit", systemImage: "sun.max") {
                SettingsPage(sensor: sensor) {
                    LightSection(sensor: sensor)
                    if showsLightCurves {
                        LightCurveSection(sensor: sensor, manager: manager)
                    } else {
                        Section {
                            Text("Schalte den Schreibtisch-Sensor oder den Demo-Modus ein, dann regelt das Umgebungslicht die Helligkeit jedes Monitors.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        // Auto-Helligkeit frisch lesen, damit der Hinweis zum Display stimmt.
        .onAppear { sensor.refreshAutoBrightness() }
    }

    /// Kurven nur, wenn überhaupt Licht kommen kann.
    private var showsLightCurves: Bool {
        sensor.effectiveLightSource != .off
            && (sensor.isEnabled || sensor.isDemoActive || sensor.hasBuiltInLightSensor)
    }
}

/// Ein Tab: Formular in fester Breite und so hoch wie sein Inhalt; oben der Hinweis auf den
/// Demo-Modus, solange er läuft.
private struct SettingsPage<Content: View>: View {
    let sensor: SensorController
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            if sensor.isDemoActive {
                DemoBanner(sensor: sensor)
            }
            content
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 500)
    }
}

private struct DiagnosticsSection: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            HStack {
                Text("Messwerte und aktive Quellen live ansehen")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sensor-Diagnose …") {
                    openWindow(id: SensorDebugView.windowID)
                    NSApplication.shared.activate()
                }
            }
        }
    }
}

private struct BuildYourOwnSection: View {
    var body: some View {
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

/// Woher das Licht für die Helligkeit kommt, mit Vorrang und Rückfall. Ohne Lichtsensor im
/// Mac bleibt nur Schreibtisch-Sensor oder aus; die Wahl erscheint dann erst mit
/// verbundenem Sensor.
private struct LightSection: View {
    let sensor: SensorController

    private var deskSensorConnected: Bool {
        sensor.isEnabled && !sensor.isDemoActive && sensor.status == .connected
    }

    private var showsChoice: Bool {
        sensor.hasBuiltInLightSensor || deskSensorConnected
    }

    var body: some View {
        #if SCREENDIM_DIRECT
        if showsChoice { section }
        #else
        // App Store: Der Hinweis auf den eingebauten Sensor steht auch ohne Schreibtisch-Sensor.
        section
        #endif
    }

    private var section: some View {
        Section("Umgebungslicht") {
            if showsChoice {
                Picker("Helligkeit anpassen nach", selection: Binding(
                    get: { sensor.effectiveLightSource }, set: { sensor.setLightSource($0) }
                )) {
                    ForEach(sensor.availableLightSources, id: \.self) { source in
                        Text(lightSourceName(source, hasBuiltIn: sensor.hasBuiltInLightSensor)).tag(source)
                    }
                }
                if sensor.effectiveLightSource != .off {
                    activeStatus
                }
            }
            #if !SCREENDIM_DIRECT
            caption("Nur in ScreenDim Direct verfügbar – der App Store erlaubt keinen Zugriff auf den Lichtsensor.")
            #endif
        }
    }

    /// „Aktiv: …“ und, wenn nötig, warum.
    @ViewBuilder
    private var activeStatus: some View {
        LabeledContent("Aktiv") {
            switch sensor.activeLightOrigin {
            case .deskSensor?: Text("Schreibtisch-Sensor")
            case .builtIn?: Text("Eingebauter Lichtsensor")
            case .demo?: Text("Demo-Modus (simuliert)")
            case nil: Text("Keine Quelle").foregroundStyle(.secondary)
            }
        }
        if sensor.isDemoActive {
            caption("Während des Demo-Modus kommt das Licht aus der Simulation.")
        } else if sensor.isLightFallback {
            switch sensor.activeLightOrigin {
            case .builtIn?: reason("\(Text(deskSensorReason)) – der eingebaute Sensor springt ein.")
            case .deskSensor?: reason("\(Text(builtInReason)) – der Schreibtisch-Sensor springt ein.")
            default: EmptyView()
            }
        } else if sensor.activeLightOrigin == nil {
            ForEach(sensor.effectiveLightSource.order, id: \.self) { origin in
                reason(origin == .builtIn ? builtInReason : deskSensorReason)
            }
        } else if sensor.activeLightOrigin == .builtIn, let lux = sensor.builtInLux {
            LabeledContent("Umgebungslicht") {
                Text("\(Int(lux.rounded())) lx").monospacedDigit()
            }
        }
    }

    private var deskSensorReason: LocalizedStringKey {
        if !sensor.isEnabled { return "Schreibtisch-Sensor aus" }
        if sensor.status != .connected { return "Schreibtisch-Sensor getrennt" }
        return "Schreibtisch-Sensor meldet kein Licht"
    }

    private var builtInReason: LocalizedStringKey {
        sensor.isBuiltInLightSensorCovered ? "Deckel zu" : "Eingebauter Sensor meldet nichts"
    }

    private func reason(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Name einer Lichtquellen-Wahl. Ohne eingebauten Sensor gibt es keinen Rückfall, dann
/// heißt „nur Schreibtisch-Sensor“ schlicht so.
func lightSourceName(_ source: SensorController.LightSource, hasBuiltIn: Bool) -> LocalizedStringKey {
    switch source {
    case .deskSensorFirst: "Schreibtisch-Sensor, sonst eingebauter"
    case .builtInFirst: "Eingebauter Sensor, sonst Schreibtisch-Sensor"
    case .deskSensorOnly: hasBuiltIn ? "Nur Schreibtisch-Sensor" : "Schreibtisch-Sensor"
    case .builtInOnly: "Nur eingebauter Lichtsensor"
    case .off: "Aus"
    }
}

// MARK: - Helligkeit je Monitor
/// Bei welchem Umgebungslicht welcher Monitor wie hell ist. Jeder Monitor hat eine eigene
/// Kurve aus Stützpunkten; zwischen den Punkten gleitet die Helligkeit.
struct LightCurveSection: View {
    let sensor: SensorController
    let manager: DisplayManager
    @State private var selectedKey: String?

    private var monitor: DisplayManager.Monitor? {
        manager.monitors.first { $0.storageKey == selectedKey } ?? manager.monitors.first
    }

    var body: some View {
        Section("Helligkeit je Monitor") {
            if let monitor {
                if manager.monitors.count > 1 {
                    Picker("Monitor", selection: Binding(get: { monitor.storageKey }, set: { selectedKey = $0 })) {
                        ForEach(manager.monitors) { monitor in
                            Text(verbatim: displayName(monitor)).tag(monitor.storageKey)
                        }
                    }
                }
                LightProfileEditor(sensor: sensor, monitor: monitor)
            } else {
                Text("Kein Monitor gefunden.").foregroundStyle(.secondary)
            }
        }
    }

    /// Zwei gleiche Monitore heißen gleich; dann hilft die Nummer.
    private func displayName(_ monitor: DisplayManager.Monitor) -> String {
        let twins = manager.monitors.filter { $0.name == monitor.name }
        guard twins.count > 1, let index = twins.firstIndex(of: monitor) else { return monitor.name }
        return "\(monitor.name) (\(index + 1))"
    }
}

private struct LightProfileEditor: View {
    let sensor: SensorController
    let monitor: DisplayManager.Monitor

    private var profile: LightProfile { sensor.lightProfile(for: monitor) }

    /// macOS regelt dieses Display: ScreenDim lässt es dann aus, damit nur einer schreibt.
    /// Unbekannt zählt wie bei der Regelung als „nein“; dann entscheidet das Profil.
    private var macOSRegulates: Bool {
        monitor.isBuiltIn && !monitor.usesSoftwareDimming && sensor.isMacOSAutoBrightnessEnabled == true
    }

    var body: some View {
        Toggle("Folgt dem Umgebungslicht", isOn: Binding(
            get: { profile.followsLight }, set: { value in update { $0.followsLight = value } }
        ))
        if macOSRegulates {
            HStack(alignment: .firstTextBaseline) {
                caption("macOS regelt dieses Display selbst. Schalte „Helligkeit automatisch anpassen“ aus, wenn ScreenDim es regeln soll.")
                Spacer()
                Button("Displays …") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
            }
        }
        if profile.followsLight {
            LightCurveChart(curve: profile.curve, lux: sensor.activeLux, current: monitor.brightness)
                .frame(height: 150)
                .padding(.vertical, 4)
            ForEach(Array(profile.curve.points.enumerated()), id: \.offset) { index, point in
                PointRow(
                    point: point,
                    canRemove: profile.curve.points.count > 1,
                    onChange: { new in update { $0.curve.setPoint(new, at: index) } },
                    onRemove: { update { $0.curve.removePoint(at: index) } }
                )
            }
            HStack {
                Button("Punkt hinzufügen") {
                    if let point = profile.curve.suggestedPoint() { update { $0.curve.insert(point) } }
                }
                .disabled(profile.curve.suggestedPoint() == nil)
                if let lux = sensor.activeLux, monitor.isAdjustable {
                    Button("Aktuelle Helligkeit merken") {
                        update { $0.curve.insert(LightCurve.Point(lux: lux, percent: monitor.brightness)) }
                    }
                    .help("Legt einen Punkt an: \(Int(lux.rounded())) lx → \(Int(monitor.brightness)) %")
                    .disabled(profile.curve.points.count >= LightCurve.maxPoints
                        && !profile.curve.points.contains { $0.lux == lux.rounded() })
                }
                Spacer()
                Button("Standard") { update { $0.curve = .standard } }
                    .disabled(profile.curve == .standard)
            }
            caption("Zwischen zwei Punkten gleitet die Helligkeit, unter dem ersten und über dem letzten bleibt sie stehen. Höchstens \(LightCurve.maxPoints) Punkte.")
        }
    }

    private func update(_ change: (inout LightProfile) -> Void) {
        var profile = profile
        change(&profile)
        sensor.setLightProfile(profile, for: monitor)
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ein Stützpunkt: Lux als Zahl, Helligkeit per Slider.
private struct PointRow: View {
    let point: LightCurve.Point
    let canRemove: Bool
    let onChange: (LightCurve.Point) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Lux", value: Binding(
                get: { point.lux }, set: { onChange(LightCurve.Point(lux: $0, percent: point.percent)) }
            ), format: .number.precision(.fractionLength(0)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text("lx").foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Slider(value: Binding(
                get: { point.percent }, set: { onChange(LightCurve.Point(lux: point.lux, percent: $0)) }
            ), in: 0...100) {
                Text("Helligkeit")
            }
            .labelsHidden()
            Text("\(Int(point.percent)) %")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Punkt entfernen")
        }
    }
}

/// Die Kurve auf logarithmischer Lux-Achse, dazu das aktuelle Licht.
private struct LightCurveChart: View {
    let curve: LightCurve
    let lux: Double?
    let current: Double

    private static let luxRange: ClosedRange<Double> = 1...LightCurve.maxLux

    /// 20 Werte je Zehnerpotenz.
    private var samples: [(lux: Double, percent: Double)] {
        stride(from: 0.0, through: 5, by: 0.05).map { exponent in
            let lux = pow(10, exponent)
            return (lux, curve.percent(forLux: lux))
        }
    }

    var body: some View {
        Chart {
            ForEach(samples, id: \.lux) { sample in
                LineMark(x: .value("Lux", sample.lux), y: .value("Helligkeit", sample.percent))
            }
            ForEach(Array(curve.points.enumerated()), id: \.offset) { _, point in
                PointMark(x: .value("Lux", max(point.lux, 1)), y: .value("Helligkeit", point.percent))
                    .symbolSize(50)
            }
            if let lux {
                RuleMark(x: .value("Lux", min(max(lux, 1), LightCurve.maxLux)))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("\(Int(lux.rounded())) lx · \(Int(current)) %")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
            }
        }
        .chartXScale(domain: Self.luxRange, type: .log)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [1, 10, 100, 1000, 10_000, 100_000]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let lux = value.as(Double.self) {
                        Text("\(Int(lux)) lx")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent)) %")
                    }
                }
            }
        }
    }
}

// MARK: - Sensor

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
