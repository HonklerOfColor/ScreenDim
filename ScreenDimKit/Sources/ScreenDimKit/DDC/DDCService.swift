import Foundation
import Synchronization

/// Lesen und Schreiben von VCP-Werten eines Monitors. Hinter diesem Protokoll lässt
/// sich die Hardware in Tests ersetzen.
public protocol DDCControlling: Sendable {
    func read(_ code: VCPCode) async throws(DDCError) -> VCPReading
    func write(_ code: VCPCode, value: UInt16) async throws(DDCError)
    /// Letzte I2C-Ergebnisse; `nil`, wenn der Kanal kein I2C benutzt (eingebautes Display).
    var diagnostics: DDCDiagnostics? { get }
}

extension DDCControlling {
    public var diagnostics: DDCDiagnostics? { nil }
}

public struct DDCTiming: Equatable, Sendable {
    /// Mindestabstand zwischen zwei Befehlen an denselben Monitor (DDC/CI: 50 ms).
    public var commandGap: Duration
    /// Wartezeit zwischen „Get VCP“ und dem Lesen der Antwort (DDC/CI: 40 ms).
    public var replyDelay: Duration
    /// Wartezeit im nächsten Versuch, nachdem der Monitor eine Null-Message geschickt hat.
    public var nullReplyDelay: Duration
    public var retryDelay: Duration
    public var readAttempts: Int
    public var writeAttempts: Int
    /// So oft geht jedes Set-VCP-Paket hinaus (1 oder 2). Manche Monitore hinter
    /// MST-Hubs übernehmen den Wert erst beim zweiten Paket. Vorsicht: Der S34CG50 hat
    /// einen zweiten Write nach 10 ms genackt und danach im Kernel gehangen.
    public var writeRepeats: Int
    public var writeRepeatGap: Duration
    /// Vorlauf-Write: Folgte die letzte Übertragung auf einen Read, geht jedes Paket
    /// zweimal hinaus (Abstand `writeRepeatGap`). Auf Apple Silicon kommt der erste
    /// Write nach einem Read beim Monitor nicht an: W-R-W-R bleibt Null-Message, W-W-R
    /// antwortet, auch bei 160 ms Abstand; ein einzelner Set-VCP nach einem Read ging
    /// verloren (JapanNext 6K und U28E590 direkt am Mac, 2026-11-03). Frische Kanäle
    /// antworteten nur deshalb, weil vor dem ersten Write kein Read lag.
    /// Aus per `defaults write … ddc.primeAfterRead -bool NO`, etwa wenn ein Monitor
    /// hinter einem Dock den zweiten Write nackt (S34CG50).
    public var primeAfterRead: Bool
    /// Obergrenze pro Operation inklusive Retries. Ein fehlerhafter I2C-Aufruf kann im
    /// Kernel mehrere Sekunden blockieren; der Aufrufer wartet höchstens so lange.
    public var deadline: Duration

    public static let standard = DDCTiming(
        commandGap: .milliseconds(50),
        replyDelay: .milliseconds(50),
        nullReplyDelay: .milliseconds(120),
        retryDelay: .milliseconds(150),
        readAttempts: 4,
        writeAttempts: 2,
        writeRepeats: 1,
        writeRepeatGap: .milliseconds(10),
        primeAfterRead: true,
        deadline: .seconds(3)
    )

    /// `standard`, einzelne Werte aus den UserDefaults überschrieben, z. B.
    /// `defaults write com.andreastrabi.ScreenDim ddc.writeRepeats -int 2`.
    public static func configured(from defaults: UserDefaults, base: DDCTiming = .standard) -> DDCTiming {
        configured(from: defaults as any PreferenceStorage, base: base)
    }

    static func configured(from defaults: any PreferenceStorage, base: DDCTiming = .standard) -> DDCTiming {
        func number(_ key: String) -> Int? { (defaults.object(forKey: "ddc.\(key)") as? NSNumber)?.intValue }
        func milliseconds(_ key: String) -> Duration? { number(key).map { .milliseconds(max($0, 0)) } }

        var timing = base
        timing.commandGap = milliseconds("commandGapMs") ?? timing.commandGap
        timing.replyDelay = milliseconds("replyDelayMs") ?? timing.replyDelay
        timing.nullReplyDelay = milliseconds("nullReplyDelayMs") ?? timing.nullReplyDelay
        timing.retryDelay = milliseconds("retryDelayMs") ?? timing.retryDelay
        timing.readAttempts = number("readAttempts").map { max($0, 1) } ?? timing.readAttempts
        timing.writeAttempts = number("writeAttempts").map { max($0, 1) } ?? timing.writeAttempts
        timing.writeRepeats = number("writeRepeats").map { min(max($0, 1), 2) } ?? timing.writeRepeats
        timing.writeRepeatGap = milliseconds("writeRepeatGapMs") ?? timing.writeRepeatGap
        timing.primeAfterRead = number("primeAfterRead").map { $0 != 0 } ?? timing.primeAfterRead
        timing.deadline = milliseconds("deadlineMs").map { max($0, .milliseconds(100)) } ?? timing.deadline
        return timing
    }
}

/// DDC/CI über einen I2C-Kanal. Alle Zugriffe auf den Kanal laufen auf einer eigenen
/// seriellen Queue pro Monitor, damit ein hängender Monitor die anderen nicht blockiert.
///
/// Überschreitet ein Aufruf seine Deadline, während er auf der Queue läuft, gilt der
/// Kanal als hängend: Der Aufrufer bekommt `.timeout`, wartende Aufrufe sofort `.hung`,
/// und neue Aufrufe werden mit `.hung` abgelehnt, bis der hängende I2C-Aufruf
/// zurückkehrt. So reiht sich nichts hinter einem Hänger ein.
public final class DDCService: DDCControlling {
    /// So viele Aufrufe dürfen gleichzeitig auf der Queue liegen.
    static let maxPendingCalls = 3

    public let label: String
    public let timing: DDCTiming
    private let transport: any I2CTransport
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private struct State {
        var lastCommand: ContinuousClock.Instant?
        var nextCallID: UInt64 = 0
        /// Angenommene Aufrufe, deren Block auf `queue` noch nicht beendet ist. Ein Eintrag
        /// verschwindet genau einmal: wenn sein Block endet oder übersprungen wird.
        var calls: [UInt64: PendingCall] = [:]
        var runningCallID: UInt64?
        /// Gesetzt, sobald der laufende Aufruf seine Deadline überschritten hat.
        var hungSince: (instant: ContinuousClock.Instant, date: Date)?
        var diagnostics = DDCDiagnostics()
        /// Zu Beginn unbekannt (etwa nach Neustart der App am selben Proxy), also wie
        /// nach einem Read behandeln.
        var lastTransferWasRead = true
    }

    private struct PendingCall {
        let operation: String
        let deadline: ContinuousClock.Instant
        /// Beantwortet den Aufrufer vorzeitig (Timeout oder Hänger).
        let fail: @Sendable (DDCError) -> Void
        /// Der Aufrufer hat seine Antwort schon; das echte Ergebnis wird nur noch geloggt.
        var answered = false
    }

    public init(transport: any I2CTransport, label: String, timing: DDCTiming = .standard) {
        self.transport = transport
        self.label = label
        self.timing = timing
        self.queue = DispatchQueue(label: "com.andreastrabi.ScreenDim.ddc.\(label)", qos: .userInitiated)
    }

    /// Aufrufe, die angenommen und noch nicht beendet sind (laufend, wartend, hängend).
    var pendingCalls: Int { state.withLock { $0.calls.count } }

    var isHung: Bool { state.withLock { $0.hungSince != nil } }

    public var diagnostics: DDCDiagnostics? {
        state.withLock { state in
            var snapshot = state.diagnostics
            snapshot.pendingCalls = state.calls.count
            snapshot.hungSince = state.hungSince?.date
            return snapshot
        }
    }

    public func read(_ code: VCPCode) async throws(DDCError) -> VCPReading {
        try await run("Read 0x\(Self.hex(code.rawValue))") { deadline throws(DDCError) in
            let started = ContinuousClock.now
            do throws(DDCError) {
                let reading = try self.readBlocking(code.rawValue, until: deadline)
                self.record(.read, code, value: reading.current, maximum: reading.maximum, error: nil, since: started)
                return reading
            } catch {
                self.record(.read, code, value: nil, maximum: nil, error: error, since: started)
                throw error
            }
        }
    }

    public func write(_ code: VCPCode, value: UInt16) async throws(DDCError) {
        try await run("Write 0x\(Self.hex(code.rawValue)) = \(value)") { deadline throws(DDCError) in
            let started = ContinuousClock.now
            do throws(DDCError) {
                try self.writeBlocking(code.rawValue, value: value, until: deadline)
                self.record(.write, code, value: value, maximum: nil, error: nil, since: started)
            } catch {
                self.record(.write, code, value: value, maximum: nil, error: error, since: started)
                throw error
            }
        }
    }

    // MARK: - Queue, Deadline und Hänger

    private func run<T: Sendable>(
        _ operation: String,
        _ work: @escaping @Sendable (ContinuousClock.Instant) throws(DDCError) -> T
    ) async throws(DDCError) -> T {
        let deadline = ContinuousClock.now.advanced(by: timing.deadline)
        let result: Result<T, DDCError> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // Zulassung und Eintrag in einem Lock: Getrennt könnten gleichzeitige Aufrufe
            // alle die Zählung bestehen und zusammen `maxPendingCalls` überschreiten.
            let admission = state.withLock { state -> Result<UInt64, DDCError> in
                if state.hungSince != nil { return .failure(.hung) }
                guard state.calls.count < Self.maxPendingCalls else { return .failure(.busy) }
                state.nextCallID += 1
                let id = state.nextCallID
                state.calls[id] = PendingCall(operation: operation, deadline: deadline, fail: { once.resume(with: .failure($0)) })
                return .success(id)
            }
            switch admission {
            case .failure(let error):
                ddcLog.notice("\(self.label, privacy: .public) \(operation, privacy: .public): abgelehnt (\(error.description, privacy: .public))")
                once.resume(with: .failure(error))
            case .success(let id):
                queue.async {
                    self.execute(id, operation, deadline: deadline, once: once, work: work)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timing.deadline.timeInterval) {
                    self.deadlinePassed(id, operation)
                }
            }
        }
        return try result.get()
    }

    /// Läuft auf `queue`.
    private func execute<T: Sendable>(
        _ id: UInt64,
        _ operation: String,
        deadline: ContinuousClock.Instant,
        once: ResumeOnce<T>,
        work: (ContinuousClock.Instant) throws(DDCError) -> T
    ) {
        let proceed = state.withLock { state -> Bool in
            guard let call = state.calls[id] else { return false }
            if call.answered {
                // Der Aufrufer hat schon `.timeout` oder `.hung` bekommen: nicht mehr an
                // den Monitor schicken.
                state.calls[id] = nil
                return false
            }
            state.runningCallID = id
            return true
        }
        guard proceed else {
            ddcLog.info("\(self.label, privacy: .public) \(operation, privacy: .public): übersprungen, Aufrufer hat schon eine Antwort")
            return
        }

        let started = ContinuousClock.now
        let result = Result { () throws(DDCError) -> T in try work(deadline) }
        let duration = ContinuousClock.now - started

        let (answered, hungSince) = state.withLock { state in
            let answered = state.calls.removeValue(forKey: id)?.answered ?? true
            state.runningCallID = nil
            defer { state.hungSince = nil }
            return (answered, state.hungSince)
        }
        if answered {
            let outcome = Self.describe(result)
            let overdue = hungSince.map { ContinuousClock.now - $0.instant } ?? .zero
            ddcLog.error("\(self.label, privacy: .public) \(operation, privacy: .public): hängender Aufruf zurück nach \(duration.milliseconds) ms (\(overdue.milliseconds) ms über der Deadline): \(outcome, privacy: .public). Kanal wieder frei.")
        } else {
            once.resume(with: result)
        }
    }

    private func deadlinePassed(_ id: UInt64, _ operation: String) {
        typealias Failure = (fail: @Sendable (DDCError) -> Void, error: DDCError)
        let (failures, hungOperation) = state.withLock { state -> ([Failure], String?) in
            guard let call = state.calls[id], !call.answered else { return ([], nil) }
            // Die Timer feuern nicht zwingend in Startreihenfolge. Ist der laufende Aufruf
            // ebenfalls über seiner Deadline, hängt der Kanal, egal welcher Timer zuerst kommt.
            if let runningID = state.runningCallID, let running = state.calls[runningID],
               !running.answered, running.deadline <= .now {
                return (Self.markHung(runningID, in: &state), running.operation)
            }
            state.calls[id]?.answered = true
            return ([(call.fail, .timeout)], nil)
        }
        if let hungOperation {
            ddcLog.error("\(self.label, privacy: .public) \(hungOperation, privacy: .public): Deadline \(self.timing.deadline.milliseconds) ms überschritten, I2C-Aufruf hängt. Kanal gesperrt, \(failures.count - 1) wartende Aufrufe abgebrochen.")
        } else if !failures.isEmpty {
            ddcLog.error("\(self.label, privacy: .public) \(operation, privacy: .public): Deadline \(self.timing.deadline.milliseconds) ms überschritten, bevor der Aufruf drankam")
        }
        for failure in failures {
            failure.fail(failure.error)
        }
    }

    /// Sperrt den Kanal: Der laufende Aufruf bekommt `.timeout`, alle wartenden `.hung`.
    private static func markHung(
        _ runningID: UInt64,
        in state: inout State
    ) -> [(fail: @Sendable (DDCError) -> Void, error: DDCError)] {
        state.hungSince = (.now, Date())
        var failures: [(fail: @Sendable (DDCError) -> Void, error: DDCError)] = []
        for (id, call) in state.calls where !call.answered {
            state.calls[id]?.answered = true
            failures.append((call.fail, id == runningID ? .timeout : .hung))
        }
        return failures
    }

    // MARK: - Blockierende Abläufe (nur auf `queue`)

    private func readBlocking(_ code: UInt8, until deadline: ContinuousClock.Instant) throws(DDCError) -> VCPReading {
        let request = DDCPacket.getVCPRequest(code)
        var lastError = DDCError.timeout
        var replyDelay = timing.replyDelay
        for attempt in 0..<max(timing.readAttempts, 1) {
            if attempt > 0 { pause(timing.retryDelay) }
            guard ContinuousClock.now < deadline else { throw lastError }
            do throws(DDCError) {
                return try exchange { () throws(DDCError) -> VCPReading in
                    try send(request)
                    pause(replyDelay)
                    let reply = try transferRead(count: DDCPacket.replyLength)
                    return try parse(reply, expecting: code)
                }
            } catch {
                // Ein unbekannter VCP-Code wird durch Wiederholen nicht besser.
                if case .unsupportedCode = error { throw error }
                // Null-Message: Der Monitor war womöglich nur noch nicht fertig.
                if case .nullReply = error { replyDelay = timing.nullReplyDelay }
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
                try exchange { () throws(DDCError) in
                    try send(packet)
                    for _ in 1..<max(timing.writeRepeats, 1) {
                        pause(timing.writeRepeatGap)
                        try transferWrite(packet)
                    }
                }
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

    // MARK: - I2C mit Logging

    /// Schickt ein Paket, nach einem Read mit Vorlauf-Write (siehe `DDCTiming.primeAfterRead`).
    private func send(_ packet: [UInt8]) throws(DDCError) {
        if timing.primeAfterRead, state.withLock({ $0.lastTransferWasRead }) {
            try transferWrite(packet, priming: true)
            pause(timing.writeRepeatGap)
        }
        try transferWrite(packet)
    }

    private func transferWrite(_ packet: [UInt8], priming: Bool = false) throws(DDCError) {
        let started = ContinuousClock.now
        let outcome = Result { () throws(DDCError) in try transport.write(packet) }
        let duration = ContinuousClock.now - started
        let error = outcome.failure
        record(I2CTransferRecord(direction: .write, status: Self.status(error), error: error, duration: duration, bytes: packet, date: Date()))

        let status = Self.statusText(error)
        let kind = priming ? "I2C-Vorlauf-Write" : "I2C-Write"
        if let error {
            ddcLog.error("\(self.label, privacy: .public) \(kind, privacy: .public) [\(packet.hexString, privacy: .public)]: \(status, privacy: .public), \(duration.milliseconds) ms")
            throw error
        }
        ddcLog.info("\(self.label, privacy: .public) \(kind, privacy: .public) [\(packet.hexString, privacy: .public)]: \(status, privacy: .public), \(duration.milliseconds) ms")
    }

    private func transferRead(count: Int) throws(DDCError) -> [UInt8] {
        let started = ContinuousClock.now
        let outcome = Result { () throws(DDCError) -> [UInt8] in try transport.read(count: count) }
        let duration = ContinuousClock.now - started
        let error = outcome.failure
        let reply = (try? outcome.get()) ?? []
        record(I2CTransferRecord(direction: .read, status: Self.status(error), error: error, duration: duration, bytes: reply, date: Date()))

        let status = Self.statusText(error)
        if let error {
            ddcLog.error("\(self.label, privacy: .public) I2C-Read \(count) Bytes: \(status, privacy: .public), \(duration.milliseconds) ms")
            throw error
        }
        ddcLog.info("\(self.label, privacy: .public) I2C-Read \(count) Bytes: \(status, privacy: .public), \(duration.milliseconds) ms")
        return reply
    }

    private func parse(_ reply: [UInt8], expecting code: UInt8) throws(DDCError) -> VCPReading {
        do throws(DDCError) {
            let reading = try DDCPacket.parseGetVCPReply(reply, expecting: code)
            ddcLog.info("\(self.label, privacy: .public) VCP 0x\(Self.hex(code), privacy: .public) = \(reading.current)/\(reading.maximum)")
            return reading
        } catch {
            switch error {
            case .nullReply, .checksumMismatch, .malformedReply:
                ddcLog.notice("\(self.label, privacy: .public) Antwort \(error.description, privacy: .public): [\(reply.hexString, privacy: .public)]")
            default:
                break
            }
            throw error
        }
    }

    // MARK: - Diagnose

    private func record(_ transfer: I2CTransferRecord) {
        state.withLock { state in
            state.lastTransferWasRead = transfer.direction == .read
            switch transfer.direction {
            case .write: state.diagnostics.lastWrite = transfer
            case .read: state.diagnostics.lastRead = transfer
            }
        }
    }

    private func record(
        _ kind: DDCOperationRecord.Kind, _ code: VCPCode,
        value: UInt16?, maximum: UInt16?, error: DDCError?, since started: ContinuousClock.Instant
    ) {
        let operation = DDCOperationRecord(
            kind: kind, code: code.rawValue, value: value, maximum: maximum, error: error,
            duration: ContinuousClock.now - started, date: Date()
        )
        state.withLock { state in
            switch kind {
            case .read: state.diagnostics.lastReadOperation = operation
            case .write: state.diagnostics.lastWriteOperation = operation
            }
        }
    }

    /// IOReturn eines Transfers: 0 bei Erfolg, `nil`, wenn der Fehler nicht von IOKit kommt.
    private static func status(_ error: DDCError?) -> Int32? {
        guard let error else { return 0 }
        return error.ioReturn
    }

    private static func statusText(_ error: DDCError?) -> String {
        if let status = status(error) { return IOReturnDescription.describe(status) }
        return error?.description ?? "?"
    }

    private static func describe<T>(_ result: Result<T, DDCError>) -> String {
        switch result {
        case .success: "Erfolg, \(IOReturnDescription.describe(0))"
        case .failure(let error): error.description
        }
    }

    private static func hex(_ byte: UInt8) -> String {
        String(format: "%02X", byte)
    }
}

/// Setzt eine Continuation genau einmal fort: entweder mit dem Ergebnis oder vorzeitig
/// mit Timeout bzw. Hänger.
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

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
