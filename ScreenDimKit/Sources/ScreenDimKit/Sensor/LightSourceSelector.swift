import Foundation

/// Ob gerade Licht die Helligkeit regelt, und von wem: Wahl des Nutzers und Verfügbarkeit
/// des Schreibtisch-Sensors. Rein und ohne Zustand; Zeiten liefert der `SensorController`.
public enum LightSourceSelector {
    /// So alt darf das letzte Ereignis des Schreibtisch-Sensors sein (Lux, Anwesenheit,
    /// Lebenszeichen). Die Firmware meldet Lux nur bei 3 % Änderung oder im 30-s-Takt;
    /// 45 s liegen sicher über diesem Takt, damit der Sensor bei ruhigem Licht nicht als
    /// ausgefallen gilt.
    public static let deskSensorMaxAge: Duration = .seconds(45)

    /// Schreibtisch-Sensor verbunden, mit einem Lux-Wert und frischem Ereignis. Frisch hält
    /// ihn jedes Ereignis, nicht nur Lux: Bei gleichem Licht bleibt der letzte Wert gültig.
    /// - Parameter eventAge: Alter des letzten Ereignisses; `nil` ohne Lux-Wert.
    public static func isDeskSensorAvailable(connected: Bool, eventAge: Duration?) -> Bool {
        guard connected, let eventAge else { return false }
        return eventAge <= deskSensorMaxAge
    }

    /// Aktive Quelle; `nil`, wenn keine. Die Demo ersetzt den Schreibtisch-Sensor, außer
    /// bei „aus“.
    public static func select(
        choice: SensorController.LightSource,
        demo: Bool,
        deskAvailable: Bool
    ) -> SensorOrigin? {
        guard choice != .off else { return nil }
        if demo { return .demo }
        return deskAvailable ? .deskSensor : nil
    }
}

extension SensorController.LightSource {
    /// Gespeicherter Wert, auch aus älteren Versionen. Jede frühere Wahl mit dem eingebauten
    /// Lichtsensor des Macs („deskSensor“, „builtIn“, „deskSensorFirst“, „builtInFirst“,
    /// „builtInOnly“) wird zu `deskSensorOnly`; den Sensor gibt es nicht mehr.
    init?(storedValue: String) {
        switch storedValue {
        case "deskSensor", "builtIn", "deskSensorFirst", "builtInFirst", "builtInOnly": self = .deskSensorOnly
        default: self.init(rawValue: storedValue)
        }
    }
}
