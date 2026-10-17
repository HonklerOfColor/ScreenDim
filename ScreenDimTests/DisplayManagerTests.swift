import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite("DisplayManager: Kanäle über Refreshes")
struct DisplayManagerTests {
    /// Was die Discovery gerade „findet“.
    private final class Setup {
        var displays: [DiscoveredDisplay] = []
        var created: [UInt64] = []
        var makeControl: (UInt64) -> any DDCControlling = { _ in StubControl() }
        let dimmer = StubDimmer()
    }

    private let setup = Setup()
    private let suiteName = "ScreenDimTests.manager.\(UUID().uuidString)"

    private func makeManager() -> DisplayManager {
        let setup = setup
        return DisplayManager(
            store: BrightnessStore(defaults: UserDefaults(suiteName: suiteName)!),
            timing: .immediate,
            probeRetryDelay: .milliseconds(1),
            dimmer: setup.dimmer,
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
        #expect(setup.dimmer.levels == [2: 100])

        manager.setBrightness(40, for: 2)
        #expect(setup.dimmer.levels == [2: 40])
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
        #expect(setup.dimmer.levels == [2: 30])
    }

    @Test("DDC funktioniert: keine Software-Dimmung")
    func readyUsesDDC() async {
        setup.displays = [Self.external(2, avService: 0x100)]
        let manager = makeManager()
        manager.refresh(force: true)

        #expect(await eventually { state(manager, 2) == .ready })
        #expect(monitor(manager, 2)?.usesSoftwareDimming == false)
        #expect(setup.dimmer.levels.isEmpty)
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
        #expect(setup.dimmer.levels == [2: 60])
        #expect(await eventually { state(manager, 2) == .ready })
        #expect(monitor(manager, 2)?.usesSoftwareDimming == false)
        #expect(setup.dimmer.levels.isEmpty)
        #expect(await eventually { control.writes == [60] })
    }

    @Test("Refresh behält Software-Dimmung und schreibt Gamma neu")
    func refreshKeepsSoftwareDimming() async {
        setup.displays = [Self.external(2, avService: 0x100)]
        setup.makeControl = { _ in StubControl(read: .failure(.nullReply)) }
        let manager = makeManager()
        manager.refresh(force: true)
        #expect(await eventually { monitor(manager, 2)?.usesSoftwareDimming == true })
        manager.setBrightness(50, for: 2)

        manager.refresh(force: true)
        #expect(monitor(manager, 2)?.usesSoftwareDimming == true)
        #expect(setup.dimmer.levels == [2: 50])
        #expect(setup.dimmer.reapplied >= 2)
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
