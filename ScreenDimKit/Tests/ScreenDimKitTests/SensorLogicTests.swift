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
    @Test("Aus nur bei Abwesenheit, verbunden und ohne Eingabe")
    func startsAbsence() {
        let idle = Duration.seconds(30)
        #expect(PresenceGate.startsAbsence(presence: false, connected: true, sinceLastInput: idle))
        #expect(!PresenceGate.startsAbsence(presence: true, connected: true, sinceLastInput: idle))
        #expect(!PresenceGate.startsAbsence(presence: nil, connected: true, sinceLastInput: idle))
        #expect(!PresenceGate.startsAbsence(presence: false, connected: false, sinceLastInput: idle))
        // Gerade getippt oder die Maus bewegt.
        #expect(!PresenceGate.startsAbsence(presence: false, connected: true, sinceLastInput: .seconds(1)))
        #expect(PresenceGate.startsAbsence(presence: false, connected: true, sinceLastInput: PresenceGate.inputGrace))
    }

    @Test("Veraltet nach 30 s Stille oder ohne Verbindung")
    func stale() {
        #expect(!PresenceGate.isStale(connected: true, lastEventAge: .seconds(29)))
        #expect(PresenceGate.isStale(connected: true, lastEventAge: .seconds(30)))
        #expect(PresenceGate.isStale(connected: false, lastEventAge: .seconds(1)))
        #expect(PresenceGate.isStale(connected: true, lastEventAge: nil))
    }

    @Test("NaN als Stützpunkt oder Abfrage: kein Absturz, Unendlich wird begrenzt")
    func nanIsHarmless() {
        let curve = LightCurve(points: [.init(lux: .nan, percent: .nan), .init(lux: 100, percent: 60)])
        #expect(curve.points.map(\.lux) == [0, 100])
        #expect(curve.points[0].percent == 100)
        #expect(curve.percent(forLux: 50) == 66) // 0 lx zählt wie 1 lx: 100 − 40 · log10(50)/2
        #expect(curve.percent(forLux: .nan) == 100)
        #expect(LightCurve.Point(lux: .infinity, percent: 50).lux == LightCurve.maxLux)
        #expect(LightCurve.Point(lux: -.infinity, percent: 50).lux == 0)
    }

    @Test("Standardkurve: Licht → Helligkeit logarithmisch zwischen 20 und 100 %")
    func ambientCurve() {
        let curve = LightCurve.standard
        #expect(curve.percent(forLux: 0) == 20)
        #expect(curve.percent(forLux: 10) == 20)
        #expect(curve.percent(forLux: 100) == 60)
        #expect(curve.percent(forLux: 1000) == 100)
        #expect(curve.percent(forLux: 50_000) == 100)
    }

    @Test("Eigene Kurve: sortiert, mehrere Abschnitte, auch fallend; 0 lx zählt wie 1 lx")
    func customCurve() {
        let curve = LightCurve(points: [
            .init(lux: 1000, percent: 40), .init(lux: 0, percent: 10), .init(lux: 100, percent: 80),
        ])
        #expect(curve.points.map(\.lux) == [0, 100, 1000])
        #expect(curve.percent(forLux: 0) == 10)
        #expect(curve.percent(forLux: 10) == 45)
        #expect(curve.percent(forLux: 100) == 80)
        #expect(curve.percent(forLux: 316) == 60)
        #expect(curve.percent(forLux: 5000) == 40)
        // Zwei Punkte bei denselben Lux: kein Teilen durch null.
        #expect(LightCurve(points: [.init(lux: 50, percent: 30), .init(lux: 50, percent: 90)]).percent(forLux: 60) == 90)
    }

    @Test("Kurve bearbeiten: Grenzen, mindestens ein Punkt, höchstens acht, Vorschlag in der größten Lücke")
    func editCurve() throws {
        var curve = LightCurve.standard
        let suggestion = try #require(curve.suggestedPoint())
        #expect(suggestion == .init(lux: 100, percent: 60))
        curve.insert(.init(lux: 10, percent: 35)) // ersetzt den Punkt bei 10 lx
        #expect(curve.points == [.init(lux: 10, percent: 35), .init(lux: 1000, percent: 100)])
        curve.setPoint(.init(lux: 500_000, percent: 120), at: 1)
        #expect(curve.points.last == .init(lux: LightCurve.maxLux, percent: 100))
        curve.removePoint(at: 0)
        curve.removePoint(at: 0)
        #expect(curve.points.count == 1)
        while let point = curve.suggestedPoint() { curve.insert(point) }
        #expect(curve.points.count == LightCurve.maxPoints)
        #expect(LightCurve(points: []) == .standard)
    }

    // MARK: LuxFilter

    private static func feed(_ filter: inout LuxFilter, _ values: [Double], from start: ContinuousClock.Instant, every step: Duration = .seconds(1)) -> [Double] {
        values.enumerated().map { index, lux in filter.add(lux, at: start + step * index) }
    }

    @Test("Median filtert einzelne Ausreißer des eingebauten Sensors")
    func medianDropsOutliers() {
        var filter = LuxFilter(.builtIn)
        let out = Self.feed(&filter, [100, 100, 100, 5000, 100, 2, 100], from: .now)
        #expect(out.allSatisfy { abs($0 - 100) < 1 })
    }

    @Test("Stufensprung: kleiner gleitet mit ~4 s, großer anhaltender zieht nach drei Werten nach")
    func emaFollowsStep() {
        let start = ContinuousClock.now
        var filter = LuxFilter(.builtIn)
        _ = Self.feed(&filter, [100, 100, 100, 100, 100], from: start)

        // Faktor 1,5: gleitet, nach 1 s erst ein Teil, nach 20 s fast ganz.
        var small = filter
        let gliding = Self.feed(&small, Array(repeating: 150, count: 20), from: start + .seconds(5))
        #expect(gliding[2] > 100 && gliding[2] < 140)
        #expect(abs(gliding.last! - 150) < 3)

        // Faktor 10: zwei Werte ändern nichts (Median), der dritte zieht den Mittelwert nach.
        var large = filter
        let jump = Self.feed(&large, [1000, 1000, 1000], from: start + .seconds(5))
        #expect(abs(jump[0] - 100) < 1)
        #expect(abs(jump[1] - 100) < 1)
        #expect(abs(jump[2] - 1000) < 1)
    }

    @Test("Schreibtisch-Sensor: Werte gehen unverändert durch, auch einzelne Änderungen")
    func deskSensorPassesThrough() {
        var filter = LuxFilter(.deskSensor)
        let out = Self.feed(&filter, [300, 1000, 20], from: .now, every: .seconds(30))
        #expect(out.map { $0.rounded() } == [300, 1000, 20])
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
