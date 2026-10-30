import Foundation
import os

let lightLog = Logger(subsystem: "com.andreastrabi.ScreenDim", category: "light")

/// Ein Helligkeitsauftrag an einen Monitor: Ziel, Grund und womit er beginnt. Je Auftrag
/// gibt es einen Eintrag in Protokoll und Log, nicht je Schritt der Überblendung.
public struct BrightnessJob: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Neues Licht der aktiven Quelle, roh und geglättet.
        case lux(raw: Double, filtered: Double, origin: SensorOrigin)
        /// Andere Lichtquelle; ihr letzter geglätteter Wert gilt.
        case sourceSwitch(from: SensorOrigin?, to: SensorOrigin)
        /// Lichtprofil geändert (Einstellungen).
        case profileChange
        /// Licht kam während der DDC-Prüfung; nach der Prüfung nachgeholt.
        case pendingAfterProbe
        /// Regler oder Tastenkürzel; sofort, ohne Überblendung.
        case manual
        /// Gespeicherter Wert nach erfolgreicher DDC-Prüfung.
        case probeRestore
        /// DDC geht nicht, die Software-Dimmung übernimmt.
        case softwareFallback
        /// Aufwachen oder Umstecken unterbrach eine Überblendung.
        case wake
        /// Ein anderer Regler (macOS, Helligkeitstasten) hat das Display verstellt; sein
        /// Wert wird übernommen.
        case externalChange
    }

    public let storageKey: String
    public let name: String
    public let reason: Reason
    /// Wert, den der Manager sich vor dem Auftrag gemerkt hatte.
    public let remembered: Double
    /// Echter Wert vor dem Auftrag: gelesen (eingebautes Display) oder zuletzt bestätigter
    /// Write (DDC); `nil`, wenn keiner bekannt ist (Software-Dimmung: gleich dem Merkwert).
    public let actual: Double?
    public let target: Double
    public let duration: Duration

    public init(
        storageKey: String,
        name: String,
        reason: Reason,
        remembered: Double,
        actual: Double?,
        target: Double,
        duration: Duration
    ) {
        self.storageKey = storageKey
        self.name = name
        self.reason = reason
        self.remembered = remembered
        self.actual = actual
        self.target = target
        self.duration = duration
    }

    /// Kurzform für Log und Protokoll, ohne Lokalisierung.
    public var logDescription: String {
        let start = actual.map { "\(Int(remembered))/\(Int($0))" } ?? "\(Int(remembered))"
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return "\(name): \(reason.logName) \(start) → \(Int(target)) % in \(String(format: "%.1f", seconds)) s"
    }
}

extension BrightnessJob.Reason {
    /// Stabiler Name für Log und Kopie der Diagnose.
    public var logName: String {
        switch self {
        case .lux(let raw, let filtered, let origin):
            "lux \(origin.rawValue) \(Int(raw.rounded()))→\(Int(filtered.rounded())) lx"
        case .sourceSwitch(let from, let to): "sourceSwitch \(from?.rawValue ?? "-")→\(to.rawValue)"
        case .profileChange: "profileChange"
        case .pendingAfterProbe: "pendingAfterProbe"
        case .manual: "manual"
        case .probeRestore: "probeRestore"
        case .softwareFallback: "softwareFallback"
        case .wake: "wake"
        case .externalChange: "externalChange"
        }
    }
}
