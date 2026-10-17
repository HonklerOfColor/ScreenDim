import CoreGraphics
import Foundation
import Synchronization

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

/// Software-Dimmung ohne Gamma-Tabellen: merkt sich nur, was gesetzt würde.
@MainActor
final class StubDimmer: SoftwareDimming {
    private(set) var levels: [CGDirectDisplayID: Double] = [:]
    private(set) var reapplied = 0

    nonisolated init() {}

    func apply(_ levels: [CGDirectDisplayID: Double]) {
        self.levels = levels
    }

    func reapply() {
        reapplied += 1
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
