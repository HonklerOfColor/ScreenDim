import CoreGraphics
import Foundation
import Testing
@testable import ScreenDimKit

@MainActor
@Suite("DisplayManager: Kanäle über Refreshes")
struct DisplayManagerTests {
    /// Was die Discovery gerade „findet“.
    private final class Setup {
        var displays: [DiscoveredDisplay] = []
        var created: [UInt64] = []
        var makeControl: (UInt64) -> any DDCControlling = { _ in StubControl() }
        let gamma = StubDimmer()
        let overlay = StubDimmer()
        /// Überlebt mehrere Manager in einem Test („Neustart“).
        let preferences = MemoryPreferences()
    }

    private let setup = Setup()

    private func makeManager(sleeper: ManualSleeper? = nil, systemFade: Duration = .zero) -> DisplayManager {
        let setup = setup
        return DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            probeRetryDelay: .milliseconds(1),
            probeLateRetryDelay: .milliseconds(20),
            systemFadeDuration: systemFade,
            sleep: { duration in
                if let sleeper { await sleeper.sleep(duration) } else { try? await Task.sleep(for: duration) }
            },
            gamma: setup.gamma,
            overlay: setup.overlay,
            discover: { setup.displays },
            makeExternalControl: { avServiceID, _, _ in
                setup.created.append(avServiceID)
                return setup.makeControl(avServiceID)
            }
        )
    }

    private static func external(
        _ id: CGDirectDisplayID,
        avService: UInt64?,
        serial: UInt32? = nil,
        link: DisplayPortLink? = nil
    ) -> DiscoveredDisplay {
        DiscoveredDisplay(
            id: id,
            identity: DisplayIdentity(vendor: 19501, model: 3148, serial: serial ?? id),
            name: "Monitor \(id)",
            kind: .external(avServiceID: avService),
            link: link
        )
    }

    private func monitor(_ manager: DisplayManager, _ id: CGDirectDisplayID) -> DisplayManager.Monitor? {
        manager.monitors.first { $0.id == id }
    }

    private func state(_ manager: DisplayManager, _ id: CGDirectDisplayID) -> DDCState? {
        manager.monitors.first { $0.id == id }?.state
    }

    @Test("Refresh mit gleicher Display-Menge erzeugt keine neuen Kanäle")
    func sameDisplaysReuseChannels() async {
        setup.displays = [Self.external(2, avService: 0x100), Self.external(3, avService: 0x200)]
        let manager = makeManager()

        manager.refresh(force: true)
        #expect(setup.created.sorted() == [0x100, 0x200])

        manager.refresh(force: false)
        manager.refresh(force: true)
        manager.refresh(force: true)
        #expect(setup.created.sorted() == [0x100, 0x200])
        #expect(manager.monitors.count == 2)
    }

    @Test("Geänderte Display-Menge: bekannte Kanäle bleiben, nur neue entstehen")
    func changedDisplaysCreateOnlyNewChannels() async {
        setup.displays = [Self.external(2, avService: 0x100), Self.external(3, avService: 0x200)]
        let manager = makeManager()
        manager.refresh(force: true)

        setup.displays = [Self.external(3, avService: 0x200), Self.external(4, avService: 0x300)]
        manager.refresh(force: false)
        #expect(setup.created.sorted() == [0x100, 0x200, 0x300])

        // Monitor 2 ist wieder da: sein alter Kanal wurde verworfen, also ein neuer.
        setup.displays.append(Self.external(2, avService: 0x100))
        manager.refresh(force: false)
        #expect(setup.created.sorted() == [0x100, 0x100, 0x200, 0x300])
    }

    @Test("Neue CGDirectDisplayID, gleicher AV-Service (Ruhezustand): Kanal bleibt")
    func newDisplayIDSameService() async {
        setup.displays = [Self.external(2, avService: 0x100, serial: 7)]
        let manager = makeManager()
        manager.refresh(force: true)

        setup.displays = [Self.external(5, avService: 0x100, serial: 7)]
        manager.refresh(force: false)

        #expect(setup.created == [0x100])
        #expect(manager.monitors.map(\.id) == [5])
        #expect(state(manager, 5) != .noChannel)
    }

    @Test("Ohne AV-Service: kein Kanal, kein IOAVService")
    func missingService() async {
        setup.displays = [Self.external(2, avService: nil)]
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(setup.created.isEmpty)
        #expect(state(manager, 2) == .noChannel)
    }

    @Test("Probe bildet Lesefehler auf Zustände ab", arguments: [
        (DDCError.nullReply, DDCState.nullReply),
        (.timeout, .i2cTimeout),
        (.readFailed(Int32(bitPattern: 0xE000_02CA)), .ioError(Int32(bitPattern: 0xE000_02CA))),
    ])
    func probeMapsErrors(_ error: DDCError, _ expected: DDCState) async {
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in StubControl(read: .failure(error)) }
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(await eventually { state(manager, 2) != .probing })
        #expect(state(manager, 2) == expected)
    }

    @Test("Verstümmelte Antwort: dritte, späte Runde; der Monitor ist dann hochgefahren")
    func garbledReplyGetsThirdRound() async {
        let control = StubControl(read: .failure(.checksumMismatch))
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in control }
        let manager = makeManager()
        manager.refresh(force: true)

        // Nach zwei Fehlrunden wartet die Probe auf die dritte; erst dann antwortet der Monitor.
        #expect(await eventually { control.reads == 2 })
        #expect(state(manager, 2) == .probing)
        control.setRead(.success(VCPReading(current: 70, maximum: 100)))
        #expect(await eventually { state(manager, 2) == .ready })
        #expect(control.reads == 3)
        #expect(monitor(manager, 2)?.usesSoftwareDimming == false)
        #expect(monitor(manager, 2)?.brightness == 70)
    }

    @Test("Keine dritte Runde nach Null-Antwort, Timeout oder I/O-Fehler", arguments: [
        DDCError.nullReply, .timeout, .hung, .readFailed(-1),
    ])
    func noThirdRoundAfterSilence(_ error: DDCError) async {
        let control = StubControl(read: .failure(error))
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in control }
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(await eventually { state(manager, 2) != .probing })
        #expect(control.reads == 2)
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
    }

    @Test("Verstümmelt, dann verstümmelt: nach der dritten Runde Software-Dimmung")
    func garbledThreeTimesFallsBack() async {
        let control = StubControl(read: .failure(.malformedReply))
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in control }
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(await eventually { state(manager, 2) != .probing })
        #expect(control.reads == 3)
        #expect(state(manager, 2) == .noResponse)
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
    }

    @Test("Probe erfolgreich: .ready")
    func probeReady() async {
        setup.displays = [Self.external(2, avService: 0x100)]
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(await eventually { state(manager, 2) != .probing })
        #expect(state(manager, 2) == .ready)
    }

    @Test("Hängender Kanal: Refresh nimmt denselben DDCService, keine zweite Queue, keine Kaskade")
    func hungServiceIsReused() async {
        let blocker = DispatchSemaphore(value: 0)
        let transport = MockTransport(blocker: blocker)
        var timing = DDCTiming.immediate
        timing.deadline = .milliseconds(100)
        let service = DDCService(transport: transport, label: "hung", timing: timing)
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in service }
        let manager = makeManager()

        manager.refresh(force: true)
        #expect(await eventually { state(manager, 2) != .probing })
        #expect(state(manager, 2) == .i2cTimeout)
        #expect(service.isHung)

        // „Monitore neu suchen“ während des Hängers.
        manager.refresh(force: true)
        #expect(await eventually { state(manager, 2) != .probing })
        #expect(state(manager, 2) == .i2cTimeout)
        #expect(setup.created == [0x100])
        #expect(service.pendingCalls == 1)

        blocker.signal()
        #expect(await eventually { !service.isHung && service.pendingCalls == 0 })
        #expect(transport.written.count == 1)
    }

    // MARK: - Software-Dimmung

    @Test("DDC-Fehler: Software-Dimmung, keine DDC-Writes, ohne gespeicherten Wert kein Abdunkeln")
    func probeFailureSwitchesToSoftware() async {
        let control = StubControl(read: .failure(.nullReply))
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in control }
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(await eventually { state(manager, 2) != .probing })
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
        #expect(monitor(manager, 2)?.brightness == 100)
        #expect(setup.gamma.levels == [2: 100])

        manager.setBrightness(40, for: 2)
        #expect(setup.gamma.levels == [2: 40])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(control.writes.isEmpty)
    }

    @Test("Ohne DDC-Kanal: sofort Software-Dimmung mit gespeichertem Wert")
    func noChannelUsesSoftware() async {
        setup.displays = [Self.external(2, avService: nil)]
        let manager = makeManager()
        manager.refresh(force: true)
        manager.setBrightness(30, for: 2)

        // Neuer Start: der gespeicherte Wert gilt sofort.
        let second = makeManager()
        second.refresh(force: true)
        #expect(second.monitors.first?.usesSoftwareDimming == true)
        #expect(second.monitors.first?.isAdjustable == true)
        #expect(setup.gamma.levels == [2: 30])
    }

    @Test("DDC funktioniert: keine Software-Dimmung")
    func readyUsesDDC() async {
        setup.displays = [Self.external(2, avService: 0x100)]
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(await eventually { state(manager, 2) == .ready })
        #expect(monitor(manager, 2)?.usesSoftwareDimming == false)
        #expect(setup.gamma.levels.isEmpty)
    }

    @Test("Erneut prüfen mit funktionierendem DDC: Gamma zurück, DDC übernimmt")
    func retryReturnsToDDC() async {
        let control = StubControl(read: .failure(.timeout))
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in control }
        let manager = makeManager()
        manager.refresh(force: true)
        #expect(await eventually { monitor(manager, 2)?.usesSoftwareDimming == true })
        manager.setBrightness(60, for: 2)

        control.setRead(.success(VCPReading(current: 80, maximum: 100)))
        manager.retry(2)
        // Während der Probe bleibt die Software-Dimmung stehen (kein Aufhellen).
        #expect(setup.gamma.levels == [2: 60])
        #expect(await eventually { state(manager, 2) == .ready })
        #expect(monitor(manager, 2)?.usesSoftwareDimming == false)
        #expect(setup.gamma.levels.isEmpty)
        // Der Gamma-Wert 60 geht nicht per DDC raus; ohne gespeicherten DDC-Wert bleibt
        // die Hintergrundbeleuchtung, wie der Monitor sie meldet.
        #expect(monitor(manager, 2)?.brightness == 80)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(control.writes.isEmpty)
    }

    @Test("DDC-Wert wird nie als Gamma übernommen (keine doppelte Abdunklung)")
    func ddcValueNotUsedForGamma() async {
        // Direkt angeschlossen: DDC setzt die Hintergrundbeleuchtung auf 30 %.
        let direct = StubControl()
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in direct }
        let first = makeManager()
        first.refresh(force: true)
        #expect(await eventually { state(first, 2) == .ready })
        first.setBrightness(30, for: 2)
        #expect(await eventually { direct.writes == [30] })

        // Am Dock antwortet DDC nicht. Die Beleuchtung steht noch auf 30 %, also kein Gamma.
        setup.makeControl = { _ in StubControl(read: .failure(.nullReply)) }
        let docked = makeManager()
        docked.refresh(force: true)
        #expect(await eventually { monitor(docked, 2)?.usesSoftwareDimming == true })
        #expect(monitor(docked, 2)?.brightness == 100)
        #expect(setup.gamma.levels == [2: 100])
        docked.setBrightness(70, for: 2)

        // Wieder direkt: Es gilt der DDC-Wert 30, nicht der Gamma-Wert 70.
        let again = StubControl(read: .success(VCPReading(current: 50, maximum: 100)))
        setup.makeControl = { _ in again }
        let third = makeManager()
        third.refresh(force: true)
        #expect(await eventually { state(third, 2) == .ready })
        #expect(monitor(third, 2)?.brightness == 30)
        #expect(setup.gamma.levels.isEmpty)
        #expect(await eventually { again.writes == [30] })

        // Und zurück ans Dock: der eigene Gamma-Wert 70 kommt wieder.
        setup.makeControl = { _ in StubControl(read: .failure(.nullReply)) }
        let fourth = makeManager()
        fourth.refresh(force: true)
        #expect(await eventually { monitor(fourth, 2)?.usesSoftwareDimming == true })
        #expect(setup.gamma.levels == [2: 70])
    }

    @Test("Refresh behält Software-Dimmung; Kurven komplett neu nur bei neuer Display-Menge oder nach Aufwachen")
    func refreshKeepsSoftwareDimming() async {
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in StubControl(read: .failure(.nullReply)) }
        let manager = makeManager()
        manager.refresh(force: true)
        #expect(await eventually { monitor(manager, 2)?.usesSoftwareDimming == true })
        manager.setBrightness(50, for: 2)
        let initial = setup.gamma.reapplied

        // „Monitore neu suchen“ mit gleicher Display-Menge: kein ColorSync-Reset.
        manager.refresh(force: true)
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
        #expect(setup.gamma.levels == [2: 50])
        #expect(setup.gamma.reapplied == initial)

        // Aufwachen: alles neu aufsetzen.
        manager.refresh(force: true, resetDimming: true, reconfigured: [])
        #expect(setup.gamma.reapplied == initial + 1)
        #expect(setup.overlay.reapplied == initial + 1)

        // Neuer Monitor: Display-Menge geändert.
        setup.displays.append(Self.external(3, avService: 0x200))
        manager.refresh(force: false)
        #expect(setup.gamma.reapplied == initial + 2)
    }

    @Test("Auflösungswechsel: nur das betroffene Display neu schreiben, kein Reset für alle")
    func resolutionChangeRefreshesOnlyAffectedDisplay() async {
        setup.displays = [Self.external(2, avService: nil), Self.external(3, avService: nil)]
        let manager = makeManager()
        manager.refresh(force: true)
        let reapplied = setup.gamma.reapplied

        manager.refresh(force: false, resetDimming: false, reconfigured: [3])

        #expect(setup.gamma.reapplied == reapplied)
        #expect(setup.gamma.refreshed == [[3]])
        #expect(setup.overlay.refreshed == [[3]])
        #expect(manager.monitors.map(\.id) == [2, 3])
    }

    // MARK: - DDC/CI je Monitor abwählen

    @Test("Gamma statt DDC/CI: Kanal weg, Software-Dimmung ohne DDC-Writes; DDC/CI: neuer Kanal, DDC übernimmt")
    func ddcToggle() async {
        let control = StubControl()
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in control }
        let manager = makeManager()
        manager.refresh(force: true)
        #expect(monitor(manager, 2)?.canUseDDC == true)
        #expect(monitor(manager, 2)?.preferredMethod == .ddc)
        #expect(await eventually { state(manager, 2) == .ready })
        manager.setBrightness(30, for: 2)
        #expect(await eventually { control.writes == [30] })

        manager.setBrightnessMethod(.gamma, for: 2)
        #expect(monitor(manager, 2)?.preferredMethod == .gamma)
        #expect(monitor(manager, 2)?.canUseDDC == true)
        #expect(state(manager, 2) == .disabled)
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
        #expect(monitor(manager, 2)?.isAdjustable == true)
        // Die Beleuchtung steht auf 30 %; ohne gespeicherten Software-Wert nicht abdunkeln.
        #expect(monitor(manager, 2)?.brightness == 100)
        #expect(setup.gamma.levels == [2: 100])
        #expect(setup.created == [0x100])

        manager.setBrightness(60, for: 2)
        #expect(setup.gamma.levels == [2: 60])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(control.writes == [30])

        // Overlay statt Gamma ist nur ein Wechsel des Software-Verfahrens, kein Refresh.
        manager.setBrightnessMethod(.overlay, for: 2)
        #expect(monitor(manager, 2)?.preferredMethod == .overlay)
        #expect(setup.gamma.levels.isEmpty)
        #expect(setup.overlay.levels == [2: 60])
        #expect(setup.created == [0x100])

        // „Monitore neu suchen“ und „Erneut prüfen“ legen keinen Kanal an.
        manager.refresh(force: true)
        manager.retry(2)
        #expect(setup.created == [0x100])
        #expect(state(manager, 2) == .disabled)

        // Wieder DDC/CI: neuer Kanal, Software-Dimmung bleibt bis zur Prüfung, dann DDC-Wert.
        control.setRead(.success(VCPReading(current: 50, maximum: 100)))
        manager.setBrightnessMethod(.ddc, for: 2)
        #expect(setup.created == [0x100, 0x100])
        #expect(state(manager, 2) == .probing)
        #expect(monitor(manager, 2)?.preferredMethod == .ddc)
        #expect(setup.overlay.levels == [2: 60])
        #expect(await eventually { state(manager, 2) == .ready })
        #expect(monitor(manager, 2)?.usesSoftwareDimming == false)
        #expect(setup.overlay.levels.isEmpty)
        #expect(await eventually { control.writes == [30, 30] })
    }

    @Test("Ohne AV-Service gibt es kein DDC/CI; die Wahl bleibt beim Software-Verfahren")
    func noAVServiceMeansNoDDC() {
        setup.displays = [Self.external(2, avService: nil)]
        let manager = makeManager()
        manager.refresh(force: true)
        #expect(monitor(manager, 2)?.canUseDDC == false)
        #expect(monitor(manager, 2)?.preferredMethod == .gamma)
        #expect(state(manager, 2) == .noChannel)
        manager.setBrightnessMethod(.ddc, for: 2)
        #expect(monitor(manager, 2)?.preferredMethod == .gamma)
        #expect(setup.created.isEmpty)
    }

    @Test("Gamma statt DDC/CI bleibt über den Neustart; der Software-Wert gilt sofort")
    func ddcDisabledPersists() async {
        setup.displays = [Self.external(2, avService: 0x100)]
        let manager = makeManager()
        manager.refresh(force: true)
        #expect(await eventually { state(manager, 2) == .ready })
        manager.setBrightnessMethod(.gamma, for: 2)
        manager.setBrightness(40, for: 2)

        let second = makeManager()
        second.refresh(force: true)
        #expect(setup.created == [0x100])
        #expect(state(second, 2) == .disabled)
        #expect(monitor(second, 2)?.preferredMethod == .gamma)
        #expect(await eventually { setup.gamma.levels == [2: 40] })
    }

    @Test("DDC/CI abwählen betrifft nur diesen Monitor, nicht das eingebaute Display")
    func ddcDisabledKeepsBuiltInControl() async {
        let control = StubControl()
        setup.displays = [Self.builtIn, Self.external(2, avService: 0x100)]
        BrightnessStore(storage: setup.preferences).setDDCEnabled(false, for: "19501-3148-2")
        let manager = DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            gamma: setup.gamma,
            overlay: setup.overlay,
            discover: { [setup] in setup.displays },
            makeExternalControl: { [setup] avServiceID, _, _ in
                setup.created.append(avServiceID)
                return StubControl()
            },
            makeBuiltInControl: { _ in control }
        )
        manager.refresh(force: true)

        #expect(setup.created.isEmpty)
        #expect(state(manager, 2) == .disabled)
        #expect(monitor(manager, 2)?.canUseDDC == true)
        #expect(await eventually { state(manager, 1) == .ready })
        #expect(monitor(manager, 1)?.usesSoftwareDimming == false)
        manager.setBrightness(70, for: 1)
        #expect(await eventually { control.writes == [70] })
    }

    // MARK: - Gamma oder Overlay

    @Test("Gamma-Tabelle nicht nutzbar: automatisch Overlay")
    func gammaFailureFallsBackToOverlay() async {
        setup.displays = [Self.external(2, avService: nil), Self.external(3, avService: nil)]
        setup.gamma.failing = [3]
        let manager = makeManager()
        manager.refresh(force: true)

        manager.setBrightness(40, for: 2)
        manager.setBrightness(30, for: 3)

        #expect(setup.gamma.levels == [2: 40])
        #expect(setup.overlay.levels == [3: 30])
        #expect(monitor(manager, 3)?.gammaUnavailable == true)
        #expect(monitor(manager, 3)?.dimming == .overlay)
        #expect(monitor(manager, 2)?.dimming == .gamma)
    }

    @Test("Umschalter Gamma/Overlay pro Monitor, gemerkt über Neustart")
    func dimmingMethodToggle() async {
        setup.displays = [Self.external(2, avService: nil)]
        let manager = makeManager()
        manager.refresh(force: true)
        manager.setBrightness(60, for: 2)
        #expect(setup.gamma.levels == [2: 60])

        manager.setDimmingMethod(.overlay, for: 2)
        #expect(setup.gamma.levels.isEmpty)
        #expect(setup.overlay.levels == [2: 60])

        let second = makeManager()
        second.refresh(force: true)
        #expect(monitor(second, 2)?.preferredDimming == .overlay)
        #expect(setup.overlay.levels == [2: 60])

        second.setDimmingMethod(.gamma, for: 2)
        #expect(setup.overlay.levels.isEmpty)
        #expect(setup.gamma.levels == [2: 60])
    }

    @Test("Zurück auf Gamma versucht Gamma neu; scheitert es, bleibt das Overlay")
    func choosingGammaRetries() async {
        setup.displays = [Self.external(2, avService: nil)]
        setup.gamma.failing = [2]
        let manager = makeManager()
        manager.refresh(force: true)
        manager.setBrightness(50, for: 2)
        #expect(monitor(manager, 2)?.dimming == .overlay)

        manager.setDimmingMethod(.gamma, for: 2)
        #expect(monitor(manager, 2)?.dimming == .overlay)
        #expect(setup.overlay.levels == [2: 50])

        setup.gamma.failing = []
        manager.setDimmingMethod(.gamma, for: 2)
        #expect(monitor(manager, 2)?.dimming == .gamma)
        #expect(setup.gamma.levels == [2: 50])
        #expect(setup.overlay.levels.isEmpty)
    }

    private static let builtIn = DiscoveredDisplay(
        id: 1, identity: DisplayIdentity(vendor: 1552, model: 1, serial: 1), name: "MacBook", kind: .builtIn
    )

    /// App-Store-Variante: keine Fabriken für DDC und das eingebaute Display.
    private func makeStoreManager() -> DisplayManager {
        DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            gamma: setup.gamma,
            overlay: setup.overlay,
            discover: { [setup] in setup.displays }
        )
    }

    @Test("Ohne Fabriken (App-Store-Variante): externe und eingebautes per Software")
    func withoutDDCFactory() async {
        setup.displays = [Self.builtIn, Self.external(2, avService: nil)]
        let manager = makeStoreManager()
        manager.refresh(force: true)

        #expect(monitor(manager, 1)?.state == .noChannel)
        #expect(monitor(manager, 1)?.usesSoftwareDimming == true)
        #expect(monitor(manager, 1)?.isAdjustable == true)
        #expect(monitor(manager, 1)?.brightness == 100)
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
        #expect(monitor(manager, 2)?.isAdjustable == true)
    }

    @Test("Eingebautes Display per Software: Wert gemerkt, Gamma oder Overlay wählbar")
    func builtInSoftwareDimming() async {
        setup.displays = [Self.builtIn]
        let manager = makeStoreManager()
        manager.refresh(force: true)

        manager.setBrightness(40, for: 1)
        #expect(setup.gamma.levels == [1: 40])
        manager.setDimmingMethod(.overlay, for: 1)
        #expect(setup.gamma.levels.isEmpty)
        #expect(setup.overlay.levels == [1: 40])

        // Neustart: Wert und Verfahren kommen zurück, nur als Software-Wert.
        let restarted = makeStoreManager()
        restarted.refresh(force: true)
        #expect(await eventually { monitor(restarted, 1)?.brightness == 40 }) // blendet vom ungedimmten Stand aus über
        #expect(monitor(restarted, 1)?.dimming == .overlay)
        #expect(BrightnessStore(storage: setup.preferences).brightness(for: Self.builtIn.identity.storageKey, mode: .ddc) == nil)
    }

    @Test("Eingebautes Display mit Steuerung (Direct): keine Software-Dimmung")
    func builtInWithControl() async {
        setup.displays = [Self.builtIn]
        let manager = DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            gamma: setup.gamma,
            overlay: setup.overlay,
            discover: { [setup] in setup.displays },
            makeBuiltInControl: { _ in StubControl(read: .failure(.timeout)) }
        )
        manager.refresh(force: true)
        #expect(await eventually { monitor(manager, 1)?.state == .i2cTimeout })
        #expect(monitor(manager, 1)?.usesSoftwareDimming == false)
        manager.setDimmingMethod(.overlay, for: 1)
        #expect(setup.overlay.levels.isEmpty)
        #expect(setup.gamma.levels.isEmpty)
    }

    // MARK: Überblenden

    @Test("Überblenden: in 2 s mit höchstens 40 Schritten zum Ziel, Ziel sofort gespeichert")
    func fadeSteps() async {
        setup.displays = [Self.external(2, avService: nil)]
        let sleeper = ManualSleeper()
        let manager = makeManager(sleeper: sleeper)
        manager.refresh(force: true)
        let key = monitor(manager, 2)!.storageKey
        #expect(monitor(manager, 2)?.brightness == 100)

        var started = sleeper.started.makeAsyncIterator()
        #expect(manager.fadeBrightness(to: 20, for: 2, reason: .profileChange, duration: .seconds(2)))
        #expect(monitor(manager, 2)?.brightness == 100)
        #expect(BrightnessStore(storage: setup.preferences).brightness(for: key, mode: .software) == 20)

        var seen: [Double] = []
        while let interval = await started.next() {
            #expect(interval == .milliseconds(50))
            sleeper.wake()
            let before = seen.last ?? 100
            #expect(await eventually { monitor(manager, 2)?.brightness != before })
            seen.append(monitor(manager, 2)!.brightness)
            if seen.last == 20 { break }
        }
        #expect(seen.count == 40)
        #expect(seen.first == 98)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 > $1 })
        #expect(setup.gamma.levels[2] == 20)
    }

    @Test("Kleine Änderung ohne Überblenden; setBrightness bricht eine Überblendung ab")
    func fadeShortAndCancel() async {
        setup.displays = [Self.external(2, avService: nil)]
        let sleeper = ManualSleeper()
        let manager = makeManager(sleeper: sleeper)
        manager.refresh(force: true)

        manager.fadeBrightness(to: 99, for: 2, reason: .profileChange)
        #expect(monitor(manager, 2)?.brightness == 99)

        var started = sleeper.started.makeAsyncIterator()
        manager.fadeBrightness(to: 39, for: 2, reason: .profileChange, duration: .seconds(2))
        _ = await started.next()
        sleeper.wake()
        #expect(await eventually { monitor(manager, 2)?.brightness == 98 }) // 99 − 60/40, gerundet
        _ = await started.next()

        manager.setBrightness(70, for: 2)
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(monitor(manager, 2)?.brightness == 70)
    }

    @Test("DDC scheitert: Software-Dimmung blendet vom ungedimmten Stand zum gespeicherten Wert über")
    func softwareFallbackFades() async {
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in StubControl(read: .failure(.timeout)) }
        BrightnessStore(storage: setup.preferences).setBrightness(
            40, for: Self.external(2, avService: nil).identity.storageKey, mode: .software
        )
        let sleeper = ManualSleeper()
        let manager = makeManager(sleeper: sleeper, systemFade: .milliseconds(500))
        var jobs: [BrightnessJob] = []
        manager.onBrightnessJob = { jobs.append($0) }
        var started = sleeper.started.makeAsyncIterator()
        manager.refresh(force: true)

        // Probe-Pause zwischen zwei Runden, dann der erste Schritt der Überblendung.
        var interval = await started.next()
        while interval == .milliseconds(1) {
            sleeper.wake()
            interval = await started.next()
        }
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
        #expect(monitor(manager, 2)?.brightness == 100)
        #expect(jobs.map(\.reason) == [.softwareFallback])
        #expect(jobs.first?.target == 40)
        #expect(jobs.first?.duration == .milliseconds(500))
        sleeper.wake()
        #expect(await eventually { monitor(manager, 2)?.brightness == 94 })
        while monitor(manager, 2)?.brightness != 40 {
            _ = await started.next()
            sleeper.wake()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(setup.gamma.levels[2] == 40)
    }

    @Test("Überblendung beginnt beim echten Wert des eingebauten Displays, nie beim Platzhalter der Prüfung")
    func fadeStartsAtRealValue() async {
        let gate = GatedControl()
        let sleeper = ManualSleeper()
        let manager = DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            sleep: { await sleeper.sleep($0) },
            gamma: setup.gamma,
            overlay: setup.overlay,
            discover: { [Self.builtIn] },
            makeBuiltInControl: { _ in gate }
        )
        var jobs: [BrightnessJob] = []
        manager.onBrightnessJob = { jobs.append($0) }
        manager.refresh(force: true)
        #expect(monitor(manager, 1)?.brightness == 50) // Platzhalter
        #expect(!manager.fadeBrightness(to: 80, for: 1, reason: .profileChange))
        #expect(jobs.isEmpty)

        gate.release(with: .success(VCPReading(current: 30, maximum: 100)))
        #expect(await eventually { monitor(manager, 1)?.state == .ready })
        #expect(monitor(manager, 1)?.brightness == 30)

        // macOS hat leicht nachgeregelt (2 Punkte, keine fremde Änderung): Start bei 32.
        gate.release(with: .success(VCPReading(current: 32, maximum: 100)))
        var started = sleeper.started.makeAsyncIterator()
        #expect(manager.fadeBrightness(to: 80, for: 1, reason: .profileChange, duration: .seconds(2)))
        _ = await started.next()
        #expect(jobs.last?.remembered == 30)
        #expect(jobs.last?.actual == 32)
        #expect(monitor(manager, 1)?.brightness == 32)
        sleeper.wake()
        #expect(await eventually { monitor(manager, 1)?.brightness == 33 }) // 32 + 48/40
    }

    @Test("Fremde Änderung: echter Wert weicht um mehr als 3 Punkte ab, wird übernommen, nichts geschrieben")
    func externalChangeAdopted() async {
        let control = StubControl(read: .success(VCPReading(current: 50, maximum: 100)))
        let manager = DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            gamma: setup.gamma,
            overlay: setup.overlay,
            discover: { [Self.builtIn] },
            makeBuiltInControl: { _ in control }
        )
        var jobs: [BrightnessJob] = []
        manager.onBrightnessJob = { jobs.append($0) }
        manager.refresh(force: true)
        #expect(await eventually { monitor(manager, 1)?.state == .ready })

        control.setRead(.success(VCPReading(current: 75, maximum: 100)))
        manager.fadeBrightness(to: 20, for: 1, reason: .profileChange)
        #expect(await eventually { jobs.last?.reason == .externalChange })
        #expect(jobs.last?.target == 75)
        #expect(monitor(manager, 1)?.brightness == 75)
        #expect(control.writes.isEmpty)
    }

    @Test("Keine fremde Änderung, wenn der Read direkt nach dem eigenen Write um höchstens 3 abweicht")
    func smallDeviationAfterOwnWriteIsNotExternal() async {
        let control = StubControl(read: .success(VCPReading(current: 50, maximum: 100)))
        let manager = DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            fadeDuration: .zero,
            systemFadeDuration: .zero,
            gamma: setup.gamma,
            overlay: setup.overlay,
            discover: { [Self.builtIn] },
            makeBuiltInControl: { _ in control }
        )
        var jobs: [BrightnessJob] = []
        manager.onBrightnessJob = { jobs.append($0) }
        manager.refresh(force: true)
        #expect(await eventually { monitor(manager, 1)?.state == .ready })

        manager.fadeBrightness(to: 20, for: 1, reason: .profileChange)
        #expect(await eventually { control.writes.last == 20 })
        try? await Task.sleep(for: .milliseconds(100)) // Drossel frei

        // Panel meldet 23 statt 20 (Rundung, Nachregeln): Grenze, keine fremde Änderung.
        control.setRead(.success(VCPReading(current: 23, maximum: 100)))
        manager.fadeBrightness(to: 80, for: 1, reason: .profileChange)
        #expect(await eventually { control.writes.last == 80 })
        #expect(!jobs.contains { $0.reason == .externalChange })
        #expect(jobs.last?.actual == 23)
        #expect(jobs.last?.target == 80)
    }

    @Test("Kein Leer-Auftrag: gleiches Ziel und Refresh ohne Änderung melden nichts")
    func noEmptyJobs() async {
        setup.displays = [Self.external(2, avService: nil)]
        let manager = makeManager()
        var jobs: [BrightnessJob] = []
        manager.onBrightnessJob = { jobs.append($0) }
        manager.refresh(force: true)
        #expect(jobs.isEmpty) // ungedimmt, nichts gespeichert: schon am Ziel

        manager.setBrightness(40, for: 2)
        #expect(jobs.map(\.reason) == [.manual])
        #expect(manager.fadeBrightness(to: 40, for: 2, reason: .profileChange))
        #expect(manager.fadeBrightness(to: 40.3, for: 2, reason: .lux(raw: 50, filtered: 50, origin: .deskSensor)))
        manager.refresh(force: true) // sichtbar 40, gespeichert 40
        #expect(jobs.map(\.reason) == [.manual])
        #expect(monitor(manager, 2)?.brightness == 40)
    }

    @Test("Dock-Erkennung aus dem DisplayPort-Link")
    func intermediaryFromLink() async {
        let dock = DisplayPortLink(branchOUI: [0x00, 0xE0, 0x4C], branchDeviceID: "Dp1.4", tunneled: true)
        setup.displays = [
            Self.external(2, avService: 0x100, link: dock),
            Self.external(3, avService: 0x200, link: DisplayPortLink(branchOUI: [0x00, 0x1C, 0xF8], tunneled: false)),
            Self.external(4, avService: 0x300, link: DisplayPortLink(tunneled: true)),
        ]
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(monitor(manager, 2)?.intermediary == .dock)
        #expect(monitor(manager, 2)?.branchVendor == "Realtek")
        #expect(monitor(manager, 3)?.intermediary == .adapter)
        #expect(monitor(manager, 4)?.intermediary == nil)
    }
}
