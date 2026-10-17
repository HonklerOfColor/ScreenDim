import Foundation
import Synchronization

/// I2C-Kanal ohne Hardware: zeichnet Writes auf und liefert vorbereitete Antworten.
final class MockTransport: I2CTransport {
    private struct State {
        var written: [[UInt8]] = []
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
            return state.writeResults.isEmpty ? nil : state.writeResults.removeFirst()
        }
        if let error { throw error }
    }

    func read(count: Int) throws(DDCError) -> [UInt8] {
        let reply = state.withLock { state in
            state.replies.isEmpty ? .failure(.readFailed(-1)) : state.replies.removeFirst()
        }
        return try reply.get()
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
        retryDelay: .zero,
        readAttempts: 3,
        writeAttempts: 2,
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
