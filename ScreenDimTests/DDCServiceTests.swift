import Foundation
import Testing

@Suite("DDCService mit Mock-Transport")
struct DDCServiceTests {
    @Test("Write schickt genau ein Set-VCP-Paket")
    func writeSendsPacket() async throws {
        let transport = MockTransport()
        let service = DDCService(transport: transport, label: "test", timing: .immediate)

        try await service.write(.brightness, value: 50)

        #expect(transport.written == [[0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]])
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

    @Test("Hängender I2C-Aufruf: Timeout, danach busy statt Warteschlange")
    func hangingTransportTimesOutAndRejects() async {
        let blocker = DispatchSemaphore(value: 0)
        let transport = MockTransport(blocker: blocker)
        var timing = DDCTiming.immediate
        timing.deadline = .milliseconds(100)
        let service = DDCService(transport: transport, label: "test", timing: timing)

        for _ in 0..<DDCService.maxPendingCalls {
            await #expect(throws: DDCError.timeout) {
                try await service.write(.brightness, value: 1)
            }
        }
        await #expect(throws: DDCError.busy) {
            try await service.write(.brightness, value: 2)
        }

        for _ in 0..<(DDCService.maxPendingCalls * timing.writeAttempts) { blocker.signal() }
    }
}
