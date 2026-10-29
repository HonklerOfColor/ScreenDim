import Testing
@testable import ScreenDimKit

@Suite("DDC-Paketaufbau")
struct DDCPacketTests {
    @Test("Get VCP Helligkeit entspricht dem Beispiel aus der DDC/CI-Spezifikation")
    func getBrightnessRequest() {
        // Spezifikation: 6E 51 82 01 10 AC (6E und 51 sind die Adressen, AC die Prüfsumme)
        #expect(DDCPacket.getVCPRequest(VCPCode.brightness.rawValue) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test("Get VCP Kontrast")
    func getContrastRequest() {
        // 6E ^ 51 ^ 82 ^ 01 ^ 12 = AE
        #expect(DDCPacket.getVCPRequest(VCPCode.contrast.rawValue) == [0x82, 0x01, 0x12, 0xAE])
    }

    @Test("Set VCP Helligkeit 50")
    func setBrightnessRequest() {
        // 6E ^ 51 ^ 84 ^ 03 ^ 10 ^ 00 ^ 32 = 9A
        #expect(DDCPacket.setVCPRequest(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    @Test("Set VCP teilt 16-Bit-Werte in High- und Low-Byte")
    func setRequestSplitsValue() {
        let packet = DDCPacket.setVCPRequest(0x12, value: 0x0102)
        #expect(Array(packet[2...4]) == [0x12, 0x01, 0x02])
        #expect(packet.last == DDCPacket.checksum(packet.dropLast(), seed: 0x6E ^ 0x51))
    }

    @Test("Prüfsumme ist XOR über Startwert und alle Bytes")
    func checksumIsXor() {
        #expect(DDCPacket.checksum([], seed: 0x3F) == 0x3F)
        #expect(DDCPacket.checksum([0xFF, 0x0F], seed: 0x00) == 0xF0)
        #expect(DDCPacket.checksum([0xAA, 0xAA], seed: 0x55) == 0x55)
    }

    @Test("Antwort wird gelesen: aktuell 70 von 100 (echter Mitschnitt S34CG50)")
    func parseRealReply() throws {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x46, 0x86]
        #expect(try DDCPacket.parseGetVCPReply(reply, expecting: 0x10) == VCPReading(current: 70, maximum: 100))
    }

    @Test("16-Bit-Werte in der Antwort")
    func parseWideValues() throws {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x01, 0x2C, 0x00, 0xC8]
        reply.append(DDCPacket.checksum(reply, seed: 0x50))
        #expect(try DDCPacket.parseGetVCPReply(reply, expecting: 0x10) == VCPReading(current: 200, maximum: 300))
    }

    @Test("Null-Message wird erkannt (echter Mitschnitt U28E590)")
    func nullReply() {
        let reply: [UInt8] = [0x6E, 0x80, 0xBE, 0xB9, 0xE4, 0x64, 0x8C, 0x02, 0x91, 0x3A, 0xBD]
        #expect(throws: DDCError.nullReply) { try DDCPacket.parseGetVCPReply(reply, expecting: 0x10) }
    }

    @Test("Falsche Prüfsumme wird abgelehnt")
    func checksumMismatch() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x46, 0x87]
        #expect(throws: DDCError.checksumMismatch) { try DDCPacket.parseGetVCPReply(reply, expecting: 0x10) }
    }

    @Test("Antwort für einen anderen VCP-Code wird abgelehnt")
    func wrongCode() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x12, 0x00, 0x00, 0x64, 0x00, 0x32]
        reply.append(DDCPacket.checksum(reply, seed: 0x50))
        #expect(throws: DDCError.malformedReply) { try DDCPacket.parseGetVCPReply(reply, expecting: 0x10) }
    }

    @Test("Result-Code ≠ 0 heißt: VCP-Code nicht unterstützt")
    func unsupportedCode() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00]
        reply.append(DDCPacket.checksum(reply, seed: 0x50))
        #expect(throws: DDCError.unsupportedCode(0x12)) { try DDCPacket.parseGetVCPReply(reply, expecting: 0x12) }
    }

    @Test("Zu kurze Antwort")
    func shortReply() {
        #expect(throws: DDCError.malformedReply) { try DDCPacket.parseGetVCPReply([0x6E, 0x88], expecting: 0x10) }
    }
}
