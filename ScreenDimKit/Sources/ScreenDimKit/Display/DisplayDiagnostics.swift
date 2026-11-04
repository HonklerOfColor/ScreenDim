import CoreGraphics
import Foundation

/// Alles, was das Diagnose-Fenster über ein Display zeigt.
public struct DisplayDiagnostics: Identifiable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let identity: DisplayIdentity?
    public let isBuiltIn: Bool
    /// Verfahren der Software-Dimmung; `nil`, wenn DDC (oder macOS) die Helligkeit regelt.
    public let softwareDimming: DimmingMethod?
    /// RegistryEntryID des `DCPAVServiceProxy`; `nil` beim eingebauten Display oder wenn
    /// keiner gefunden wurde.
    public let avServiceID: UInt64?
    public let hasChannel: Bool
    public let link: DisplayPortLink?
    public let state: DDCState
    /// 0…100
    public let brightness: Double
    public let maximum: UInt16
    public let ddc: DDCDiagnostics?

    public var edidText: String {
        guard let identity else { return "–" }
        return String(
            format: "Vendor %u (0x%04X), Model %u (0x%04X), Serial %u",
            identity.vendor, identity.vendor, identity.model, identity.model, identity.serial
        )
    }

    public var avServiceText: String {
        if isBuiltIn { return String(localized: "– (eingebautes Display)") }
        guard let avServiceID else { return String(localized: "nicht gefunden") }
        let id = String(format: "0x%llX", avServiceID)
        return hasChannel
            ? String(localized: "gefunden, RegistryEntryID \(id)")
            : String(localized: "gefunden, RegistryEntryID \(id), Kanal nicht erzeugt")
    }

    public var linkText: String? {
        guard let link else { return nil }
        var parts: [String] = []
        if let transport = link.transport { parts.append(transport) }
        if let rate = link.linkRate { parts.append(rate) }
        if let lanes = link.laneCount { parts.append(String(localized: "\(lanes) Lanes")) }
        if link.tunneled == true { parts.append(String(localized: "getunnelt (USB4/TB)")) }
        if let sinks = link.sinkCount { parts.append("Sinks \(sinks)") }
        return parts.joined(separator: ", ")
    }

    public var branchText: String? {
        guard let link, link.branchOUI != nil || link.branchDeviceID != nil else { return nil }
        var parts: [String] = []
        if let vendor = link.branchVendor { parts.append(vendor) }
        if let oui = link.branchOUI { parts.append("OUI \(oui.hexString)") }
        if let device = link.branchDeviceID { parts.append("Device-ID \"\(device)\"") }
        return parts.joined(separator: ", ")
    }

    public var stateText: String {
        // Ignoriert: ScreenDim kennt weder Beleuchtung noch Dimmung.
        guard state != .ignored else { return state.summary }
        var parts = [state.summary]
        switch softwareDimming {
        case .gamma: parts.append(String(localized: "Software-Dimmung (Gamma)"))
        case .overlay: parts.append(String(localized: "Software-Dimmung (Overlay)"))
        case nil: break
        }
        parts.append(String(localized: "Helligkeit \(Int(brightness)) von 100, Maximum \(Int(maximum))"))
        return parts.joined(separator: ", ")
    }

    public var channelText: String? {
        guard let ddc else { return nil }
        var text = String(localized: "\(ddc.pendingCalls) offene Aufrufe")
        if let hungSince = ddc.hungSince {
            let seconds = String(format: "%.1f", Date().timeIntervalSince(hungSince))
            text += ", " + String(localized: "hängt seit \(seconds) s")
        }
        return text
    }

    // MARK: - Text

    public static func report(_ displays: [DisplayDiagnostics], timing: DDCTiming, date: Date = Date()) -> String {
        var lines = [
            String(localized: "ScreenDim Diagnose, \(date.formatted(date: .numeric, time: .standard))"),
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            String(localized: "DDC-Timing: \(timing.summary)"),
        ]
        for display in displays {
            lines.append("")
            lines.append(contentsOf: display.reportLines)
        }
        return lines.joined(separator: "\n")
    }

    var reportLines: [String] {
        var lines = [
            isBuiltIn ? String(localized: "\(name) (eingebaut)") : name,
            "  CGDirectDisplayID: \(id)",
            "  EDID: \(edidText)",
            "  " + String(localized: "AV-Service: \(avServiceText)"),
        ]
        if let linkText { lines.append("  " + String(localized: "Link: \(linkText)")) }
        if let branchText { lines.append("  " + String(localized: "Branch: \(branchText)")) }
        lines.append("  " + String(localized: "Zustand: \(stateText)"))
        if let channelText { lines.append("  " + String(localized: "Kanal: \(channelText)")) }
        if let ddc {
            lines.append("  " + String(localized: "Letzter Write: \(Self.describe(ddc.lastWriteOperation))"))
            lines.append("  " + String(localized: "Letzter Read: \(Self.describe(ddc.lastReadOperation))"))
            lines.append("  " + String(localized: "Letzter I2C-Write: \(Self.describe(ddc.lastWrite))"))
            lines.append("  " + String(localized: "Letzter I2C-Read: \(Self.describe(ddc.lastRead))"))
        }
        return lines
    }

    public static func describe(_ operation: DDCOperationRecord?) -> String {
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

    public static func describe(_ transfer: I2CTransferRecord?) -> String {
        guard let transfer else { return "–" }
        let status = transfer.status.map(IOReturnDescription.describe) ?? (transfer.error?.description ?? "?")
        let bytes = transfer.bytes.isEmpty ? String(localized: "keine Bytes") : "[\(transfer.bytes.hexString)]"
        return "\(status), \(transfer.duration.milliseconds) ms, \(bytes), \(transfer.date.formatted(date: .omitted, time: .standard))"
    }
}

extension DDCTiming {
    /// Technische Kurzform, z. B. für das Diagnose-Fenster.
    public var summary: String {
        "replyDelay \(replyDelay.milliseconds) ms, nullReplyDelay \(nullReplyDelay.milliseconds) ms, "
            + "commandGap \(commandGap.milliseconds) ms, retryDelay \(retryDelay.milliseconds) ms, "
            + "Reads \(readAttempts)×, Writes \(writeAttempts)×, Set-VCP \(writeRepeats)× "
            + "(\(writeRepeatGap.milliseconds) ms), Deadline \(deadline.milliseconds) ms"
    }
}
