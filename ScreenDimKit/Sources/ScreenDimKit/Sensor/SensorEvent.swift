import Foundation
import os

let sensorLog = Logger(subsystem: "com.andreastrabi.ScreenDim", category: "sensor")

/// Verbindung zum Schreibtisch-Sensor.
public enum SensorConnection: Equatable, Sendable {
    /// Sucht den Sensor im LAN (mDNS) oder wartet auf den nächsten Versuch.
    case searching
    case connected
    /// Der Sensor lehnt den gespeicherten Code ab (401). Kein weiterer Versuch, bis neu
    /// gekoppelt wurde.
    case pairingRequired
}

/// Was eine Sensorquelle meldet.
public enum SensorEvent: Equatable, Sendable {
    /// `true`: jemand sitzt am Schreibtisch.
    case presence(Bool)
    /// Umgebungslicht in Lux.
    case lux(Double)
    case connection(SensorConnection)
    /// Lebenszeichen ohne Messwert (SSE-Ping).
    case heartbeat
    /// „Max Distance“ der Firmware: Bis zu dieser Entfernung (cm) zählt jemand als
    /// anwesend. Gespeichert im Sensor, einstellbar über `SensorController.setMaxDistance`.
    case maxDistance(SensorNumber)
    /// Entfernung der Person laut Radar (cm); `nil`, wenn das Radar niemanden sieht.
    /// Kommt etwa alle 2 s.
    case distance(Double?)
}

/// Ein einstellbarer Zahlenwert des Sensors (ESPHome-Number).
public struct SensorNumber: Equatable, Sendable {
    public var value: Double
    /// Erlaubter Bereich laut Firmware; `nil` in Zustandsmeldungen ohne Details.
    public var range: ClosedRange<Double>?
    /// Schrittweite laut Firmware; `nil` wie `range`.
    public var step: Double?

    public init(value: Double, range: ClosedRange<Double>? = nil, step: Double? = nil) {
        self.value = value
        self.range = range
        self.step = step
    }
}

/// Quelle für Sensorereignisse: der echte Sensor (SSE) oder die Simulation.
public protocol SensorSource: AnyObject, Sendable {
    /// Jeder Aufruf startet einen eigenen Strom. Beenden des Konsumenten beendet die Quelle.
    func events() -> AsyncStream<SensorEvent>
}

/// Feste Angaben der Sensor-Firmware (ESPHome mit `web_server`).
public enum SensorProtocol {
    public static let serviceType = "_screendim._tcp"
    public static let user = "screendim"
    public static let eventsPath = "events"
    public static let presencePath = "binary_sensor/Presence"
    public static let luxPath = "sensor/Ambient Light"
    public static let pairingPath = "text_sensor/Pairing Code"
    /// Reichweite der Anwesenheit (cm). Lesen über den SSE-Strom (beim Verbinden mit
    /// Bereich und Schritt), setzen per `POST <Pfad>/set?value=…`.
    public static let maxDistancePath = "number/Max Distance"
    /// Entfernung laut Radar (cm), nur zum Anzeigen.
    public static let distancePath = "sensor/Distance"
    /// Bereich und Schritt von „Max Distance“, falls der Sensor sie (noch) nicht gemeldet hat.
    public static let maxDistanceRange: ClosedRange<Double> = 30...800
    public static let maxDistanceStep: Double = 10

    /// `number/Max Distance` → `number/Max Distance/set`
    public static func setPath(_ path: String) -> String {
        path + "/set"
    }
}

/// Links rund um den Sensor.
public enum SensorLinks {
    /// Bauanleitung für den Sensor. `nil`, solange keine veröffentlicht ist; dann zeigen
    /// die Einstellungen keinen Link.
    public static let flashPage: URL? = nil
}
