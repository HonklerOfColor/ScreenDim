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

struct DiscoveredDisplay: Identifiable, Sendable {
    enum Kind: Sendable {
        /// Eingebautes Panel, gesteuert über DisplayServices.
        case builtIn
        /// Externer Monitor. `nil`, wenn in der IORegistry kein passender
        /// DCPAVServiceProxy gefunden wurde.
        case external(IOAVServiceTransport?)
    }

    let id: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let kind: Kind

    var isBuiltIn: Bool {
        if case .builtIn = kind { true } else { false }
    }
}

/// Findet die Displays (eingebautes zuerst) und ordnet den externen ihren DDC-Kanal zu.
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

        var candidates = avServiceCandidates()
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
            return DiscoveredDisplay(
                id: id,
                identity: identity(of: id),
                name: match?.productName ?? screenName(for: id) ?? "Monitor \(id)",
                kind: .external(match?.transport)
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
        let transport: IOAVServiceTransport
    }

    /// Läuft die IOService-Ebene in Registry-Reihenfolge ab. Auf Apple Silicon steht der
    /// Framebuffer eines Monitors (`IOMobileFramebufferShim`, älter `AppleCLCD2`, mit
    /// EDID-Daten unter „DisplayAttributes“) vor dem zugehörigen `DCPAVServiceProxy`
    /// mit „Location“ = „External“. Jeder Proxy wird mit dem zuletzt gesehenen
    /// Framebuffer gepaart.
    private static func avServiceCandidates() -> [Candidate] {
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [Candidate] = []
        var lastAttributes: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            switch entryName(entry) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                if let attributes = property(entry, "DisplayAttributes") as? [String: Any],
                   let product = attributes["ProductAttributes"] as? [String: Any] {
                    lastAttributes = product
                }
            case "DCPAVServiceProxy":
                defer { lastAttributes = nil }
                guard property(entry, "Location") as? String == "External",
                      let transport = IOAVServiceTransport(registryEntry: entry)
                else { continue }
                candidates.append(Candidate(
                    vendor: (lastAttributes?["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                    model: (lastAttributes?["ProductID"] as? NSNumber)?.uint32Value,
                    serial: (lastAttributes?["SerialNumber"] as? NSNumber)?.uint32Value,
                    productName: lastAttributes?["ProductName"] as? String,
                    transport: transport
                ))
            default:
                break
            }
        }
        return candidates
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
