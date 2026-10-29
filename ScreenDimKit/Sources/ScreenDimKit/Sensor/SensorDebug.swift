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
    public enum Effect: Equatable, Sendable {
        /// Neue Helligkeit aus dem Licht, in Prozent.
        case brightness(Double)
        case screensOff
        case screensOn
    }

    public let id: Int
    public let date: Date
    public let origin: SensorOrigin
    public let event: SensorEvent
    /// `nil`: Das Ereignis hat nichts verändert (Hysterese, nicht die Lichtquelle, …).
    public let effect: Effect?
}
