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
        /// Ein Helligkeitsauftrag an einen Monitor, mit Grund.
        case brightnessJob(BrightnessJob)
    }

    public enum Effect: Equatable, Sendable {
        /// Neue Helligkeit aus dem Licht, je Monitor.
        case brightness([LightLevel])
        case screensOff
        case screensOn
    }

    public let id: Int
    public let date: Date
    public let kind: Kind
    /// `nil`: Das Ereignis hat nichts verändert (Hysterese, nicht die Lichtquelle, …).
    public let effect: Effect?

    public var job: BrightnessJob? {
        if case .brightnessJob(let job) = kind { job } else { nil }
    }

    /// Quelle eines Ereignisses; `nil` bei einem Quellwechsel oder Auftrag.
    public var origin: SensorOrigin? {
        if case .event(let origin, _) = kind { origin } else { nil }
    }

    public var event: SensorEvent? {
        if case .event(_, let event) = kind { event } else { nil }
    }
}

/// Helligkeit, die das Licht einem Monitor gegeben hat.
public struct LightLevel: Equatable, Sendable {
    public let storageKey: String
    public let name: String
    /// 0…100
    public let percent: Double

    public init(storageKey: String, name: String, percent: Double) {
        self.storageKey = storageKey
        self.name = name
        self.percent = percent
    }
}
