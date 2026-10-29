import Testing
@testable import ScreenDimKit

@Suite("Lichtquelle: Vorrang, Rückfall, Sperre")
struct LightSourceSelectorTests {
    typealias Choice = SensorController.LightSource

    enum Desk: CaseIterable, Sendable {
        case connected, disconnected, stale
    }

    enum BuiltIn: CaseIterable, Sendable {
        case available, missing, lidClosed, stale
    }

    @Test("Übernahme gespeicherter Werte", arguments: [
        ("deskSensor", Choice.deskSensorFirst),
        ("builtIn", .builtInFirst),
        ("off", .off),
        ("deskSensorFirst", .deskSensorFirst),
        ("builtInFirst", .builtInFirst),
        ("deskSensorOnly", .deskSensorOnly),
        ("builtInOnly", .builtInOnly),
    ])
    func storedValues(stored: String, expected: Choice) {
        #expect(Choice(storedValue: stored) == expected)
    }

    @Test("Unbekannter gespeicherter Wert gilt nicht")
    func unknownStoredValue() {
        #expect(Choice(storedValue: "sonne") == nil)
    }

    @Test("Schreibtisch-Sensor: verbunden und Lux höchstens 10 s alt")
    func deskAvailability() {
        #expect(LightSourceSelector.isDeskSensorAvailable(connected: true, luxAge: .zero))
        #expect(LightSourceSelector.isDeskSensorAvailable(connected: true, luxAge: .seconds(10)))
        #expect(!LightSourceSelector.isDeskSensorAvailable(connected: true, luxAge: .seconds(10) + .milliseconds(1)))
        #expect(!LightSourceSelector.isDeskSensorAvailable(connected: true, luxAge: nil))
        #expect(!LightSourceSelector.isDeskSensorAvailable(connected: false, luxAge: .zero))
    }

    @Test("Eingebauter Sensor: vorhanden, Deckel offen, Wert höchstens 5 s alt")
    func builtInAvailability() {
        #expect(LightSourceSelector.isBuiltInAvailable(present: true, covered: false, luxAge: .seconds(5)))
        #expect(!LightSourceSelector.isBuiltInAvailable(present: true, covered: false, luxAge: .seconds(6)))
        #expect(!LightSourceSelector.isBuiltInAvailable(present: true, covered: false, luxAge: nil))
        #expect(!LightSourceSelector.isBuiltInAvailable(present: true, covered: true, luxAge: .zero))
        #expect(!LightSourceSelector.isBuiltInAvailable(present: false, covered: false, luxAge: .zero))
    }

    @Test("Ohne eingebauten Sensor wirkt jede Wahl außer „aus“ wie „nur Schreibtisch-Sensor“")
    func effectiveChoice() {
        for choice in Choice.allCases {
            #expect(LightSourceSelector.effectiveChoice(choice, builtInPresent: true) == choice)
            let expected: Choice = choice == .off ? .off : .deskSensorOnly
            #expect(LightSourceSelector.effectiveChoice(choice, builtInPresent: false) == expected)
        }
    }

    @Test("Auswahl für alle Kombinationen", arguments: Desk.allCases, BuiltIn.allCases)
    func allCombinations(desk: Desk, builtIn: BuiltIn) {
        let deskOK = LightSourceSelector.isDeskSensorAvailable(
            connected: desk != .disconnected,
            luxAge: desk == .stale ? .seconds(11) : .seconds(1)
        )
        let builtInOK = LightSourceSelector.isBuiltInAvailable(
            present: builtIn != .missing,
            covered: builtIn == .lidClosed,
            luxAge: builtIn == .stale ? .seconds(6) : .seconds(1)
        )
        #expect(deskOK == (desk == .connected))
        #expect(builtInOK == (builtIn == .available))

        for choice in Choice.allCases {
            let effective = LightSourceSelector.effectiveChoice(choice, builtInPresent: builtIn != .missing)
            let selected = LightSourceSelector.select(
                choice: effective, demo: false, deskAvailable: deskOK, builtInAvailable: builtInOK,
                current: nil, sinceLastSwitch: nil
            )
            #expect(selected == expected(choice, deskOK: deskOK, builtIn: builtIn), "\(choice)")
        }
    }

    /// Erwartung, unabhängig von `order` ausgeschrieben.
    private func expected(_ choice: Choice, deskOK: Bool, builtIn: BuiltIn) -> SensorOrigin? {
        let builtInOK = builtIn == .available
        let desk: SensorOrigin? = deskOK ? .deskSensor : nil
        let inside: SensorOrigin? = builtInOK ? .builtIn : nil
        // Ohne Sensor (App Store, Mac mini) gibt es nur den Schreibtisch-Sensor.
        if builtIn == .missing { return choice == .off ? nil : desk }
        return switch choice {
        case .deskSensorFirst: desk ?? inside
        case .builtInFirst: inside ?? desk
        case .deskSensorOnly: desk
        case .builtInOnly: inside
        case .off: nil
        }
    }

    @Test("Demo ersetzt jede Quelle außer „aus“")
    func demoOverrides() {
        for choice in Choice.allCases {
            let selected = LightSourceSelector.select(
                choice: choice, demo: true, deskAvailable: true, builtInAvailable: true,
                current: .builtIn, sinceLastSwitch: .zero
            )
            #expect(selected == (choice == .off ? nil : .demo))
        }
    }

    @Test("Sperre: Rückkehr zur bevorzugten Quelle erst nach 5 s, Ausfall wechselt sofort")
    func hold() {
        func select(current: SensorOrigin?, since: Duration?, builtInOK: Bool = true, choice: Choice = .deskSensorFirst) -> SensorOrigin? {
            LightSourceSelector.select(
                choice: choice, demo: false, deskAvailable: true, builtInAvailable: builtInOK,
                current: current, sinceLastSwitch: since
            )
        }
        // Rückfall ist aktiv, der Schreibtisch-Sensor ist wieder da.
        #expect(select(current: .builtIn, since: .seconds(2)) == .builtIn)
        #expect(select(current: .builtIn, since: .seconds(5)) == .deskSensor)
        // Fällt die aktive Quelle aus, gilt keine Sperre.
        #expect(select(current: .builtIn, since: .zero, builtInOK: false) == .deskSensor)
        // Neue Wahl ohne die aktive Quelle: sofort.
        #expect(select(current: .builtIn, since: .zero, choice: .deskSensorOnly) == .deskSensor)
        // Erste Quelle nach „keine“: sofort.
        #expect(select(current: nil, since: .zero) == .deskSensor)
    }
}
