import CoreGraphics
import Foundation

/// Alles, was das Diagnose-Fenster über ein Display zeigt.
struct DisplayDiagnostics: Identifiable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let identity: DisplayIdentity?
    let isBuiltIn: Bool
    let usesSoftwareDimming: Bool
    /// RegistryEntryID des `DCPAVServiceProxy`; `nil` beim eingebauten Display oder wenn
    /// keiner gefunden wurde.
    let avServiceID: UInt64?
    let hasChannel: Bool
    let link: DisplayPortLink?
    let state: DDCState
    /// 0…100
    let brightness: Double
    let maximum: UInt16
    let ddc: DDCDiagnostics?

    var edidText: String {
        guard let identity else { return "–" }
        return String(
            format: "Vendor %u (0x%04X), Model %u (0x%04X), Serial %u",
            identity.vendor, identity.vendor, identity.model, identity.model, identity.serial
        )
    }

    var avServiceText: String {
        if isBuiltIn { return "– (eingebautes Display, DisplayServices)" }
        guard let avServiceID else { return "nicht gefunden" }
        return String(format: "gefunden, RegistryEntryID 0x%llX", avServiceID) + (hasChannel ? "" : ", IOAVService nicht erzeugt")
    }

    var linkText: String? {
        guard let link else { return nil }
        var parts: [String] = []
        if let transport = link.transport { parts.append(transport) }
        if let rate = link.linkRate { parts.append(rate) }
        if let lanes = link.laneCount { parts.append("\(lanes) Lanes") }
        if link.tunneled == true { parts.append("getunnelt (USB4/TB)") }
        if let sinks = link.sinkCount { parts.append("Sinks \(sinks)") }
        return parts.joined(separator: ", ")
    }

    var branchText: String? {
        guard let link, link.branchOUI != nil || link.branchDeviceID != nil else { return nil }
        var parts: [String] = []
        if let vendor = link.branchVendor { parts.append(vendor) }
        if let oui = link.branchOUI { parts.append("OUI \(oui.hexString)") }
        if let device = link.branchDeviceID { parts.append("Device-ID \"\(device)\"") }
        return parts.joined(separator: ", ")
    }

    var stateText: String {
        let dimming = usesSoftwareDimming ? ", Software-Dimmung (Gamma)" : ""
        return "\(state.summary)\(dimming), Helligkeit \(Int(brightness)) % (Maximum \(maximum))"
    }

    var channelText: String? {
        guard let ddc else { return nil }
        var text = "\(ddc.pendingCalls) offene Aufrufe"
        if let hungSince = ddc.hungSince {
            text += String(format: ", hängt seit %.1f s", Date().timeIntervalSince(hungSince))
        }
        return text
    }

    // MARK: - Text

    static func report(_ displays: [DisplayDiagnostics], timing: DDCTiming, date: Date = Date()) -> String {
        var lines = [
            "ScreenDim Diagnose, \(date.formatted(date: .numeric, time: .standard))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "DDC-Timing: \(timing.summary)",
        ]
        for display in displays {
            lines.append("")
            lines.append(contentsOf: display.reportLines)
        }
        return lines.joined(separator: "\n")
    }

    var reportLines: [String] {
        var lines = [
            "\(name)\(isBuiltIn ? " (eingebaut)" : "")",
            "  CGDirectDisplayID: \(id)",
            "  EDID: \(edidText)",
            "  AV-Service: \(avServiceText)",
        ]
        if let linkText { lines.append("  Link: \(linkText)") }
        if let branchText { lines.append("  Branch: \(branchText)") }
        lines.append("  Zustand: \(stateText)")
        if let channelText { lines.append("  Kanal: \(channelText)") }
        if let ddc {
            lines.append("  Letzter Write: \(Self.describe(ddc.lastWriteOperation))")
            lines.append("  Letzter Read: \(Self.describe(ddc.lastReadOperation))")
            lines.append("  Letzter I2C-Write: \(Self.describe(ddc.lastWrite))")
            lines.append("  Letzter I2C-Read: \(Self.describe(ddc.lastRead))")
        }
        return lines
    }

    static func describe(_ operation: DDCOperationRecord?) -> String {
        guard let operation else { return "–" }
        var text = "\(operation.kind.rawValue) 0x\(String(format: "%02X", operation.code))"
        switch (operation.kind, operation.value, operation.maximum) {
        case (.read, let value?, let maximum?): text += " = \(value)/\(maximum)"
        case (.write, let value?, _): text += " = \(value)"
        default: break
        }
        text += operation.error.map { ": \($0.description)" } ?? ": OK"
        text += ", \(operation.duration.milliseconds) ms, \(operation.date.formatted(date: .omitted, time: .standard))"
        return text
    }

    static func describe(_ transfer: I2CTransferRecord?) -> String {
        guard let transfer else { return "–" }
        let status = transfer.status.map(IOReturnDescription.describe) ?? (transfer.error?.description ?? "?")
        let bytes = transfer.bytes.isEmpty ? "keine Bytes" : "[\(transfer.bytes.hexString)]"
        return "\(status), \(transfer.duration.milliseconds) ms, \(bytes), \(transfer.date.formatted(date: .omitted, time: .standard))"
    }
}

extension DDCTiming {
    var summary: String {
        "replyDelay \(replyDelay.milliseconds) ms, nach Null-Antwort \(nullReplyDelay.milliseconds) ms, "
            + "commandGap \(commandGap.milliseconds) ms, retryDelay \(retryDelay.milliseconds) ms, "
            + "Reads \(readAttempts)×, Writes \(writeAttempts)×, Set-VCP \(writeRepeats)× "
            + "(Abstand \(writeRepeatGap.milliseconds) ms), Deadline \(deadline.milliseconds) ms"
    }
}
