import AppKit
import ScreenDimKit
import SwiftUI

/// Fenster „Sensor-Diagnose“: aktuelle Messung des Sensors (oder der Demo), ob er gerade
/// Anwesenheit und Licht liefert, und ein Protokoll der Ereignisse und Quellwechsel mit
/// ihrer Wirkung.
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
            "Licht aktiv: \(sensor.activeLightOrigin?.rawValue ?? "-"), Schreibtisch verfügbar \(sensor.isDeskSensorLightAvailable)",
            "Anwesenheit aktiv: \(sensor.activePresenceOrigin?.rawValue ?? "-"), reagieren \(sensor.reactsToAbsence), "
                + "manuell \(sensor.isManualMode)",
            "Schreibtisch-Sensor: \(sensor.status), Host \(sensor.pairedHostname ?? "-"), "
                + "Anwesenheit \(sensor.presence.map(String.init) ?? "-"), Lux \(sensor.lux.map { String($0) } ?? "-")",
            "Zuletzt gesetzt: \(sensor.lightLevels.isEmpty ? "-" : levelsText(sensor.lightLevels)) "
                + "(\(sensor.lightBrightnessOrigin?.rawValue ?? "-")), Bildschirme: \(sensor.absenceStage.logName)",
            "",
        ]
        for entry in sensor.debugLog.reversed() {
            let time = entry.date.formatted(date: .omitted, time: .standard)
            let effect = entry.effect.map { " → \($0)" } ?? ""
            let what = switch entry.kind {
            case .event(let origin, let event): "\(origin.rawValue) \(event)"
            case .lightSourceSwitch(let from, let to): "Lichtquelle \(from?.rawValue ?? "-") → \(to?.rawValue ?? "-")"
            case .brightnessJob(let job): "Auftrag \(job.logDescription)"
            case .absence(let stage): "Abwesenheit: Bildschirme \(stage.logName)"
            }
            lines.append("\(time) \(what)\(effect)")
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
                    Text(lightSourceName(sensor.lightSource))
                }
                GridRow {
                    Text("Verfügbar").foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        AvailabilityLabel(title: "Schreibtisch-Sensor", available: sensor.isDeskSensorLightAvailable)
                    }
                }
                GridRow {
                    Text("Zuletzt gesetzt").foregroundStyle(.secondary)
                    if !sensor.lightLevels.isEmpty, let origin = sensor.lightBrightnessOrigin {
                        HStack(spacing: 4) {
                            Text(verbatim: levelsText(sensor.lightLevels)).monospacedDigit()
                            Text("aus \(Text(originName(origin)))").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(verbatim: "–")
                    }
                }
                GridRow {
                    Text("Bildschirme").foregroundStyle(.secondary)
                    switch sensor.absenceStage {
                    case .none: Text("An")
                    case .dimmed: Label("Abgedunkelt (niemand da)", systemImage: "moon").foregroundStyle(.orange)
                    case .off: Label("Aus (niemand da)", systemImage: "moon.fill").foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// Ob eine Quelle gerade Licht liefern kann (verbunden, Wert frisch).
private struct AvailabilityLabel: View {
    let title: LocalizedStringKey
    let available: Bool

    var body: some View {
        Label(title, systemImage: available ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(available ? .green : .secondary)
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
                    case true?: Text("Anwesend")
                    case false?: Text("Abwesend")
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
                    HStack(spacing: 8) {
                        Text("Zeit").frame(width: 58, alignment: .leading)
                        Text("Quelle / Grund").frame(width: 130, alignment: .leading)
                        Text("Was")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(sensor.debugLog.reversed()) { entry in
                        HStack(spacing: 8) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .leading)
                            switch entry.kind {
                            case .event(let origin, let event):
                                Text(originName(origin))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text(eventText(event))
                            case .lightSourceSwitch(let from, let to):
                                Text("Lichtquelle")
                                    .foregroundStyle(.orange)
                                    .frame(width: 130, alignment: .leading)
                                Text("Wechsel: \(Text(switchName(from))) → \(Text(switchName(to)))")
                                    .fontWeight(.semibold)
                            case .brightnessJob(let job):
                                Text(reasonName(job.reason))
                                    .foregroundStyle(.blue)
                                    .frame(width: 130, alignment: .leading)
                                if case .lux(let raw, let filtered, _) = job.reason {
                                    Text("\(Int(raw.rounded())) → \(Int(filtered.rounded())) lx")
                                        .foregroundStyle(.secondary)
                                }
                                Text(jobText(job))
                            case .absence(let stage):
                                Text("Abwesenheit")
                                    .foregroundStyle(.orange)
                                    .frame(width: 130, alignment: .leading)
                                Text(stageText(stage))
                                    .fontWeight(.semibold)
                            }
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
        case .presence(false): "Abwesend"
        case .lux(let lux): "\(Int(lux.rounded())) lx"
        case .connection(.connected): "Verbunden"
        case .connection(.searching): "Suche …"
        case .connection(.pairingRequired): "Kopplung nötig"
        case .heartbeat: "Lebenszeichen"
        case .maxDistance(let setting): "Anwesend bis \(Int(setting.value.rounded())) cm"
        case .distance(let cm?): "Entfernung \(Int(cm.rounded())) cm"
        case .distance(nil): "Entfernung: niemand erkannt"
        }
    }

    private func reasonName(_ reason: BrightnessJob.Reason) -> LocalizedStringKey {
        switch reason {
        case .lux: "Licht"
        case .sourceSwitch: "Quellwechsel"
        case .profileChange: "Profil"
        case .presenceChange: "Anwesenheit"
        case .pendingAfterProbe: "Nach der Prüfung"
        case .manual: "Von Hand"
        case .probeRestore: "Gespeicherter Wert"
        case .softwareFallback: "Software-Dimmung"
        case .wake: "Aufwachen/Umstecken"
        case .externalChange: "Fremde Änderung"
        case .idleDim: "Leerlauf"
        case .idleEnd: "Leerlauf beendet"
        case .absenceDim: "Abwesenheit"
        case .absenceEnd: "Abwesenheit beendet"
        }
    }

    /// „Monitor 7: 50/47 → 80 % · 2 s“: Merkwert, echter Wert (falls abweichend), Ziel, Dauer.
    private func jobText(_ job: BrightnessJob) -> LocalizedStringKey {
        let start = if let actual = job.actual, Int(actual) != Int(job.remembered) {
            "\(Int(job.remembered))/\(Int(actual))"
        } else {
            "\(Int(job.remembered))"
        }
        let duration = job.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        return "\(job.name): \(start) → \(Int(job.target)) % · \(duration)"
    }

    private func switchName(_ origin: SensorOrigin?) -> LocalizedStringKey {
        origin.map(originName) ?? "keine"
    }

    private func effectText(_ effect: SensorDebugEntry.Effect) -> LocalizedStringKey {
        switch effect {
        case .brightness(let levels): "→ \(levelsText(levels))"
        case .absence(.none): "→ Bildschirme an"
        case .absence(.dimmed): "→ Bildschirme abgedunkelt"
        case .absence(.off): "→ Bildschirme aus"
        }
    }

    private func stageText(_ stage: SensorController.AbsenceStage) -> LocalizedStringKey {
        switch stage {
        case .none: "Bildschirme an"
        case .dimmed: "Bildschirme abgedunkelt"
        case .off: "Bildschirme aus"
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
    }
}

/// „Monitor 7 80 %, MacBook 50 %“
private func levelsText(_ levels: [LightLevel]) -> String {
    levels.map { "\($0.name) \(Int($0.percent)) %" }.joined(separator: ", ")
}
