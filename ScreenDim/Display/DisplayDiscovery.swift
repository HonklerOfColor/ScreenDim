import AppKit
import CoreGraphics
import IOKit

/// Identität eines Monitors aus der EDID. Dient als Schlüssel für gespeicherte Werte,
/// weil `CGDirectDisplayID` nach Hotplug oder Neustart wechseln kann.
struct DisplayIdentity: Hashable, Sendable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    var storageKey: String { "\(vendor)-\(model)-\(serial)" }
}

/// Daten des DisplayPort-Links aus der IORegistry (`IOPortTransportStateDisplayPort`).
/// Ein Branch-Device (MST-Hub, Dock) zeigt sich über OUI und Device-ID.
struct DisplayPortLink: Equatable, Sendable {
    var transport: String?
    var branchOUI: [UInt8]?
    var branchDeviceID: String?
    var linkRate: String?
    var laneCount: Int?
    var tunneled: Bool?
    var sinkCount: Int?

    /// Gerät zwischen Mac und Monitor, das DDC weiterreichen muss.
    enum Intermediary: Equatable, Sendable {
        /// Über USB4/Thunderbolt getunnelt, mit Branch-Device (Dock, MST-Hub).
        case dock
        /// Branch-Device ohne Tunnel (USB-C-Adapter, Wandler).
        case adapter
    }

    var intermediary: Intermediary? {
        guard branchOUI != nil else { return nil }
        return tunneled == true ? .dock : .adapter
    }

    var branchVendor: String? {
        guard let branchOUI else { return nil }
        return Self.knownOUIs[branchOUI] ?? "OUI \(branchOUI.hexString)"
    }

    private static let knownOUIs: [[UInt8]: String] = [
        [0x00, 0xE0, 0x4C]: "Realtek",
    ]
}

struct DiscoveredDisplay: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Eingebautes Panel, gesteuert über DisplayServices.
        case builtIn
        /// Externer Monitor mit der RegistryEntryID seines `DCPAVServiceProxy`; `nil`,
        /// wenn in der IORegistry kein passender Proxy gefunden wurde.
        case external(avServiceID: UInt64?)
    }

    let id: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let kind: Kind
    var link: DisplayPortLink?

    var avServiceID: UInt64? {
        if case .external(let id) = kind { id } else { nil }
    }

    var isBuiltIn: Bool {
        if case .builtIn = kind { true } else { false }
    }
}

/// Findet die Displays (eingebautes zuerst) und ordnet den externen ihren DDC-Kanal zu.
/// Erzeugt selbst keine IOAVService-Objekte; das übernimmt der DisplayManager, und
/// zwar nur für Kanäle, die er noch nicht kennt.
@MainActor
enum DisplayDiscovery {
    static func displays() -> [DiscoveredDisplay] {
        let online = onlineDisplayIDs()
        let builtIn = online.filter { CGDisplayIsBuiltin($0) != 0 }.map { id in
            DiscoveredDisplay(id: id, identity: identity(of: id), name: screenName(for: id) ?? "MacBook-Display", kind: .builtIn)
        }
        return builtIn + externalDisplays(online.filter { CGDisplayIsBuiltin($0) == 0 })
    }

    private static func externalDisplays(_ displays: [CGDirectDisplayID]) -> [DiscoveredDisplay] {
        guard !displays.isEmpty else { return [] }

        var (candidates, links) = registryScan()
        var matches: [CGDirectDisplayID: Candidate] = [:]
        for id in displays {
            matches[id] = takeCandidate(for: identity(of: id), from: &candidates)
        }
        // Letzter Ausweg: genau ein Monitor und genau ein Kanal sind übrig.
        let unmatched = displays.filter { matches[$0] == nil }
        if unmatched.count == 1, candidates.count == 1 {
            matches[unmatched[0]] = candidates.removeFirst()
        }

        return displays.map { id in
            let match = matches[id]
            let identity = identity(of: id)
            return DiscoveredDisplay(
                id: id,
                identity: identity,
                name: match?.productName ?? screenName(for: id) ?? "Monitor \(id)",
                kind: .external(avServiceID: match?.registryEntryID),
                link: takeLink(for: identity, from: &links)
            )
        }
    }

    // MARK: - CoreGraphics

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func identity(of id: CGDirectDisplayID) -> DisplayIdentity {
        DisplayIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }

    private static func screenName(for id: CGDirectDisplayID) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }?.localizedName
    }

    // MARK: - IORegistry

    private struct Candidate {
        let vendor: UInt32?
        let model: UInt32?
        let serial: UInt32?
        let productName: String?
        let registryEntryID: UInt64
    }

    private struct LinkCandidate {
        let model: UInt32?
        let serial: UInt32?
        let link: DisplayPortLink
    }

    /// Läuft die IOService-Ebene in Registry-Reihenfolge ab. Auf Apple Silicon steht der
    /// Framebuffer eines Monitors (`IOMobileFramebufferShim`, älter `AppleCLCD2`, mit
    /// EDID-Daten unter „DisplayAttributes“) vor dem zugehörigen `DCPAVServiceProxy`
    /// mit „Location“ = „External“. Jeder Proxy wird mit dem zuletzt gesehenen
    /// Framebuffer gepaart. Nebenbei sammelt der Lauf die DisplayPort-Links.
    private static func registryScan() -> (candidates: [Candidate], links: [LinkCandidate]) {
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return ([], [])
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [Candidate] = []
        var links: [LinkCandidate] = []
        var lastAttributes: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOPortTransportStateDisplayPort") != 0 {
                links.append(linkCandidate(entry))
                continue
            }
            switch entryName(entry) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                if let attributes = property(entry, "DisplayAttributes") as? [String: Any],
                   let product = attributes["ProductAttributes"] as? [String: Any] {
                    lastAttributes = product
                }
            case "DCPAVServiceProxy":
                defer { lastAttributes = nil }
                var registryEntryID: UInt64 = 0
                guard property(entry, "Location") as? String == "External",
                      IORegistryEntryGetRegistryEntryID(entry, &registryEntryID) == KERN_SUCCESS
                else { continue }
                candidates.append(Candidate(
                    vendor: (lastAttributes?["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                    model: (lastAttributes?["ProductID"] as? NSNumber)?.uint32Value,
                    serial: (lastAttributes?["SerialNumber"] as? NSNumber)?.uint32Value,
                    productName: lastAttributes?["ProductName"] as? String,
                    registryEntryID: registryEntryID
                ))
            default:
                break
            }
        }
        return (candidates, links)
    }

    private static func linkCandidate(_ entry: io_registry_entry_t) -> LinkCandidate {
        let number = { (key: String) in property(entry, key) as? NSNumber }
        return LinkCandidate(
            model: number("ProductID")?.uint32Value,
            serial: number("SerialNumber")?.uint32Value,
            link: DisplayPortLink(
                transport: property(entry, "TransportDescription") as? String,
                branchOUI: (property(entry, "BranchDeviceOUI") as? Data).map { Array($0) },
                branchDeviceID: property(entry, "BranchDeviceID") as? String,
                linkRate: property(entry, "LinkRateDescription") as? String,
                laneCount: number("LaneCount")?.intValue,
                tunneled: number("Tunneled")?.boolValue,
                sinkCount: number("SinkCount")?.intValue
            )
        )
    }

    /// Ein Link gehört zum Monitor, wenn Modell und Seriennummer aus der EDID passen.
    private static func takeLink(for identity: DisplayIdentity, from links: inout [LinkCandidate]) -> DisplayPortLink? {
        guard let index = links.firstIndex(where: { $0.model == identity.model && $0.serial == identity.serial }) else {
            return nil
        }
        return links.remove(at: index).link
    }

    /// Zuordnung in absteigender Sicherheit: Hersteller+Modell+Seriennummer, dann
    /// Hersteller+Modell, jeweils nur bei eindeutigem Treffer.
    private static func takeCandidate(for identity: DisplayIdentity, from candidates: inout [Candidate]) -> Candidate? {
        func take(_ predicate: (Candidate) -> Bool) -> Candidate? {
            let matches = candidates.indices.filter { predicate(candidates[$0]) }
            guard matches.count == 1 else { return nil }
            return candidates.remove(at: matches[0])
        }
        let sameProduct = { (c: Candidate) in c.vendor == identity.vendor && c.model == identity.model }
        return take { sameProduct($0) && $0.serial == identity.serial } ?? take(sameProduct)
    }

    private static func entryName(_ entry: io_registry_entry_t) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: MemoryLayout<io_name_t>.size) { buffer in
            guard IORegistryEntryGetName(entry, buffer.baseAddress!) == KERN_SUCCESS else { return "" }
            return String(cString: buffer.baseAddress!)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
