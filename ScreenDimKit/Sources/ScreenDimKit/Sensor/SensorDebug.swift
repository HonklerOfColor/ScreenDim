import Foundation

/// Woher ein Sensorwert kommt.
public enum SensorOrigin: String, Sendable, CaseIterable {
    /// ESP32-Schreibtisch-Sensor (SSE).
    case deskSensor
    /// Simulierter Sensor des Demo-Modus.
    case demo
    /// Eingebauter Lichtsensor des Macs (nur Direct).
    case builtIn
}

/// Ein Eintrag im Protokoll der Sensor-Diagnose: was kam, und was daraus folgte.
public struct SensorDebugEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Ereignis einer Quelle.
        case event(SensorOrigin, SensorEvent)
        /// Die aktive Lichtquelle wechselt; `nil`: keine.
        case lightSourceSwitch(from: SensorOrigin?, to: SensorOrigin?)
    }

    public enum Effect: Equatable, Sendable {
        /// Neue Helligkeit aus dem Licht, in Prozent.
        case brightness(Double)
        case screensOff
        case screensOn
    }

    public let id: Int
    public let date: Date
    public let kind: Kind
    /// `nil`: Das Ereignis hat nichts verändert (Hysterese, nicht die Lichtquelle, …).
    public let effect: Effect?

    /// Quelle eines Ereignisses; `nil` bei einem Quellwechsel.
    public var origin: SensorOrigin? {
        if case .event(let origin, _) = kind { origin } else { nil }
    }

    public var event: SensorEvent? {
        if case .event(_, let event) = kind { event } else { nil }
    }
}
