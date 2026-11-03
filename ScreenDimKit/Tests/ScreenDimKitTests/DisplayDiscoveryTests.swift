import CoreGraphics
import Testing
@testable import ScreenDimKit

@MainActor
@Suite("DisplayDiscovery: Speicherschlüssel")
struct DisplayDiscoveryTests {
    @Test("Baugleiche Monitore ohne Seriennummer: getrennte Schlüssel nach Lage, der linke behält den alten")
    func twinsGetDistinctKeys() {
        let twin = DisplayIdentity(vendor: 19501, model: 3148, serial: 0)
        let other = DisplayIdentity(vendor: 1, model: 2, serial: 3)
        let displays = [
            DiscoveredDisplay(id: 7, identity: twin, name: "Twin", kind: .external(avServiceID: 1)),
            DiscoveredDisplay(id: 5, identity: twin, name: "Twin", kind: .external(avServiceID: 2)),
            DiscoveredDisplay(id: 9, identity: other, name: "Other", kind: .external(avServiceID: 3)),
        ]
        let positions: [CGDirectDisplayID: CGPoint] = [7: CGPoint(x: 1920, y: 0), 5: .zero, 9: CGPoint(x: -1000, y: 0)]

        let unique = DisplayDiscovery.withUniqueStorageKeys(displays) { positions[$0]! }

        #expect(unique.map(\.id) == [7, 5, 9])
        #expect(unique[1].storageKey == twin.storageKey)
        #expect(unique[0].storageKey == twin.storageKey + "#2")
        #expect(unique[2].storageKey == other.storageKey)
    }

    @Test("Gleiche Lage: die Display-ID entscheidet, die Schlüssel bleiben verschieden")
    func samePositionFallsBackToID() {
        let twin = DisplayIdentity(vendor: 19501, model: 3148, serial: 0)
        let displays = [
            DiscoveredDisplay(id: 7, identity: twin, name: "Twin", kind: .external(avServiceID: 1)),
            DiscoveredDisplay(id: 5, identity: twin, name: "Twin", kind: .external(avServiceID: 2)),
        ]

        let unique = DisplayDiscovery.withUniqueStorageKeys(displays) { _ in .zero }

        #expect(unique[1].storageKey == twin.storageKey)
        #expect(unique[0].storageKey == twin.storageKey + "#2")
    }

    @Test("Ohne Zwillinge ändert sich kein Schlüssel")
    func uniqueIdentitiesUnchanged() {
        let displays = [
            DiscoveredDisplay(id: 1, identity: DisplayIdentity(vendor: 1, model: 1, serial: 0), name: "A", kind: .builtIn),
            DiscoveredDisplay(id: 2, identity: DisplayIdentity(vendor: 1, model: 2, serial: 0), name: "B", kind: .external(avServiceID: nil)),
        ]
        let unique = DisplayDiscovery.withUniqueStorageKeys(displays) { _ in .zero }
        #expect(unique.map(\.storageKey) == ["1-1-0", "1-2-0"])
    }
}
