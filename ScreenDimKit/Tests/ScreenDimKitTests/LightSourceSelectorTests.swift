import Testing
@testable import ScreenDimKit

@Suite("Lichtquelle: Wahl, Verfügbarkeit, Altwerte")
struct LightSourceSelectorTests {
    typealias Choice = SensorController.LightSource

    @Test("Gespeicherte Werte; jede frühere Wahl mit eingebautem Lichtsensor wird „Schreibtisch-Sensor“", arguments: [
        ("deskSensor", Choice.deskSensorOnly),
        ("builtIn", .deskSensorOnly),
        ("deskSensorFirst", .deskSensorOnly),
        ("builtInFirst", .deskSensorOnly),
        ("builtInOnly", .deskSensorOnly),
        ("deskSensorOnly", .deskSensorOnly),
        ("off", .off),
    ])
    func storedValues(stored: String, expected: Choice) {
        #expect(Choice(storedValue: stored) == expected)
    }

    @Test("Unbekannter gespeicherter Wert gilt nicht")
    func unknownStoredValue() {
        #expect(Choice(storedValue: "sonne") == nil)
    }

    @Test("Nur noch Schreibtisch-Sensor oder aus")
    func choices() {
        #expect(Choice.allCases == [.deskSensorOnly, .off])
    }

    @Test("Schreibtisch-Sensor: verbunden und letztes Ereignis höchstens 45 s alt (über dem 30-s-Takt der Firmware)")
    func deskAvailability() {
        #expect(LightSourceSelector.isDeskSensorAvailable(connected: true, eventAge: .zero))
        #expect(LightSourceSelector.isDeskSensorAvailable(connected: true, eventAge: .seconds(31)))
        #expect(LightSourceSelector.isDeskSensorAvailable(connected: true, eventAge: .seconds(45)))
        #expect(!LightSourceSelector.isDeskSensorAvailable(connected: true, eventAge: .seconds(45) + .milliseconds(1)))
        #expect(!LightSourceSelector.isDeskSensorAvailable(connected: true, eventAge: nil))
        #expect(!LightSourceSelector.isDeskSensorAvailable(connected: false, eventAge: .zero))
    }

    @Test("Auswahl: Schreibtisch-Sensor, wenn verfügbar; die Demo ersetzt ihn; „aus“ heißt keine", arguments: [true, false])
    func select(deskAvailable: Bool) {
        #expect(LightSourceSelector.select(choice: .deskSensorOnly, demo: false, deskAvailable: deskAvailable)
            == (deskAvailable ? .deskSensor : nil))
        #expect(LightSourceSelector.select(choice: .deskSensorOnly, demo: true, deskAvailable: deskAvailable) == .demo)
        #expect(LightSourceSelector.select(choice: .off, demo: false, deskAvailable: deskAvailable) == nil)
        #expect(LightSourceSelector.select(choice: .off, demo: true, deskAvailable: deskAvailable) == nil)
    }
}
