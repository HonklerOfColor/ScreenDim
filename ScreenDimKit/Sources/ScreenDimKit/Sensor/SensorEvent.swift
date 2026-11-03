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
}

/// Quelle für Sensorereignisse: der echte Sensor (SSE), die Simulation oder (per Fabrik,
/// derzeit ungenutzt) der eingebaute Lichtsensor des Macs, der nur `.connection(.connected)`
/// und `.lux` meldet.
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
}

/// Links rund um den Sensor.
public enum SensorLinks {
    // TODO: Platzhalter. Vor der Veröffentlichung durch die echte Bauanleitung ersetzen.
    public static let flashPage = URL(string: "https://screendim.example.com/sensor/")!
}
