import CoreGraphics
import Foundation
import Synchronization
@testable import ScreenDimKit

/// I2C-Kanal ohne Hardware: zeichnet Writes auf und liefert vorbereitete Antworten.
final class MockTransport: I2CTransport {
    enum Event: Equatable {
        case write([UInt8])
        case read
    }

    private struct State {
        var written: [[UInt8]] = []
        var events: [(event: Event, at: ContinuousClock.Instant)] = []
        var writeResults: [DDCError?] = []
        var replies: [Result<[UInt8], DDCError>] = []
    }

    private let state = Mutex(State())
    /// Wenn gesetzt, blockiert jeder Write, bis das Semaphor signalisiert wird (simuliert
    /// einen im Kernel hängenden I2C-Aufruf).
    let blocker: DispatchSemaphore?

    init(blocker: DispatchSemaphore? = nil) {
        self.blocker = blocker
    }

    var written: [[UInt8]] { state.withLock { $0.written } }
    var events: [(event: Event, at: ContinuousClock.Instant)] { state.withLock { $0.events } }

    func enqueueWriteResult(_ error: DDCError?) {
        state.withLock { $0.writeResults.append(error) }
    }

    func enqueueReply(_ reply: Result<[UInt8], DDCError>) {
        state.withLock { $0.replies.append(reply) }
    }

    func write(_ bytes: [UInt8]) throws(DDCError) {
        blocker?.wait()
        let error = state.withLock { state -> DDCError? in
            state.written.append(bytes)
            state.events.append((.write(bytes), .now))
            return state.writeResults.isEmpty ? nil : state.writeResults.removeFirst()
        }
        if let error { throw error }
    }

    func read(count: Int) throws(DDCError) -> [UInt8] {
        let reply = state.withLock { state in
            state.events.append((.read, .now))
            return state.replies.isEmpty ? .failure(.readFailed(-1)) : state.replies.removeFirst()
        }
        return try reply.get()
    }
}

/// Steuerkanal ohne DDC-Schicht für DisplayManager-Tests.
final class StubControl: DDCControlling {
    private struct State {
        var readResult: Result<VCPReading, DDCError>
        var reads = 0
        var writes: [UInt16] = []
    }

    private let state: Mutex<State>

    init(read: Result<VCPReading, DDCError> = .success(VCPReading(current: 50, maximum: 100))) {
        state = Mutex(State(readResult: read))
    }

    var reads: Int { state.withLock { $0.reads } }
    var writes: [UInt16] { state.withLock { $0.writes } }

    func setRead(_ result: Result<VCPReading, DDCError>) {
        state.withLock { $0.readResult = result }
    }

    func read(_ code: VCPCode) async throws(DDCError) -> VCPReading {
        let result = state.withLock { state in
            state.reads += 1
            return state.readResult
        }
        return try result.get()
    }

    func write(_ code: VCPCode, value: UInt16) async throws(DDCError) {
        state.withLock { $0.writes.append(value) }
    }
}

/// Steuerkanal, dessen Reads warten, bis `release(with:)` sie freigibt: Der Monitor bleibt
/// so lange in der Prüfung.
final class GatedControl: DDCControlling {
    private struct State {
        var result: Result<VCPReading, DDCError>?
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func release(with result: Result<VCPReading, DDCError>) {
        let waiting = state.withLock { state in
            state.result = result
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func read(_ code: VCPCode) async throws(DDCError) -> VCPReading {
        await withCheckedContinuation { continuation in
            let released = state.withLock { state in
                if state.result == nil { state.waiting.append(continuation) }
                return state.result != nil
            }
            if released { continuation.resume() }
        }
        return try state.withLock { $0.result! }.get()
    }

    func write(_ code: VCPCode, value: UInt16) async throws(DDCError) {}
}

/// Software-Dimmung ohne Gamma-Tabellen und Fenster: merkt sich nur, was gesetzt würde.
@MainActor
final class StubDimmer: SoftwareDimming {
    private(set) var levels: [CGDirectDisplayID: Double] = [:]
    private(set) var reapplied = 0
    private(set) var refreshed: [Set<CGDirectDisplayID>] = []
    /// Displays, bei denen das Verfahren nicht greift (z. B. Gamma-Tabelle nicht lesbar).
    var failing: Set<CGDirectDisplayID> = []

    nonisolated init() {}

    func apply(_ levels: [CGDirectDisplayID: Double]) -> Set<CGDirectDisplayID> {
        let failed = failing.intersection(levels.keys)
        self.levels = levels.filter { !failed.contains($0.key) }
        return failed
    }

    func reapply() {
        reapplied += 1
    }

    func refresh(_ displays: Set<CGDirectDisplayID>) {
        refreshed.append(displays)
    }
}

/// Gamma-Tabellen im Speicher: Lineare Kurve mit vier Stützstellen je Display.
final class StubGammaTables: GammaTableAccess {
    private struct State {
        var tables: [CGDirectDisplayID: GammaTable] = [:]
        var unreadable: Set<CGDirectDisplayID> = []
        /// Lesbar, aber jeder Write scheitert (etwa während einer Umkonfiguration).
        var unwritable: Set<CGDirectDisplayID> = []
        var writes = 0
        var colorSyncResets = 0
    }

    private let state = Mutex(State())
    static let identity = GammaTable(red: [0, 0.25, 0.5, 1], green: [0, 0.25, 0.5, 1], blue: [0, 0.25, 0.5, 1])

    init(displays: [CGDirectDisplayID], unreadable: Set<CGDirectDisplayID> = []) {
        state.withLock { state in
            for id in displays { state.tables[id] = Self.identity }
            state.unreadable = unreadable
        }
    }

    var writes: Int { state.withLock { $0.writes } }
    var colorSyncResets: Int { state.withLock { $0.colorSyncResets } }
    func table(_ id: CGDirectDisplayID) -> GammaTable? { state.withLock { $0.tables[id] } }

    /// Simuliert, dass macOS die Kurve zurückgesetzt hat (z. B. Auflösungswechsel).
    func resetByMacOS(_ id: CGDirectDisplayID) {
        state.withLock { $0.tables[id] = Self.identity }
    }

    /// Ab jetzt scheitern Writes an diese Displays; Reads gehen weiter.
    func failWrites(to ids: Set<CGDirectDisplayID>) {
        state.withLock { $0.unwritable = ids }
    }

    func read(_ id: CGDirectDisplayID) -> GammaTable? {
        state.withLock { $0.unreadable.contains(id) ? nil : $0.tables[id] }
    }

    func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool {
        state.withLock { state in
            guard !state.unreadable.contains(id), !state.unwritable.contains(id), state.tables[id] != nil else { return false }
            state.writes += 1
            state.tables[id] = table
            return true
        }
    }

    func restoreColorSync() {
        state.withLock { state in
            state.colorSyncResets += 1
            for id in state.tables.keys { state.tables[id] = Self.identity }
        }
    }
}

/// Overlay-Fenster ohne AppKit.
@MainActor
final class StubOverlayWindow: OverlayWindow {
    private(set) var alpha: Double?
    private(set) var frameUpdates = 0
    private(set) var isClosed = false

    func show(alpha: Double) {
        self.alpha = alpha
    }

    func updateFrame() {
        frameUpdates += 1
    }

    func close() {
        isClosed = true
    }
}

/// Einstellungen im RAM. Tests benutzen keine UserDefaults-Suites: Selbst nach
/// `removePersistentDomain` legt `cfprefsd` die Plist asynchron in ~/Library/Preferences an.
final class MemoryPreferences: PreferenceStorage {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }
}

/// Ersetzt `Task.sleep`: Jeder Aufruf wartet, bis der Test `wake()` ruft.
final class ManualSleeper: Sendable {
    let started: AsyncStream<Duration>
    private let startedContinuation: AsyncStream<Duration>.Continuation
    private let sleepers = Mutex<[CheckedContinuation<Void, Never>]>([])

    init() {
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            sleepers.withLock { $0.append(continuation) }
            startedContinuation.yield(duration)
        }
    }

    func wake() {
        let waiting = sleepers.withLock { sleepers in
            defer { sleepers.removeAll() }
            return sleepers
        }
        waiting.forEach { $0.resume() }
    }
}

extension DDCTiming {
    static let immediate = DDCTiming(
        commandGap: .zero,
        replyDelay: .zero,
        nullReplyDelay: .zero,
        retryDelay: .zero,
        readAttempts: 3,
        writeAttempts: 2,
        writeRepeats: 1,
        writeRepeatGap: .zero,
        primeAfterRead: false,
        deadline: .seconds(5)
    )
}

enum Replies {
    static func brightness(current: UInt16, maximum: UInt16 = 100) -> [UInt8] {
        let body: [UInt8] = [
            0x6E, 0x88, 0x02, 0x00, 0x10, 0x00,
            UInt8(maximum >> 8), UInt8(maximum & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF),
        ]
        return body + [DDCPacket.checksum(body, seed: 0x50)]
    }

    static let null: [UInt8] = [0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0]
}

/// Wartet (mit Obergrenze), bis eine Bedingung gilt. Läuft in der Isolation des Aufrufers.
func eventually(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration = .seconds(3),
    _ condition: () async -> Bool
) async -> Bool {
    let end = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Sensor

/// Uhr ohne Wartezeit: `sleep` springt sofort zum Ziel. Für deterministische Simulationen.
final class InstantClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private let current = Mutex(Instant(offset: .zero))

    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        current.withLock { $0 = max($0, deadline) }
        await Task.yield()
    }
}

/// Eingespeiste Uhr für den `SensorController`: steht, bis der Test sie vorstellt.
@MainActor
final class ManualNow {
    private(set) var instant = ContinuousClock.now

    func advance(by duration: Duration) {
        instant = instant + duration
    }
}

/// Sensorquelle, deren Ereignisse der Test schickt.
final class StubSensorSource: SensorSource {
    private let stream: AsyncStream<SensorEvent>
    private let continuation: AsyncStream<SensorEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<SensorEvent> {
        stream
    }

    func send(_ events: SensorEvent...) {
        events.forEach { continuation.yield($0) }
    }
}

/// HTTP ohne Netz: Antworten je Pfad (`sensor/Ambient Light`), der Reihe nach; danach
/// `.unreachable`.
final class StubSensorHTTP: SensorHTTP {
    private struct State {
        var responses: [String: [SensorResponse]] = [:]
        var requests: [(path: String, password: String?)] = []
    }

    private let state = Mutex(State())

    var requests: [(path: String, password: String?)] { state.withLock { $0.requests } }

    func enqueue(_ response: SensorResponse, for path: String) {
        state.withLock { $0.responses[path, default: []].append(response) }
    }

    func get(_ url: URL, password: String?) async -> SensorResponse {
        let path = String(url.path().removingPercentEncoding?.dropFirst() ?? "")
        return state.withLock { state in
            state.requests.append((path, password))
            guard var queue = state.responses[path], !queue.isEmpty else { return .unreachable }
            let response = queue.removeFirst()
            state.responses[path] = queue
            return response
        }
    }
}

/// Schlüsselbund im RAM.
final class MemoryCredentials: SensorCredentialStore {
    private let codes = Mutex<[String: PairingCode]>([:])
    /// Gesetzt: Jedes Lesen wirft diesen Status (Schlüsselbund gesperrt).
    let readFailure = Mutex<OSStatus?>(nil)

    var stored: [String: PairingCode] { codes.withLock { $0 } }

    func code(for hostname: String) throws(SensorKeychain.Failure) -> PairingCode? {
        if let status = readFailure.withLock({ $0 }) { throw SensorKeychain.Failure(status: status) }
        return codes.withLock { $0[hostname] }
    }

    func save(_ code: PairingCode, for hostname: String) throws(SensorKeychain.Failure) {
        codes.withLock { $0[hostname] = code }
    }

    func delete(_ hostname: String) {
        codes.withLock { $0[hostname] = nil }
    }
}

/// Eingaben auf Zuruf.
@MainActor
final class StubInput: InputActivityMonitoring {
    var timeSinceLastInput: Duration = .seconds(60)
    private(set) var onInput: (@MainActor () -> Void)?

    nonisolated init() {}

    func startObserving(_ onInput: @escaping @MainActor () -> Void) {
        self.onInput = onInput
    }

    func stopObserving() {
        onInput = nil
    }

    var isObserving: Bool { onInput != nil }

    /// Simuliert eine Mausbewegung.
    func fire() {
        onInput?()
    }
}

/// Merkt sich, welche Displays schwarz wären.
@MainActor
final class StubBlanker: ScreenBlanking {
    private(set) var blanked: Set<CGDirectDisplayID> = []
    private(set) var refreshed: [Set<CGDirectDisplayID>] = []

    nonisolated init() {}

    func blank(_ displays: Set<CGDirectDisplayID>) {
        blanked = displays
    }

    func refresh(_ displays: Set<CGDirectDisplayID>) {
        refreshed.append(displays)
    }
}
