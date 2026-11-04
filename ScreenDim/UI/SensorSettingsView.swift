import Charts
import ScreenDimKit
import SwiftUI

/// Einstellungsfenster in drei Tabs: „Allgemein“ (Login, Tastenkürzel, Leerlauf, Monitore),
/// „Sensor“ (Kopplung, Demo, Diagnose) und „Licht“ (Umgebungslicht, Kurven je Monitor).
/// Jeder Tab ist so hoch wie sein Inhalt, gescrollt wird nicht.
struct SettingsView: View {
    let sensor: SensorController
    let manager: DisplayManager
    let idle: IdleDimmer
    let loginItem: LoginItem

    var body: some View {
        TabView {
            Tab("Allgemein", systemImage: "gearshape") {
                SettingsPage(sensor: sensor) {
                    LoginSection(loginItem: loginItem)
                    ShortcutSection(manager: manager)
                    IdleSection(idle: idle)
                    MonitorSection(manager: manager)
                }
            }
            Tab("Sensor", systemImage: "sensor") {
                SettingsPage(sensor: sensor) {
                    SensorSection(sensor: sensor)
                    if sensor.isEnabled || sensor.isDemoActive {
                        AbsenceSection(sensor: sensor)
                    }
                    DemoSection(sensor: sensor)
                    DiagnosticsSection()
                    BuildYourOwnSection()
                }
            }
            Tab("Licht", systemImage: "sun.max") {
                SettingsPage(sensor: sensor) {
                    LightSection(sensor: sensor)
                    if showsLightCurves {
                        LightCurveSection(sensor: sensor, manager: manager)
                    }
                }
            }
        }
        // Auto-Helligkeit frisch lesen, damit der Hinweis zum Display stimmt.
        .onAppear {
            loginItem.reload()
            sensor.refreshAutoBrightness()
        }
    }

    /// Kurven nur, wenn überhaupt Licht kommen kann.
    private var showsLightCurves: Bool {
        sensor.effectiveLightSource != .off && (sensor.isEnabled || sensor.isDemoActive)
    }
}

// MARK: - Allgemein

private struct LoginSection: View {
    let loginItem: LoginItem

    var body: some View {
        Section {
            Toggle("Bei Login starten", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
            if loginItem.needsApproval {
                HStack {
                    Text("Der Start wartet auf deine Erlaubnis in den Systemeinstellungen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Anmeldeobjekte …") { loginItem.openSystemSettings() }
                }
            }
            if let error = loginItem.lastError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ShortcutSection: View {
    let manager: DisplayManager

    var body: some View {
        Section("Tastenkürzel") {
            LabeledContent("Alle Monitore heller") { Text(verbatim: "⌃⌥↑") }
            LabeledContent("Alle Monitore dunkler") { Text(verbatim: "⌃⌥↓") }
            if manager.hotKeysAvailable {
                Text("Jeder Druck ändert die Helligkeit um \(Int(DisplayManager.hotKeyStep)) %.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Die Kürzel sind von einer anderen App belegt.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Abdunkeln nach einer Weile ohne Maus und Tastatur: Wartezeit und Helligkeit.
private struct IdleSection: View {
    let idle: IdleDimmer

    var body: some View {
        Section("Bei Inaktivität") {
            Toggle("Bildschirme abdunkeln, wenn du nichts tust", isOn: Binding(
                get: { idle.isEnabled }, set: { idle.setEnabled($0) }
            ))
            if idle.isEnabled {
                Picker("Nach", selection: Binding(
                    get: { idle.timeoutMinutes }, set: { idle.setTimeout(.seconds($0 * 60)) }
                )) {
                    ForEach(IdleDimmer.timeoutChoices, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                LabeledContent("Helligkeit") {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(get: { idle.level }, set: { idle.setLevel($0) }),
                            in: IdleDimmer.levelRange
                        ) {
                            Text("Helligkeit")
                        }
                        .labelsHidden()
                        Text("\(Int(idle.level)) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Text("Es zählen nur Maus und Tastatur, auch während ein Video läuft. Jede Mausbewegung oder Taste bringt die Helligkeit sofort zurück. Dunklere Monitore bleiben, wie sie sind. Wann macOS die Displays ausschaltet, stellst du weiter in den Systemeinstellungen ein.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Je Monitor das Verfahren (DDC/CI, Gamma, Overlay, Ignorieren); der Hinweis dazu steht
/// einmal darunter.
private struct MonitorSection: View {
    let manager: DisplayManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            if manager.monitors.isEmpty {
                Text("Kein Display gefunden.").foregroundStyle(.secondary)
            }
            ForEach(manager.monitors) { monitor in
                MonitorRow(monitor: monitor, manager: manager)
            }
            HStack(alignment: .top) {
                Text("DDC/CI stellt die Hintergrundbeleuchtung des Monitors ein. Gamma und Overlay dimmen per Software; die Hintergrundbeleuchtung bleibt dann, wie sie ist. Die des eingebauten Displays regelst du mit den Helligkeitstasten. „Ignorieren“ nimmt einen Monitor ganz aus der Dimmung, etwa einen Beamer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Neu suchen") { manager.refresh(force: true) }
                        .help("Monitore neu suchen, z. B. nach dem Umstecken")
                    Button("Diagnose …") {
                        openWindow(id: DiagnosticsView.windowID)
                        NSApplication.shared.activate()
                    }
                    .help("DDC-Kanal, Link und die letzten I2C-Ergebnisse je Monitor")
                }
            }
        } header: {
            Text("Monitore")
        }
    }
}

private struct MonitorRow: View {
    let monitor: DisplayManager.Monitor
    let manager: DisplayManager

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if showsRetry {
                    Button("Erneut prüfen") { manager.retry(monitor.id) }
                        .controlSize(.small)
                }
                if monitor.canUseDDC || monitor.usesSoftwareDimming || monitor.isIgnored {
                    // Auch ohne nutzbare Gamma-Tabelle wählbar: „Ignorieren“ muss immer gehen,
                    // und Gamma wird bei der Wahl neu versucht.
                    Picker("Helligkeit regeln über", selection: Binding(
                        get: { monitor.preferredMethod },
                        set: { manager.setBrightnessMethod($0, for: monitor.id) }
                    )) {
                        if monitor.canUseDDC {
                            Text("DDC/CI").tag(BrightnessMethod.ddc)
                        }
                        Text("Gamma").tag(BrightnessMethod.gamma)
                        Text("Overlay").tag(BrightnessMethod.overlay)
                        Divider()
                        Text("Ignorieren").tag(BrightnessMethod.ignored)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("DDC/CI regelt die Hintergrundbeleuchtung des Monitors. Gamma skaliert die Farbkurve des Displays, Overlay legt ein halbtransparentes Fenster darüber. Ignorieren nimmt den Monitor ganz aus der Dimmung.")
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: monitor.name)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(detailIsWarning ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: monitor.isBuiltIn ? "laptopcomputer" : "display")
            }
        }
    }

    /// DDC/CI ist gewählt, kommt aber nicht durch: Die Software dimmt als Rückfall.
    private var ddcFallback: Bool {
        monitor.preferredMethod == .ddc && monitor.usesSoftwareDimming && monitor.state != .probing
    }

    private var showsRetry: Bool {
        ddcFallback || (monitor.isBuiltIn && monitor.state.isFailure)
    }

    private var detailIsWarning: Bool {
        ddcFallback || (monitor.isBuiltIn && monitor.state.isFailure) || monitor.gammaUnavailable
    }

    /// Was gerade wirkt und warum: Ignoriert, Prüfung, DDC-Rückfall, Overlay statt Gamma,
    /// Anschlussweg.
    private var detail: LocalizedStringKey? {
        if monitor.isIgnored { return "Wird nie gedimmt, auch nicht bei Inaktivität oder Abwesenheit." }
        if monitor.preferredMethod == .ddc, monitor.state == .probing { return "DDC/CI wird geprüft …" }
        if ddcFallback { return fallbackReason }
        if monitor.isBuiltIn, monitor.state.isFailure { return "Helligkeit lässt sich gerade nicht lesen oder setzen." }
        if monitor.gammaUnavailable { return "Gamma-Tabelle nicht nutzbar, Overlay aktiv." }
        guard let intermediary = monitor.intermediary else { return nil }
        return switch (intermediary, monitor.branchVendor) {
        case (.dock, let vendor?): "Über Dock (\(vendor))"
        case (.dock, nil): "Über Dock"
        case (.adapter, let vendor?): "Über Adapter (\(vendor))"
        case (.adapter, nil): "Über Adapter"
        }
    }

    private var fallbackReason: LocalizedStringKey {
        let software = monitor.dimming == .gamma ? String(localized: "Gamma dimmt") : String(localized: "Overlay dimmt")
        return switch (monitor.intermediary, monitor.state) {
        case (.dock, _): "DDC/CI kommt über das Dock nicht durch, \(software)."
        case (.adapter, _): "DDC/CI kommt über den Adapter nicht durch, \(software)."
        case (nil, .nullReply): "Monitor antwortet leer – DDC/CI im Monitor-Menü aus? \(software)."
        case (nil, .i2cTimeout): "DDC/CI-Verbindung blockiert, \(software)."
        case (nil, .ioError(let status)): "I2C-Fehler \(IOReturnDescription.name(status)), \(software)."
        case (nil, _): "Monitor reagiert nicht auf DDC/CI, \(software)."
        }
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
                DemoBanner(sensor: sensor, title: "Demo-Modus aktiv: Anwesenheit und Licht sind simuliert.")
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
                Text("Der Sensor ist optional; ScreenDim funktioniert vollständig ohne ihn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hinweis, solange der Demo-Modus läuft; im Menü und in den Einstellungen.
struct DemoBanner: View {
    let sensor: SensorController
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks.fill")
                .foregroundStyle(.orange)
            Text(title)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Beenden") { sensor.setDemoActive(false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 10))
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

/// Was passiert, wenn der Sensor niemanden meldet: erst abdunkeln, nach einer Weile die
/// Displays schlafen lassen.
private struct AbsenceSection: View {
    let sensor: SensorController

    var body: some View {
        Section("Wenn du weg bist") {
            if sensor.absenceOffDelay != .zero {
                LabeledContent("Abdunkeln auf") {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(get: { sensor.absenceLevel }, set: { sensor.setAbsenceLevel($0) }),
                            in: SensorController.absenceLevelRange
                        ) {
                            Text("Abdunkeln auf")
                        }
                        .labelsHidden()
                        Text("\(Int(sensor.absenceLevel)) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Picker("Ausschalten", selection: Binding(
                get: { sensor.absenceOffMinutes },
                set: { sensor.setAbsenceOffDelay($0.map { .seconds($0 * 60) }) }
            )) {
                ForEach(SensorController.absenceOffChoices, id: \.self) { minutes in
                    Text(offChoiceName(minutes)).tag(minutes)
                }
            }
            Text("Meldet der Sensor niemanden, dunkelt ScreenDim die Bildschirme ab und schaltet sie später aus, so wie macOS nach der Zeit aus den Systemeinstellungen. Kommst du zurück, gehen sie wieder an; Maus und Tastatur holen sie jederzeit zurück. Verlangt macOS danach ein Passwort, ist der Mac gesperrt. Ist ein Monitor auf „Ignorieren“ gestellt, bleiben die Displays an und die übrigen werden schwarz.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func offChoiceName(_ minutes: Int?) -> LocalizedStringKey {
        switch minutes {
        case nil: "Nie"
        case 0?: "Sofort"
        case let minutes?: "Nach \(minutes) min"
        }
    }
}

/// Ob das Umgebungslicht die Helligkeit regelt. Ohne eingebauten Lichtsensor gibt es nur
/// den Schreibtisch-Sensor, darum ein Schalter statt einer Quellenwahl.
private struct LightSection: View {
    let sensor: SensorController

    private var hasLight: Bool { sensor.isEnabled || sensor.isDemoActive }

    var body: some View {
        Section("Umgebungslicht") {
            Toggle("Helligkeit dem Umgebungslicht anpassen", isOn: Binding(
                get: { sensor.effectiveLightSource != .off },
                set: { sensor.setLightSource($0 ? .deskSensorOnly : .off) }
            ))
            .disabled(!hasLight)
            if !hasLight {
                caption("Schalte dafür im Tab „Sensor“ den Schreibtisch-Sensor oder den Demo-Modus ein.")
            } else if sensor.effectiveLightSource != .off {
                activeStatus
            }
        }
    }

    /// Woher das Licht gerade kommt, oder warum keins kommt.
    @ViewBuilder
    private var activeStatus: some View {
        LabeledContent("Lichtquelle") {
            switch sensor.activeLightOrigin {
            case .deskSensor?: Text("Schreibtisch-Sensor")
            case .builtIn?: Text("Eingebauter Lichtsensor")
            case .demo?: Text("Demo-Modus (simuliert)")
            case nil: Text(deskSensorReason).foregroundStyle(.orange)
            }
        }
        if let lux = sensor.activeLux {
            LabeledContent("Gemessen") {
                Text("\(Int(lux.rounded())) lx").monospacedDigit()
            }
        }
    }

    private var deskSensorReason: LocalizedStringKey {
        if sensor.status != .connected { return "Schreibtisch-Sensor getrennt" }
        return "Schreibtisch-Sensor meldet kein Licht"
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
    @State private var selectedID: CGDirectDisplayID?

    /// Ignorierte Monitore folgen keinem Licht.
    private var monitors: [DisplayManager.Monitor] {
        manager.monitors.filter { !$0.isIgnored }
    }

    private var monitor: DisplayManager.Monitor? {
        monitors.first { $0.id == selectedID } ?? monitors.first
    }

    var body: some View {
        Section("Helligkeit je Monitor") {
            if let monitor {
                if monitors.count > 1 {
                    // Tag ist die Display-ID: Baugleiche Monitore teilen sich Namen und
                    // womöglich die Identität, nie die ID.
                    Picker("Monitor", selection: Binding(get: { monitor.id }, set: { selectedID = $0 })) {
                        ForEach(monitors) { monitor in
                            Text(verbatim: displayName(monitor)).tag(monitor.id)
                        }
                    }
                }
                LightProfileEditor(sensor: sensor, manager: manager, monitor: LightMonitor(monitor))
            } else if !manager.monitors.isEmpty {
                Text("Alle Monitore werden ignoriert.").foregroundStyle(.secondary)
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

/// Was der Editor über den Monitor braucht, ohne die Helligkeit: `monitors` ist als Ganzes
/// beobachtet, und jeder Überblendungsschritt (20 Hz) ändert die Helligkeit. Mit gleichen
/// Werten überspringt SwiftUI den Body samt Chart; die Helligkeit lesen nur zwei kleine
/// Unter-Views.
private struct LightMonitor: Equatable {
    let id: CGDirectDisplayID
    let storageKey: String
    let isBuiltIn: Bool
    let usesSoftwareDimming: Bool

    init(_ monitor: DisplayManager.Monitor) {
        id = monitor.id
        storageKey = monitor.storageKey
        isBuiltIn = monitor.isBuiltIn
        usesSoftwareDimming = monitor.usesSoftwareDimming
    }
}

private struct LightProfileEditor: View {
    let sensor: SensorController
    let manager: DisplayManager
    let monitor: LightMonitor

    private var profile: LightProfile { sensor.lightProfile(forKey: monitor.storageKey, isBuiltIn: monitor.isBuiltIn) }

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
            LightCurveChart(curve: profile.curve, lux: sensor.activeLux, manager: manager, id: monitor.id)
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
                if let lux = sensor.activeLux {
                    RememberBrightnessButton(manager: manager, id: monitor.id, lux: lux, curve: profile.curve) { point in
                        update { $0.curve.insert(point) }
                    }
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
        sensor.setLightProfile(profile, forKey: monitor.storageKey, isBuiltIn: monitor.isBuiltIn)
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Liest die Helligkeit des Monitors für die Beschriftung; nur diese View rendert bei
/// jedem Überblendungsschritt neu, nicht der Chart.
private struct BrightnessAnnotation: View {
    let manager: DisplayManager
    let id: CGDirectDisplayID
    let lux: Double

    var body: some View {
        let current = manager.monitors.first { $0.id == id }?.brightness ?? 0
        Text("\(Int(lux.rounded())) lx · \(Int(current)) %")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.orange)
    }
}

/// „Aktuelle Helligkeit merken“: braucht die Helligkeit, deshalb eigene View.
private struct RememberBrightnessButton: View {
    let manager: DisplayManager
    let id: CGDirectDisplayID
    let lux: Double
    let curve: LightCurve
    let onInsert: (LightCurve.Point) -> Void

    var body: some View {
        if let monitor = manager.monitors.first(where: { $0.id == id }), monitor.isAdjustable {
            Button("Aktuelle Helligkeit merken") {
                onInsert(LightCurve.Point(lux: lux, percent: monitor.brightness))
            }
            .help("Legt einen Punkt an: \(Int(lux.rounded())) lx → \(Int(monitor.brightness)) %")
            .disabled(curve.points.count >= LightCurve.maxPoints && !curve.points.contains { $0.lux == lux.rounded() })
        }
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
    let manager: DisplayManager
    let id: CGDirectDisplayID
    /// 20 Werte je Zehnerpotenz; hängt nur von der Kurve ab, deshalb einmal berechnet
    /// statt bei jedem Body.
    private let samples: [(lux: Double, percent: Double)]

    private static let luxRange: ClosedRange<Double> = 1...LightCurve.maxLux

    init(curve: LightCurve, lux: Double?, manager: DisplayManager, id: CGDirectDisplayID) {
        self.curve = curve
        self.lux = lux
        self.manager = manager
        self.id = id
        samples = stride(from: 0.0, through: 5, by: 0.05).map { exponent in
            let lux = pow(10, exponent)
            return (lux, curve.percent(forLux: lux))
        }
    }

    var body: some View {
        Chart {
            ForEach(samples, id: \.lux) { sample in
                AreaMark(x: .value("Lux", sample.lux), y: .value("Helligkeit", sample.percent))
                    .foregroundStyle(.linearGradient(
                        colors: [.accentColor.opacity(0.25), .accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                LineMark(x: .value("Lux", sample.lux), y: .value("Helligkeit", sample.percent))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            ForEach(Array(curve.points.enumerated()), id: \.offset) { _, point in
                PointMark(x: .value("Lux", max(point.lux, 1)), y: .value("Helligkeit", point.percent))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(40)
            }
            if let lux {
                RuleMark(x: .value("Lux", min(max(lux, 1), LightCurve.maxLux)))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        BrightnessAnnotation(manager: manager, id: id, lux: lux)
                    }
            }
        }
        .chartXScale(domain: Self.luxRange, type: .log)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [1, 10, 100, 1000, 10_000, 100_000]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let lux = value.as(Double.self) {
                        Text("\(Int(lux)) lx")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
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
        case .keychainUnavailable(let status):
            Label("Schlüsselbund nicht lesbar (Fehler \(Int(status)))", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
                Text("Nach 3 s gilt „weg“, dann wirkt die Einstellung „Wenn du weg bist“. Maus oder Tastatur holt die Bildschirme sofort zurück.")
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
