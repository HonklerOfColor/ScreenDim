import Foundation
import Synchronization

/// Takt des simulierten Sensors: wie lange jemand da ist und wie lange weg.
public struct SimulationSchedule: Equatable, Sendable {
    public var presentFor: Duration
    public var awayFor: Duration

    public init(presentFor: Duration = .seconds(20), awayFor: Duration = .seconds(8)) {
        self.presentFor = presentFor
        self.awayFor = awayFor
    }
}

/// Zustand der Simulation, abhängig nur von der verstrichenen Zeit und dem Seed.
struct SensorSimulation: Sendable {
    static let luxRange = 50.0...600.0
    static let luxPeriod = 120.0
    static let luxNoise = 15.0

    var schedule: SimulationSchedule
    /// Ab hier läuft ein Zyklus „da, dann weg“.
    var cycleStart: Duration = .zero
    /// Vom Regler gesetzt; ersetzt den Sinus.
    var luxOverride: Double?
    private var random: SplitMix64
    private var lastPresence: Bool?

    init(schedule: SimulationSchedule, seed: UInt64) {
        self.schedule = schedule
        random = SplitMix64(seed: seed)
    }

    func presence(at time: Duration) -> Bool {
        let present = schedule.presentFor.timeInterval
        let cycle = present + schedule.awayFor.timeInterval
        guard cycle > 0 else { return true }
        let position = (time - cycleStart).timeInterval.truncatingRemainder(dividingBy: cycle)
        return (position < 0 ? position + cycle : position) < present
    }

    /// Sinus zwischen 50 und 600 lx (Periode 2 min) mit Rauschen.
    mutating func lux(at time: Duration) -> Double {
        if let luxOverride { return luxOverride }
        let middle = (Self.luxRange.lowerBound + Self.luxRange.upperBound) / 2
        let amplitude = (Self.luxRange.upperBound - Self.luxRange.lowerBound) / 2 - Self.luxNoise
        let wave = middle + amplitude * sin(2 * .pi * time.timeInterval / Self.luxPeriod)
        let noise = (random.nextUnit() * 2 - 1) * Self.luxNoise
        return min(max(wave + noise, Self.luxRange.lowerBound), Self.luxRange.upperBound)
    }

    /// Ereignisse eines Takts: Anwesenheit bei Änderung, Lux immer.
    mutating func step(at time: Duration) -> [SensorEvent] {
        var events: [SensorEvent] = []
        let presence = presence(at: time)
        if presence != lastPresence {
            lastPresence = presence
            events.append(.presence(presence))
        }
        events.append(.lux((lux(at: time) * 10).rounded() / 10))
        return events
    }

    /// „Weg“ beginnt nach `lead`; dann läuft der Zyklus normal weiter.
    mutating func simulateAway(at time: Duration, lead: Duration) {
        cycleStart = time + lead - schedule.presentFor
    }

    /// Sofort wieder da.
    mutating func simulateBack(at time: Duration) {
        cycleStart = time
    }
}

/// Deterministischer Zufall (SplitMix64), damit Tests mit festem Seed gleiche Werte sehen.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// Simulierter Sensor für den Demo-Modus: gleiche Schnittstelle wie der echte, ohne Netz.
/// Meldet sofort „verbunden“, danach jede Sekunde Lux und bei Wechsel die Anwesenheit.
public final class SimulatedSensorSource: SensorSource {
    public static let tick: Duration = .seconds(1)
    /// Vorlauf von „Simulieren: weg“: Der Klick selbst ist eine Eingabe und würde die
    /// Abdunklung sonst sofort verhindern.
    public static let awayLead: Duration = .seconds(3)

    private let state: Mutex<SensorSimulation>
    private let elapsed: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init<C: Clock<Duration>>(
        schedule: SimulationSchedule = SimulationSchedule(),
        seed: UInt64 = .random(in: .min ... .max),
        clock: C = ContinuousClock()
    ) {
        state = Mutex(SensorSimulation(schedule: schedule, seed: seed))
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
    }

    public func events() -> AsyncStream<SensorEvent> {
        // Bei 1 Hz läuft der Puffer nie voll; mit einer Test-Uhr bleiben so die ersten
        // Ereignisse erhalten.
        AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task { [self] in
                continuation.yield(.connection(.connected))
                while !Task.isCancelled {
                    let now = elapsed()
                    for event in state.withLock({ $0.step(at: now) }) {
                        if case .terminated = continuation.yield(event) { return }
                    }
                    do { try await sleep(Self.tick) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var schedule: SimulationSchedule {
        get { state.withLock { $0.schedule } }
        set { state.withLock { $0.schedule = newValue } }
    }

    public func simulateAway() {
        let now = elapsed()
        state.withLock { $0.simulateAway(at: now, lead: Self.awayLead) }
    }

    public func simulateBack() {
        let now = elapsed()
        state.withLock { $0.simulateBack(at: now) }
    }

    /// `nil`: wieder Sinus.
    public func setLux(_ lux: Double?) {
        state.withLock { $0.luxOverride = lux }
    }
}
