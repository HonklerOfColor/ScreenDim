import Foundation
import Synchronization

/// Lesen und Schreiben von VCP-Werten eines Monitors. Hinter diesem Protokoll lässt
/// sich die Hardware in Tests ersetzen.
protocol DDCControlling: Sendable {
    func read(_ code: VCPCode) async throws(DDCError) -> VCPReading
    func write(_ code: VCPCode, value: UInt16) async throws(DDCError)
}

struct DDCTiming: Sendable {
    /// Mindestabstand zwischen zwei Befehlen an denselben Monitor (DDC/CI: 50 ms).
    var commandGap: Duration
    /// Wartezeit zwischen „Get VCP“ und dem Lesen der Antwort (DDC/CI: 40 ms).
    var replyDelay: Duration
    var retryDelay: Duration
    var readAttempts: Int
    var writeAttempts: Int
    /// Obergrenze pro Operation inklusive Retries. Ein fehlerhafter I2C-Aufruf kann im
    /// Kernel mehrere Sekunden blockieren; der Aufrufer wartet höchstens so lange.
    var deadline: Duration

    static let standard = DDCTiming(
        commandGap: .milliseconds(50),
        replyDelay: .milliseconds(50),
        retryDelay: .milliseconds(150),
        readAttempts: 4,
        writeAttempts: 2,
        deadline: .seconds(3)
    )
}

/// DDC/CI über einen I2C-Kanal. Alle Zugriffe auf den Kanal laufen auf einer eigenen
/// seriellen Queue pro Monitor, damit ein hängender Monitor die anderen nicht blockiert.
final class DDCService: DDCControlling {
    /// So viele Aufrufe dürfen gleichzeitig auf der Queue liegen (auch hängende).
    static let maxPendingCalls = 3

    private let transport: any I2CTransport
    private let queue: DispatchQueue
    private let timing: DDCTiming
    private let state = Mutex(State())

    private struct State {
        var lastCommand: ContinuousClock.Instant?
        var pendingCalls = 0
    }

    init(transport: any I2CTransport, label: String, timing: DDCTiming = .standard) {
        self.transport = transport
        self.timing = timing
        self.queue = DispatchQueue(label: "com.andreastrabi.ScreenDim.ddc.\(label)", qos: .userInitiated)
    }

    func read(_ code: VCPCode) async throws(DDCError) -> VCPReading {
        try await run { deadline throws(DDCError) in
            try self.readBlocking(code.rawValue, until: deadline)
        }
    }

    func write(_ code: VCPCode, value: UInt16) async throws(DDCError) {
        try await run { deadline throws(DDCError) in
            try self.writeBlocking(code.rawValue, value: value, until: deadline)
        }
    }

    // MARK: - Queue und Deadline

    private func run<T: Sendable>(
        _ work: @escaping @Sendable (ContinuousClock.Instant) throws(DDCError) -> T
    ) async throws(DDCError) -> T {
        let admitted = state.withLock { state in
            guard state.pendingCalls < Self.maxPendingCalls else { return false }
            state.pendingCalls += 1
            return true
        }
        guard admitted else { throw .busy }

        let deadline = ContinuousClock.now.advanced(by: timing.deadline)
        let result: Result<T, DDCError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            queue.async {
                let result = Result { () throws(DDCError) -> T in try work(deadline) }
                self.state.withLock { $0.pendingCalls -= 1 }
                once.resume(with: result)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timing.deadline.timeInterval) {
                once.resume(with: .failure(.timeout))
            }
        }
        return try result.get()
    }

    // MARK: - Blockierende Abläufe (nur auf `queue`)

    private func readBlocking(_ code: UInt8, until deadline: ContinuousClock.Instant) throws(DDCError) -> VCPReading {
        let request = DDCPacket.getVCPRequest(code)
        var lastError = DDCError.timeout
        for attempt in 0..<max(timing.readAttempts, 1) {
            if attempt > 0 { pause(timing.retryDelay) }
            guard ContinuousClock.now < deadline else { throw lastError }
            do throws(DDCError) {
                return try exchange { () throws(DDCError) -> VCPReading in
                    try transport.write(request)
                    pause(timing.replyDelay)
                    return try DDCPacket.parseGetVCPReply(transport.read(count: DDCPacket.replyLength), expecting: code)
                }
            } catch {
                // Ein unbekannter VCP-Code wird durch Wiederholen nicht besser.
                if case .unsupportedCode = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func writeBlocking(_ code: UInt8, value: UInt16, until deadline: ContinuousClock.Instant) throws(DDCError) {
        let packet = DDCPacket.setVCPRequest(code, value: value)
        var lastError = DDCError.timeout
        for attempt in 0..<max(timing.writeAttempts, 1) {
            if attempt > 0 { pause(timing.retryDelay) }
            guard ContinuousClock.now < deadline else { throw lastError }
            do throws(DDCError) {
                try exchange { () throws(DDCError) in try transport.write(packet) }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Führt einen Befehl aus und hält dabei den Mindestabstand zum vorherigen ein.
    private func exchange<T>(_ body: () throws(DDCError) -> T) throws(DDCError) -> T {
        if let last = state.withLock({ $0.lastCommand }) {
            pause(timing.commandGap - (ContinuousClock.now - last))
        }
        defer { state.withLock { $0.lastCommand = .now } }
        return try body()
    }

    private func pause(_ duration: Duration) {
        guard duration > .zero else { return }
        Thread.sleep(forTimeInterval: duration.timeInterval)
    }
}

/// Setzt eine Continuation genau einmal fort: entweder mit dem Ergebnis oder mit dem Timeout.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Result<T, DDCError>, Never>?>

    init(_ continuation: CheckedContinuation<Result<T, DDCError>, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, DDCError>) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: result)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
