import AppKit
import ScreenDimKit
import SwiftUI

/// Fenster „Sensor-Diagnose“: aktuelle Messung jeder Quelle, welche gerade Anwesenheit
/// und Licht liefert, und ein Protokoll der Ereignisse mit ihrer Wirkung. Solange das
/// Fenster offen ist, liest der eingebaute Lichtsensor mit, auch wenn er nicht die
/// Lichtquelle ist.
struct SensorDebugView: View {
    static let windowID = "sensor-debug"

    let sensor: SensorController
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ActiveSummary(sensor: sensor)
                    DeskSourceBox(sensor: sensor)
                    BuiltInSourceBox(sensor: sensor)
                    EventLog(sensor: sensor)
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text("Das Protokoll läuft nur, solange dieses Fenster offen ist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Protokoll leeren") { sensor.clearDebugLog() }
                    .disabled(sensor.debugLog.isEmpty)
                Button(copied ? "Kopiert" : "Kopieren") { copy() }
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { sensor.setDebugMonitoring(true) }
        .onDisappear { sensor.setDebugMonitoring(false) }
    }

    /// Zustand und Protokoll als Text, z. B. für einen Fehlerbericht.
    private func copy() {
        var lines = [
            "ScreenDim Sensor-Diagnose, \(Date().formatted(date: .numeric, time: .standard))",
            "Lichtquelle (Einstellung): \(sensor.lightSource.rawValue)",
            "Licht aktiv: \(sensor.activeLightOrigin?.rawValue ?? "-")",
            "Anwesenheit aktiv: \(sensor.activePresenceOrigin?.rawValue ?? "-")",
            "Schreibtisch-Sensor: \(sensor.status), Host \(sensor.pairedHostname ?? "-"), "
                + "Anwesenheit \(sensor.presence.map(String.init) ?? "-"), Lux \(sensor.lux.map { String($0) } ?? "-")",
            "Eingebaut: vorhanden \(sensor.hasBuiltInLightSensor), Deckel zu \(sensor.isBuiltInLightSensorCovered), "
                + "Lux \(sensor.builtInLux.map { String($0) } ?? "-")",
            "Zuletzt gesetzt: \(sensor.lightBrightness.map { "\(Int($0)) %" } ?? "-") "
                + "(\(sensor.lightBrightnessOrigin?.rawValue ?? "-")), Bildschirme aus: \(sensor.screensBlanked)",
            "",
        ]
        for entry in sensor.debugLog.reversed() {
            let time = entry.date.formatted(date: .omitted, time: .standard)
            let effect = entry.effect.map { " → \($0)" } ?? ""
            lines.append("\(time) \(entry.origin.rawValue) \(entry.event)\(effect)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

// MARK: - Bausteine

/// Was gerade wirkt: Quelle für Anwesenheit und Licht, letzte Helligkeit, Bildschirme.
private struct ActiveSummary: View {
    let sensor: SensorController

    var body: some View {
        GroupBox("Gerade aktiv") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Anwesenheit").foregroundStyle(.secondary)
                    OriginLabel(origin: sensor.activePresenceOrigin)
                }
                GridRow {
                    Text("Licht").foregroundStyle(.secondary)
                    OriginLabel(origin: sensor.activeLightOrigin)
                }
                GridRow {
                    Text("Lichtquelle (Einstellung)").foregroundStyle(.secondary)
                    Text(lightSourceName)
                }
                GridRow {
                    Text("Zuletzt gesetzt").foregroundStyle(.secondary)
                    if let percent = sensor.lightBrightness, let origin = sensor.lightBrightnessOrigin {
                        HStack(spacing: 4) {
                            Text("\(Int(percent)) %").monospacedDigit()
                            Text("aus \(Text(originName(origin)))").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(verbatim: "–")
                    }
                }
                GridRow {
                    Text("Bildschirme").foregroundStyle(.secondary)
                    if sensor.screensBlanked {
                        Label("Aus (niemand da)", systemImage: "moon.fill").foregroundStyle(.orange)
                    } else {
                        Text("An")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var lightSourceName: LocalizedStringKey {
        switch sensor.lightSource {
        case .deskSensor: "Schreibtisch-Sensor"
        case .builtIn: "Eingebauter Lichtsensor"
        case .off: "Aus"
        }
    }
}

/// Schreibtisch-Sensor oder, im Demo-Modus, die Simulation.
private struct DeskSourceBox: View {
    let sensor: SensorController

    private var origin: SensorOrigin { sensor.isDemoActive ? .demo : .deskSensor }

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    SensorStatusLabel(sensor: sensor)
                }
                if !sensor.isDemoActive, let host = sensor.pairedHostname {
                    GridRow {
                        Text("Host").foregroundStyle(.secondary)
                        Text(verbatim: host).textSelection(.enabled)
                    }
                }
                GridRow {
                    Text("Anwesenheit").foregroundStyle(.secondary)
                    switch sensor.presence {
                    case true?: Text("Da")
                    case false?: Text("Weg")
                    case nil: Text(verbatim: "–")
                    }
                }
                GridRow {
                    Text("Umgebungslicht").foregroundStyle(.secondary)
                    LuxText(lux: sensor.lux)
                }
                GridRow {
                    Text("Letztes Ereignis").foregroundStyle(.secondary)
                    EventAge(date: sensor.lastEventDate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            SourceHeader(
                title: sensor.isDemoActive ? "Demo-Modus (simuliert)" : "Schreibtisch-Sensor",
                presence: sensor.activePresenceOrigin == origin,
                light: sensor.activeLightOrigin == origin
            )
        }
    }
}

private struct BuiltInSourceBox: View {
    let sensor: SensorController

    var body: some View {
        GroupBox {
            Group {
                if !sensor.hasBuiltInLightSensor {
                    Text("Nicht verfügbar: Dieser Mac hat keinen Lichtsensor, oder die Variante darf ihn nicht lesen (App Store).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if sensor.isBuiltInLightSensorCovered {
                    Label("Deckel zu: Der Lichtsensor ist pausiert.", systemImage: "laptopcomputer")
                        .foregroundStyle(.orange)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Umgebungslicht").foregroundStyle(.secondary)
                            LuxText(lux: sensor.builtInLux)
                        }
                        GridRow {
                            Text("Letztes Ereignis").foregroundStyle(.secondary)
                            EventAge(date: sensor.builtInLastEventDate)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            SourceHeader(title: "Eingebauter Lichtsensor", presence: false, light: sensor.activeLightOrigin == .builtIn)
        }
    }
}

private struct EventLog: View {
    let sensor: SensorController

    var body: some View {
        GroupBox("Protokoll") {
            if sensor.debugLog.isEmpty {
                Text("Noch keine Ereignisse.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            } else {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(sensor.debugLog.reversed()) { entry in
                        HStack(spacing: 8) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text(originName(entry.origin))
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            Text(eventText(entry.event))
                            if let effect = entry.effect {
                                Text(effectText(effect)).fontWeight(.semibold)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                .padding(4)
            }
        }
    }

    private func eventText(_ event: SensorEvent) -> LocalizedStringKey {
        switch event {
        case .presence(true): "Anwesend"
        case .presence(false): "Weg"
        case .lux(let lux): "\(Int(lux.rounded())) lx"
        case .connection(.connected): "Verbunden"
        case .connection(.searching): "Suche …"
        case .connection(.pairingRequired): "Kopplung nötig"
        case .heartbeat: "Lebenszeichen"
        }
    }

    private func effectText(_ effect: SensorDebugEntry.Effect) -> LocalizedStringKey {
        switch effect {
        case .brightness(let percent): "→ \(Int(percent)) %"
        case .screensOff: "→ Bildschirme aus"
        case .screensOn: "→ Bildschirme an"
        }
    }
}

/// Titel einer Quelle mit ihren Rollen.
private struct SourceHeader: View {
    let title: LocalizedStringKey
    let presence: Bool
    let light: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.semibold)
            if presence { RoleBadge(text: "Anwesenheit", systemImage: "person.fill") }
            if light { RoleBadge(text: "Licht", systemImage: "sun.max.fill") }
            if !presence && !light {
                Text("nur Anzeige").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RoleBadge: View {
    let text: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.green.opacity(0.25), in: .capsule)
    }
}

private struct OriginLabel: View {
    let origin: SensorOrigin?

    var body: some View {
        if let origin {
            Text(originName(origin)).fontWeight(.semibold)
        } else {
            Text("Keine").foregroundStyle(.secondary)
        }
    }
}

private struct LuxText: View {
    let lux: Double?

    var body: some View {
        if let lux {
            Text("\(Int(lux.rounded())) lx").monospacedDigit()
        } else {
            Text(verbatim: "–")
        }
    }
}

/// „vor 3 s“; aktualisiert sich selbst, ohne eigenen Timer.
private struct EventAge: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, style: .relative).monospacedDigit()
        } else {
            Text(verbatim: "–")
        }
    }
}

private func originName(_ origin: SensorOrigin) -> LocalizedStringKey {
    switch origin {
    case .deskSensor: "Schreibtisch-Sensor"
    case .demo: "Demo-Modus"
    case .builtIn: "Eingebauter Lichtsensor"
    }
}
