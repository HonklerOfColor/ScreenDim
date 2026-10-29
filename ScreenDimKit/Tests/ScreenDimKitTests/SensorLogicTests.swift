import Foundation
import Testing
@testable import ScreenDimKit

@Suite("Simulierter Sensor")
struct SimulatedSensorTests {
    private let schedule = SimulationSchedule(presentFor: .seconds(3), awayFor: .seconds(2))

    private func run(_ simulation: inout SensorSimulation, seconds: Int) -> [SensorEvent] {
        (0..<seconds).flatMap { simulation.step(at: .seconds($0)) }
    }

    @Test("Gleicher Seed, gleiche Werte; anderer Seed, anderes Rauschen")
    func deterministic() {
        var a = SensorSimulation(schedule: schedule, seed: 42)
        var b = SensorSimulation(schedule: schedule, seed: 42)
        var c = SensorSimulation(schedule: schedule, seed: 43)
        let first = run(&a, seconds: 30)
        #expect(first == run(&b, seconds: 30))
        #expect(first != run(&c, seconds: 30))
    }

    @Test("Anwesenheit wechselt im Takt und nur bei Änderung")
    func presenceCycle() {
        var simulation = SensorSimulation(schedule: schedule, seed: 1)
        let presence = (0..<11).map { simulation.step(at: .seconds($0)).compactMap { event -> Bool? in
            if case .presence(let value) = event { value } else { nil }
        } }
        // 3 s da, 2 s weg, …
        #expect(presence == [[true], [], [], [false], [], [true], [], [], [false], [], [true]])
    }

    @Test("Lux bleibt zwischen 50 und 600 und folgt dem Sinus")
    func luxRange() {
        var simulation = SensorSimulation(schedule: schedule, seed: 7)
        let values = (0..<240).map { simulation.lux(at: .seconds($0)) }
        #expect(values.allSatisfy(SensorSimulation.luxRange.contains))
        // Viertelperiode (30 s): oben; Dreiviertelperiode (90 s): unten.
        #expect(values[30] > 500)
        #expect(values[90] < 150)
    }

    @Test("„weg“ mit Vorlauf, „zurück“ sofort; Lux von Hand ersetzt den Sinus")
    func overrides() {
        var simulation = SensorSimulation(schedule: SimulationSchedule(presentFor: .seconds(20), awayFor: .seconds(8)), seed: 1)
        simulation.simulateAway(at: .seconds(5), lead: .seconds(3))
        #expect(simulation.presence(at: .seconds(7)))
        #expect(!simulation.presence(at: .seconds(8)))
        #expect(!simulation.presence(at: .seconds(15)))
        #expect(simulation.presence(at: .seconds(16)))

        simulation.simulateAway(at: .seconds(30), lead: .zero)
        simulation.simulateBack(at: .seconds(31))
        #expect(simulation.presence(at: .seconds(31)))

        simulation.luxOverride = 444
        #expect(simulation.lux(at: .seconds(1)) == 444)
    }

    @Test("Quelle mit injizierter Uhr liefert genau die Ereignisse des Modells")
    func sourceWithClock() async {
        let source = SimulatedSensorSource(schedule: schedule, seed: 42, clock: InstantClock())
        var received: [SensorEvent] = []
        for await event in source.events() {
            received.append(event)
            if received.count == 20 { break }
        }
        var model = SensorSimulation(schedule: schedule, seed: 42)
        let expected = [SensorEvent.connection(.connected)] + run(&model, seconds: 20)
        #expect(received == Array(expected.prefix(20)))
    }
}

@Suite("Freigabe der Abwesenheit")
struct PresenceGateTests {
    @Test("Aus nur bei frischer Abwesenheit, verbunden und ohne Eingabe")
    func shouldBlank() {
        let fresh = Duration.seconds(1)
        let idle = Duration.seconds(30)
        #expect(PresenceGate.shouldBlank(presence: false, connected: true, lastEventAge: fresh, sinceLastInput: idle))
        #expect(!PresenceGate.shouldBlank(presence: true, connected: true, lastEventAge: fresh, sinceLastInput: idle))
        #expect(!PresenceGate.shouldBlank(presence: nil, connected: true, lastEventAge: fresh, sinceLastInput: idle))
        #expect(!PresenceGate.shouldBlank(presence: false, connected: false, lastEventAge: fresh, sinceLastInput: idle))
        #expect(!PresenceGate.shouldBlank(presence: false, connected: true, lastEventAge: nil, sinceLastInput: idle))
        // Veraltet: 10 s und älter.
        #expect(PresenceGate.shouldBlank(presence: false, connected: true, lastEventAge: .milliseconds(9_999), sinceLastInput: idle))
        #expect(!PresenceGate.shouldBlank(presence: false, connected: true, lastEventAge: .seconds(10), sinceLastInput: idle))
        // Gerade getippt oder die Maus bewegt.
        #expect(!PresenceGate.shouldBlank(presence: false, connected: true, lastEventAge: fresh, sinceLastInput: .seconds(1)))
    }

    @Test("Veraltet nach 30 s Stille oder ohne Verbindung")
    func stale() {
        #expect(!PresenceGate.isStale(connected: true, lastEventAge: .seconds(29)))
        #expect(PresenceGate.isStale(connected: true, lastEventAge: .seconds(30)))
        #expect(PresenceGate.isStale(connected: false, lastEventAge: .seconds(1)))
        #expect(PresenceGate.isStale(connected: true, lastEventAge: nil))
    }

    @Test("Licht → Helligkeit logarithmisch zwischen 20 und 100 %")
    func ambientCurve() {
        #expect(AmbientLightCurve.percent(forLux: 0) == 20)
        #expect(AmbientLightCurve.percent(forLux: 10) == 20)
        #expect(AmbientLightCurve.percent(forLux: 100) == 60)
        #expect(AmbientLightCurve.percent(forLux: 1000) == 100)
        #expect(AmbientLightCurve.percent(forLux: 50_000) == 100)
    }

    @Test("Backoff 1 s → 30 s, Reset nach Verbindung")
    func backoff() {
        var backoff = ReconnectBackoff()
        let waits = (0..<8).map { _ in backoff.next() }
        #expect(waits == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        backoff.reset()
        #expect(backoff.next() == .seconds(1))
    }
}
