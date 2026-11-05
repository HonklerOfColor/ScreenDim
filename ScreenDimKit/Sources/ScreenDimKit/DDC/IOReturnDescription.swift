import Foundation

/// Lesbare Form von IOReturn-Codes für Log und Diagnose, z. B. `0xE00002D6 kIOReturnTimeout`.
///
/// Die Konstanten aus `IOReturn.h` sind Makros, die Swift nicht importiert; deshalb
/// steht die Tabelle hier.
public enum IOReturnDescription {
    public static func hex(_ status: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: status))
    }

    /// `MACH_SEND_INVALID_DEST`: Der Mach-Port des Dienstes ist tot. So antwortet ein
    /// DDC-Kanal, dessen `DCPAVServiceProxy` macOS inzwischen neu angelegt hat.
    public static let machSendInvalidDest = Int32(bitPattern: 0x1000_0003)

    public static func name(_ status: Int32) -> String {
        if status == 0 { return "kIOReturnSuccess" }
        if status == machSendInvalidDest { return "MACH_SEND_INVALID_DEST" }
        let raw = UInt32(bitPattern: status)
        // sys_iokit | sub_iokit_common
        if raw & 0xFFFF_C000 == 0xE000_0000, let name = commonNames[raw & 0x3FFF] {
            return name
        }
        let system = (raw >> 26) & 0x3F
        let subsystem = (raw >> 14) & 0xFFF
        let code = raw & 0x3FFF
        return String(format: "unbekannt (sys 0x%02X, sub 0x%03X, code 0x%04X)", system, subsystem, code)
    }

    public static func describe(_ status: Int32) -> String {
        "\(hex(status)) \(name(status))"
    }

    private static let commonNames: [UInt32: String] = [
        0x001: "kIOReturnInvalid",
        0x2BC: "kIOReturnError",
        0x2BD: "kIOReturnNoMemory",
        0x2BE: "kIOReturnNoResources",
        0x2BF: "kIOReturnIPCError",
        0x2C0: "kIOReturnNoDevice",
        0x2C1: "kIOReturnNotPrivileged",
        0x2C2: "kIOReturnBadArgument",
        0x2C3: "kIOReturnLockedRead",
        0x2C4: "kIOReturnLockedWrite",
        0x2C5: "kIOReturnExclusiveAccess",
        0x2C6: "kIOReturnBadMessageID",
        0x2C7: "kIOReturnUnsupported",
        0x2C8: "kIOReturnVMError",
        0x2C9: "kIOReturnInternalError",
        0x2CA: "kIOReturnIOError",
        0x2CC: "kIOReturnCannotLock",
        0x2CD: "kIOReturnNotOpen",
        0x2CE: "kIOReturnNotReadable",
        0x2CF: "kIOReturnNotWritable",
        0x2D0: "kIOReturnNotAligned",
        0x2D1: "kIOReturnBadMedia",
        0x2D2: "kIOReturnStillOpen",
        0x2D3: "kIOReturnRLDError",
        0x2D4: "kIOReturnDMAError",
        0x2D5: "kIOReturnBusy",
        0x2D6: "kIOReturnTimeout",
        0x2D7: "kIOReturnOffline",
        0x2D8: "kIOReturnNotReady",
        0x2D9: "kIOReturnNotAttached",
        0x2DA: "kIOReturnNoChannels",
        0x2DB: "kIOReturnNoSpace",
        0x2DD: "kIOReturnPortExists",
        0x2DE: "kIOReturnCannotWire",
        0x2DF: "kIOReturnNoInterrupt",
        0x2E0: "kIOReturnNoFrames",
        0x2E1: "kIOReturnMessageTooLarge",
        0x2E2: "kIOReturnNotPermitted",
        0x2E3: "kIOReturnNoPower",
        0x2E4: "kIOReturnNoMedia",
        0x2E5: "kIOReturnUnformattedMedia",
        0x2E6: "kIOReturnUnsupportedMode",
        0x2E7: "kIOReturnUnderrun",
        0x2E8: "kIOReturnOverrun",
        0x2E9: "kIOReturnDeviceError",
        0x2EA: "kIOReturnNoCompletion",
        0x2EB: "kIOReturnAborted",
        0x2EC: "kIOReturnNoBandwidth",
        0x2ED: "kIOReturnNotResponding",
        0x2EE: "kIOReturnIsoTooOld",
        0x2EF: "kIOReturnIsoTooNew",
        0x2F0: "kIOReturnNotFound",
    ]
}

extension Sequence where Element == UInt8 {
    /// `6E 80 BE …`
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
