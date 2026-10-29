import CoreGraphics
import Testing
@testable import ScreenDimKit

@MainActor
@Suite("GammaDimmer")
struct GammaDimmerTests {
    @Test("100 % lässt die Kurve unverändert, 0 % bleibt über der Untergrenze")
    func factorRange() {
        #expect(GammaDimmer.factor(forPercent: 100) == 1)
        #expect(GammaDimmer.factor(forPercent: 0) == GammaDimmer.minimumFactor)
        #expect(GammaDimmer.factor(forPercent: -5) == GammaDimmer.minimumFactor)
        #expect(GammaDimmer.factor(forPercent: 150) == 1)
        #expect(abs(GammaDimmer.factor(forPercent: 50) - 0.55) < 0.0001)
    }

    @Test("Abdunkeln skaliert die gemerkte Kurve, 100 % stellt sie wieder her")
    func applyAndRestore() {
        let tables = StubGammaTables(displays: [2])
        let dimmer = GammaDimmer(tables: tables)

        #expect(dimmer.apply([2: 50]).isEmpty)
        #expect(tables.table(2) == StubGammaTables.identity.scaled(by: GammaDimmer.factor(forPercent: 50)))

        dimmer.apply([2: 100])
        #expect(tables.table(2) == StubGammaTables.identity)
    }

    @Test("Nicht lesbare Gamma-Tabelle wird als Fehlschlag gemeldet")
    func unreadableTableFails() {
        let tables = StubGammaTables(displays: [2, 3], unreadable: [3])
        let dimmer = GammaDimmer(tables: tables)

        #expect(dimmer.apply([2: 40, 3: 40]) == [3])
        #expect(tables.table(3) == StubGammaTables.identity)
        // Der Fehlschlag bleibt nicht hängen: Ohne Display 3 kommt kein Fehler mehr.
        #expect(dimmer.apply([2: 40]).isEmpty)
    }

    @Test("Refresh schreibt nur betroffene Displays neu, ohne ColorSync-Reset")
    func refreshWithoutColorSync() {
        let tables = StubGammaTables(displays: [2, 3])
        let dimmer = GammaDimmer(tables: tables)
        dimmer.apply([2: 50, 3: 50])

        // macOS setzt beim Auflösungswechsel die Kurve von Display 3 zurück.
        tables.resetByMacOS(3)
        let writes = tables.writes
        dimmer.refresh([3])

        #expect(tables.colorSyncResets == 0)
        #expect(tables.writes == writes + 1)
        #expect(tables.table(3) == StubGammaTables.identity.scaled(by: GammaDimmer.factor(forPercent: 50)))
    }

    @Test("Reapply setzt per ColorSync zurück und dunkelt wieder ab")
    func reapplyUsesColorSync() {
        let tables = StubGammaTables(displays: [2])
        let dimmer = GammaDimmer(tables: tables)

        dimmer.reapply()
        #expect(tables.colorSyncResets == 0)

        dimmer.apply([2: 20])
        dimmer.reapply()
        #expect(tables.colorSyncResets == 1)
        #expect(tables.table(2) == StubGammaTables.identity.scaled(by: GammaDimmer.factor(forPercent: 20)))
    }
}

@MainActor
@Suite("OverlayDimmer")
struct OverlayDimmerTests {
    @Test("Deckkraft folgt derselben Kurve wie Gamma")
    func alphaCurve() {
        #expect(OverlayDimmer.alpha(forPercent: 100) == 0)
        #expect(abs(OverlayDimmer.alpha(forPercent: 0) - 0.9) < 0.0001)
        #expect(abs(OverlayDimmer.alpha(forPercent: 50) - 0.45) < 0.0001)
    }

    @Test("Ein Fenster je Display, geschlossen bei 100 % oder wenn das Display fehlt")
    func windowsLifecycle() {
        var created: [CGDirectDisplayID: StubOverlayWindow] = [:]
        let dimmer = OverlayDimmer { id in
            let window = StubOverlayWindow()
            created[id] = window
            return window
        }

        #expect(dimmer.apply([2: 50, 3: 100]).isEmpty)
        #expect(created.keys.sorted() == [2])
        #expect(abs((created[2]?.alpha ?? 0) - 0.45) < 0.0001)

        dimmer.apply([2: 20])
        #expect(created.count == 1)
        #expect(abs((created[2]?.alpha ?? 0) - OverlayDimmer.alpha(forPercent: 20)) < 0.0001)

        dimmer.apply([:])
        #expect(created[2]?.isClosed == true)
    }

    @Test("Ohne Bildschirm kein Fenster: Fehlschlag")
    func missingScreenFails() {
        let dimmer = OverlayDimmer { _ in nil }
        #expect(dimmer.apply([2: 50]) == [2])
    }

    @Test("Refresh und Reapply passen nur die Fensterlage an")
    func refreshUpdatesFrames() {
        var created: [CGDirectDisplayID: StubOverlayWindow] = [:]
        let dimmer = OverlayDimmer { id in
            let window = StubOverlayWindow()
            created[id] = window
            return window
        }
        dimmer.apply([2: 50, 3: 50])

        dimmer.refresh([3])
        #expect(created[2]?.frameUpdates == 0)
        #expect(created[3]?.frameUpdates == 1)

        dimmer.reapply()
        #expect(created[2]?.frameUpdates == 1)
        #expect(created[3]?.frameUpdates == 2)
    }
}
