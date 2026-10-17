import Foundation

/// VCP-Codes (MCCS), die ScreenDim benutzt.
enum VCPCode: UInt8, Sendable {
    case brightness = 0x10
    case contrast = 0x12
}

/// Antwort auf „Get VCP Feature“.
struct VCPReading: Equatable, Sendable {
    let current: UInt16
    let maximum: UInt16
}

enum DDCError: Error, Equatable, Sendable {
    /// IOAVServiceWriteI2C lieferte einen Fehler (IOReturn).
    case writeFailed(Int32)
    /// IOAVServiceReadI2C lieferte einen Fehler (IOReturn).
    case readFailed(Int32)
    /// Der Monitor hat mit einer DDC-Null-Message geantwortet (nicht bereit oder DDC/CI aus).
    case nullReply
    case malformedReply
    case checksumMismatch
    /// Der Monitor kennt den VCP-Code nicht.
    case unsupportedCode(UInt8)
    /// Die Operation hat ihre Deadline überschritten.
    case timeout
    /// Auf dem I2C-Kanal hängen bereits zu viele Aufrufe.
    case busy
}

/// Paketaufbau nach DDC/CI 1.1.
///
/// Die Pakete gehen per `IOAVServiceWriteI2C` an Chip 0x37 (Schreibadresse 0x6E).
/// Das Quell-Byte 0x51 übergibt IOKit als „data address“; es steht deshalb nicht im
/// Array, fließt aber in die Prüfsumme ein.
enum DDCPacket {
    static let chipAddress: UInt32 = 0x37
    static let hostSubaddress: UInt32 = 0x51
    static let destinationAddress: UInt8 = 0x6E
    /// Antworten werden gegen die virtuelle Host-Adresse 0x50 geprüft.
    static let replyChecksumSeed: UInt8 = 0x50
    static let replyLength = 11

    private static let requestChecksumSeed = destinationAddress ^ UInt8(hostSubaddress)

    static func checksum<Bytes: Sequence>(_ bytes: Bytes, seed: UInt8) -> UInt8 where Bytes.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    /// `82 01 <vcp> <chk>`
    static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        sealed([0x82, 0x01, code])
    }

    /// `84 03 <vcp> <hi> <lo> <chk>`
    static func setVCPRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        sealed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Erwartet `6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <chk>`.
    static func parseGetVCPReply(_ reply: [UInt8], expecting code: UInt8) throws(DDCError) -> VCPReading {
        guard reply.count >= replyLength else { throw .malformedReply }
        // Null-Message `6E 80 BE`: der Monitor hat (noch) nichts zu melden.
        if reply[1] == 0x80 { throw .nullReply }
        guard checksum(reply[0..<(replyLength - 1)], seed: replyChecksumSeed) == reply[replyLength - 1] else {
            throw .checksumMismatch
        }
        guard reply[1] == 0x88, reply[2] == 0x02, reply[4] == code else { throw .malformedReply }
        guard reply[3] == 0x00 else { throw .unsupportedCode(code) }
        return VCPReading(
            current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
            maximum: UInt16(reply[6]) << 8 | UInt16(reply[7])
        )
    }

    private static func sealed(_ body: [UInt8]) -> [UInt8] {
        body + [checksum(body, seed: requestChecksumSeed)]
    }
}
