import Foundation
import Testing
@testable import ScreenDimKit

@Suite("DDCService mit Mock-Transport")
struct DDCServiceTests {
    @Test("Write schickt genau ein Set-VCP-Paket")
    func writeSendsPacket() async throws {
        let transport = MockTransport()
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        try await service.write(.brightness, value: 50)

        #expect(transport.written == [[0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]])
    }

    @Test("Vorlauf-Write: nach einem Read doppelt, nach einem Write einfach, zu Beginn doppelt")
    func primeAfterRead() async throws {
        let transport = MockTransport()
        var timing = DDCTiming.immediate
        timing.primeAfterRead = true
        let service = DDCService(transport: transport, label: "test", timing: timing)
        let request: [UInt8] = [0x82, 0x01, 0x10, 0xAC]
        let set50 = DDCPacket.setVCPRequest(0x10, value: 50)
        let set60 = DDCPacket.setVCPRequest(0x10, value: 60)

        // Vorgeschichte unbekannt: Vorlauf. Danach Read, also wieder Vorlauf vor dem Set.
        transport.enqueueReply(.success(Replies.brightness(current: 50)))
        let reading = try await service.read(.brightness)
        #expect(reading.current == 50)
        #expect(transport.written == [request, request])

        try await service.write(.brightness, value: 50)
        #expect(transport.written == [request, request, set50, set50])

        // Write nach Write: kein Vorlauf (Regler, Überblendung).
        try await service.write(.brightness, value: 60)
        #expect(transport.written == [request, request, set50, set50, set60])

        // Read nach Write: erster Versuch ohne Vorlauf; nach der Null-Message (ein Read)
        // bekommt der zweite Versuch ihn wieder.
        transport.enqueueReply(.success(Replies.null))
        transport.enqueueReply(.success(Replies.brightness(current: 60)))
        _ = try await service.read(.brightness)
        #expect(transport.written == [request, request, set50, set50, set60, request, request, request])
    }

    @Test("Write wiederholt nach einem I2C-Fehler")
    func writeRetries() async throws {
        let transport = MockTransport()
        transport.enqueueWriteResult(.writeFailed(-1))
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        try await service.write(.brightness, value: 50)

        #expect(transport.written.count == 2)
    }

    @Test("Write gibt nach writeAttempts auf")
    func writeGivesUp() async {
        let transport = MockTransport()
        transport.enqueueWriteResult(.writeFailed(-7))
        transport.enqueueWriteResult(.writeFailed(-7))
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        await #expect(throws: DDCError.writeFailed(-7)) {
            try await service.write(.brightness, value: 50)
        }
        #expect(transport.written.count == 2)
    }

    @Test("Read liest nach Null-Message im zweiten Versuch")
    func readRetriesAfterNullReply() async throws {
        let transport = MockTransport()
        transport.enqueueReply(.success(Replies.null))
        transport.enqueueReply(.success(Replies.brightness(current: 70)))
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        let reading = try await service.read(.brightness)

        #expect(reading == VCPReading(current: 70, maximum: 100))
        #expect(transport.written == [[0x82, 0x01, 0x10, 0xAC], [0x82, 0x01, 0x10, 0xAC]])
    }

    @Test("Read meldet den letzten Fehler, wenn alle Versuche scheitern")
    func readGivesUp() async {
        let transport = MockTransport()
        for _ in 0..<3 { transport.enqueueReply(.success(Replies.null)) }
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        await #expect(throws: DDCError.nullReply) {
            try await service.read(.brightness)
        }
        #expect(transport.written.count == DDCTiming.immediate.readAttempts)
    }

    @Test("Nicht unterstützter VCP-Code wird nicht wiederholt")
    func unsupportedIsNotRetried() async {
        let transport = MockTransport()
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x12, 0, 0, 0, 0, 0]
        reply.append(DDCPacket.checksum(reply, seed: 0x50))
        transport.enqueueReply(.success(reply))
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        await #expect(throws: DDCError.unsupportedCode(0x12)) {
            try await service.read(.contrast)
        }
        #expect(transport.written.count == 1)
    }

    @Test("Write sendet Set-VCP optional zweimal")
    func writeRepeats() async throws {
        let transport = MockTransport()
        var timing = DDCTiming.immediate
        timing.writeRepeats = 2
        let service = DDCService(transport: transport, label: "test", timing: timing)

        try await service.write(.brightness, value: 50)

        let packet: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]
        #expect(transport.written == [packet, packet])
    }

    @Test("Nach einer Null-Message wartet der nächste Versuch länger auf die Antwort")
    func longerReplyDelayAfterNullReply() async throws {
        let transport = MockTransport()
        transport.enqueueReply(.success(Replies.null))
        transport.enqueueReply(.success(Replies.brightness(current: 70)))
        var timing = DDCTiming.immediate
        timing.nullReplyDelay = .milliseconds(40)
        let service = DDCService(transport: transport, label: "test", timing: timing)

        _ = try await service.read(.brightness)

        let events = transport.events
        try #require(events.count == 4)
        let firstGap = events[1].at - events[0].at
        let secondGap = events[3].at - events[2].at
        #expect(firstGap < .milliseconds(40))
        #expect(secondGap >= .milliseconds(40))
    }

    @Test("Diagnose hält IOReturn, Dauer und Rohbytes fest")
    func diagnosticsRecordTransfers() async {
        let transport = MockTransport()
        for _ in 0..<3 { transport.enqueueReply(.success(Replies.null)) }
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        await #expect(throws: DDCError.nullReply) { try await service.read(.brightness) }
        let afterRead = service.diagnostics
        #expect(afterRead?.lastRead?.status == 0)
        #expect(afterRead?.lastRead?.bytes == Replies.null)
        #expect(afterRead?.lastReadOperation?.error == .nullReply)

        // Erst jetzt, sonst verbrauchen die Get-VCP-Requests des Reads die Fehler.
        transport.enqueueWriteResult(.writeFailed(Int32(bitPattern: 0xE000_02CA)))
        transport.enqueueWriteResult(.writeFailed(Int32(bitPattern: 0xE000_02CA)))

        await #expect(throws: DDCError.writeFailed(Int32(bitPattern: 0xE000_02CA))) {
            try await service.write(.brightness, value: 20)
        }
        let afterWrite = service.diagnostics
        #expect(afterWrite?.lastWrite?.status == Int32(bitPattern: 0xE000_02CA))
        #expect(afterWrite?.lastWrite?.bytes == DDCPacket.setVCPRequest(0x10, value: 20))
        #expect(afterWrite?.lastWriteOperation?.value == 20)
        #expect(afterWrite?.pendingCalls == 0)
    }

    @Test("Hängender I2C-Aufruf: Timeout, danach sofort .hung ohne Warteschlange")
    func hangingTransportRejectsImmediately() async throws {
        let blocker = DispatchSemaphore(value: 0)
        let transport = MockTransport(blocker: blocker)
        var timing = DDCTiming.immediate
        timing.deadline = .milliseconds(100)
        let service = DDCService(transport: transport, label: "test", timing: timing)

        await #expect(throws: DDCError.timeout) {
            try await service.write(.brightness, value: 1)
        }
        #expect(service.isHung)
        #expect(service.diagnostics?.hungSince != nil)

        // Folgeaufrufe warten nicht auf ihre Deadline und landen nicht in der Queue.
        for value in UInt16(2)...6 {
            let started = ContinuousClock.now
            await #expect(throws: DDCError.hung) {
                try await service.write(.brightness, value: value)
            }
            await #expect(throws: DDCError.hung) {
                _ = try await service.read(.brightness)
            }
            #expect(ContinuousClock.now - started < .milliseconds(50))
        }
        #expect(service.pendingCalls == 1)

        // Der I2C-Aufruf kehrt zurück: Kanal wieder frei, nichts wurde nachgeholt.
        blocker.signal()
        #expect(await eventually { !service.isHung && service.pendingCalls == 0 })
        #expect(transport.written == [DDCPacket.setVCPRequest(0x10, value: 1)])

        blocker.signal()
        try await service.write(.brightness, value: 7)
        #expect(transport.written.last == DDCPacket.setVCPRequest(0x10, value: 7))
        #expect(service.pendingCalls == 0)
    }

    @Test("Wartende Aufrufe hinter einem Hänger: sofort .hung statt Timeout-Kaskade")
    func waitingCallsDoNotCascade() async throws {
        let blocker = DispatchSemaphore(value: 0)
        let transport = MockTransport(blocker: blocker)
        var timing = DDCTiming.immediate
        timing.deadline = .milliseconds(300)
        let service = DDCService(transport: transport, label: "test", timing: timing)

        let started = ContinuousClock.now
        let errors = await withTaskGroup(of: DDCError?.self) { group in
            for value in UInt16(1)...UInt16(DDCService.maxPendingCalls) {
                group.addTask {
                    do throws(DDCError) {
                        try await service.write(.brightness, value: value)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var errors: [DDCError?] = []
            for await error in group { errors.append(error) }
            return errors
        }
        let elapsed = ContinuousClock.now - started

        // Einer läuft in die Deadline, die anderen werden mit ihm abgebrochen; ohne
        // Sperre kämen sie nacheinander, zusammen also nach mehreren Deadlines.
        #expect(errors.filter { $0 == .timeout }.count == 1)
        #expect(errors.filter { $0 == .hung }.count == DDCService.maxPendingCalls - 1)
        #expect(elapsed < .milliseconds(550))
        #expect(service.pendingCalls == DDCService.maxPendingCalls)

        blocker.signal()
        #expect(await eventually { service.pendingCalls == 0 && !service.isHung })
        // Nur der hängende Write hat die Hardware erreicht.
        #expect(transport.written.count == 1)
    }

    @Test("Volle Queue ohne Hänger: busy")
    func fullQueueIsBusy() async {
        let blocker = DispatchSemaphore(value: 0)
        let transport = MockTransport(blocker: blocker)
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        let calls = (1...DDCService.maxPendingCalls).map { value in
            Task { try? await service.write(.brightness, value: UInt16(value)) }
        }
        #expect(await eventually { service.pendingCalls == DDCService.maxPendingCalls })
        await #expect(throws: DDCError.busy) {
            try await service.write(.brightness, value: 99)
        }

        for _ in calls { blocker.signal() }
        for call in calls { await call.value }
        #expect(service.pendingCalls == 0)
        #expect(transport.written.count == DDCService.maxPendingCalls)
    }

    @Test("Gleichzeitige Aufrufe: nie mehr als maxPendingCalls angenommen", arguments: 1...20)
    func concurrentAdmission(_ round: Int) async {
        let blocker = DispatchSemaphore(value: 0)
        let transport = MockTransport(blocker: blocker)
        let service = DDCService(transport: transport, label: "race", timing: .immediate)
        let callers = 24

        // Alle Aufrufe starten gleichzeitig; der Transport blockiert, also bleibt jeder
        // angenommene Aufruf offen, bis der Test ihn freigibt.
        let results = await withTaskGroup(of: DDCError?.self) { group in
            for value in 1...callers {
                group.addTask {
                    do throws(DDCError) {
                        try await service.write(.brightness, value: UInt16(value))
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            // Erst freigeben, wenn alle Abgelehnten zurück sind: die Angenommenen hängen.
            var results: [DDCError?] = []
            var released = false
            for await result in group {
                results.append(result)
                if !released, results.count == callers - DDCService.maxPendingCalls {
                    #expect(service.pendingCalls == DDCService.maxPendingCalls)
                    released = true
                    for _ in 0..<DDCService.maxPendingCalls { blocker.signal() }
                }
            }
            return results
        }

        #expect(results.filter { $0 == .busy }.count == callers - DDCService.maxPendingCalls)
        #expect(results.filter { $0 == nil }.count == DDCService.maxPendingCalls)
        #expect(transport.written.count == DDCService.maxPendingCalls)
        #expect(service.pendingCalls == 0)
    }
}

@Suite("DDC-Timing aus den UserDefaults")
struct DDCTimingTests {
    @Test("Werte werden übernommen und begrenzt")
    func configured() throws {
        let defaults = MemoryPreferences()
        defaults.set(5, forKey: "ddc.writeRepeats")
        defaults.set(80, forKey: "ddc.replyDelayMs")
        defaults.set(140, forKey: "ddc.nullReplyDelayMs")

        defaults.set(false, forKey: "ddc.primeAfterRead")
        let timing = DDCTiming.configured(from: defaults)

        #expect(timing.writeRepeats == 2)
        #expect(!timing.primeAfterRead)
        #expect(timing.replyDelay == .milliseconds(80))
        #expect(timing.nullReplyDelay == .milliseconds(140))
        #expect(timing.deadline == DDCTiming.standard.deadline)
    }

    @Test("Standard: Set-VCP einmal, replyDelay 50 ms, nach Null-Antwort 100–150 ms")
    func standardValues() {
        let timing = DDCTiming.standard
        #expect(timing.writeRepeats == 1)
        #expect(timing.primeAfterRead)
        #expect(timing.writeRepeatGap == .milliseconds(10))
        #expect(timing.replyDelay == .milliseconds(50))
        #expect((Duration.milliseconds(100)...Duration.milliseconds(150)).contains(timing.nullReplyDelay))
    }
}
