import Foundation

/// Welche Lichtquelle gerade die Helligkeit regelt: Wahl des Nutzers, Verfügbarkeit der
/// Quellen und eine Sperre gegen Hin-und-her. Rein und ohne Zustand; Zeiten und den
/// letzten Wechsel liefert der `SensorController`.
public enum LightSourceSelector {
    /// So alt darf das letzte Ereignis des Schreibtisch-Sensors sein (Lux, Anwesenheit,
    /// Lebenszeichen). Die Firmware meldet Lux nur bei 3 % Änderung oder im 30-s-Takt;
    /// 45 s liegen sicher über diesem Takt, damit der Sensor bei ruhigem Licht nicht als
    /// ausgefallen gilt.
    public static let deskSensorMaxAge: Duration = .seconds(45)
    /// So alt darf der letzte Wert des eingebauten Sensors sein; er meldet jede Sekunde.
    public static let builtInMaxAge: Duration = .seconds(5)
    /// Mindestdauer einer verfügbaren aktiven Quelle, bevor die bevorzugte sie wieder
    /// ablöst. Fällt die aktive Quelle aus, wird sofort gewechselt.
    public static let minimumHold: Duration = .seconds(5)

    /// Schreibtisch-Sensor verbunden, mit einem Lux-Wert und frischem Ereignis. Frisch hält
    /// ihn jedes Ereignis, nicht nur Lux: Bei gleichem Licht bleibt der letzte Wert gültig.
    /// - Parameter eventAge: Alter des letzten Ereignisses; `nil` ohne Lux-Wert.
    public static func isDeskSensorAvailable(connected: Bool, eventAge: Duration?) -> Bool {
        guard connected, let eventAge else { return false }
        return eventAge <= deskSensorMaxAge
    }

    /// Eingebauter Sensor vorhanden, Deckel offen und mit frischem Wert.
    public static func isBuiltInAvailable(present: Bool, covered: Bool, luxAge: Duration?) -> Bool {
        guard present, !covered, let luxAge else { return false }
        return luxAge <= builtInMaxAge
    }

    /// Ohne eingebauten Sensor (keine Fabrik, Mac mini, Mac Studio) bleibt nur der
    /// Schreibtisch-Sensor; jede Wahl außer „aus“ wirkt dann wie „nur Schreibtisch-Sensor“.
    public static func effectiveChoice(
        _ choice: SensorController.LightSource,
        builtInPresent: Bool
    ) -> SensorController.LightSource {
        builtInPresent || choice == .off ? choice : .deskSensorOnly
    }

    /// Aktive Quelle; `nil`, wenn keine. Die Demo ersetzt jede Quelle außer „aus“.
    /// - Parameters:
    ///   - current: bisher aktive Quelle.
    ///   - sinceLastSwitch: Zeit seit dem letzten Wechsel; `nil`, wenn es keinen gab.
    public static func select(
        choice: SensorController.LightSource,
        demo: Bool,
        deskAvailable: Bool,
        builtInAvailable: Bool,
        current: SensorOrigin?,
        sinceLastSwitch: Duration?
    ) -> SensorOrigin? {
        guard choice != .off else { return nil }
        if demo { return .demo }
        func available(_ origin: SensorOrigin) -> Bool {
            switch origin {
            case .deskSensor: deskAvailable
            case .builtIn: builtInAvailable
            case .demo: false
            }
        }
        let wanted = choice.order.first(where: available)
        // Sperre: Eine verfügbare aktive Quelle bleibt mindestens `minimumHold`.
        if let current, current != wanted, choice.order.contains(current), available(current),
           let sinceLastSwitch, sinceLastSwitch < minimumHold {
            return current
        }
        return wanted
    }
}

extension SensorController.LightSource {
    /// Quellen in der Reihenfolge des Vorrangs.
    public var order: [SensorOrigin] {
        switch self {
        case .deskSensorFirst: [.deskSensor, .builtIn]
        case .builtInFirst: [.builtIn, .deskSensor]
        case .deskSensorOnly: [.deskSensor]
        case .builtInOnly: [.builtIn]
        case .off: []
        }
    }

    /// Gespeicherter Wert, auch aus älteren Versionen („deskSensor“, „builtIn“).
    init?(storedValue: String) {
        switch storedValue {
        case "deskSensor": self = .deskSensorFirst
        case "builtIn": self = .builtInFirst
        default: self.init(rawValue: storedValue)
        }
    }
}
