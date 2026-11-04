import CoreGraphics
import Foundation
import Testing
@testable import ScreenDimKit

@MainActor
@Suite("Leerlauf: abdunkeln ohne Eingabe")
struct IdleDimmerTests {
    private final class Setup {
        let gamma = StubDimmer()
        let overlay = StubDimmer()
        let preferences = MemoryPreferences()
        let input = StubInput()
        /// Schlaf des `IdleDimmer`; Überblendungen des Managers haben ihren eigenen.
        let sleeper = ManualSleeper()
        var displays: [DiscoveredDisplay] = [IdleDimmerTests.display(2), IdleDimmerTests.display(3)]
        var makeControl: (UInt64) -> any DDCControlling = { _ in StubControl() }
        /// Hält den Dimmer am Leben; seine Tasks halten ihn nur schwach.
        var dimmer: IdleDimmer?
    }

    private let setup = Setup()
    private let timeout: Duration = .seconds(900)

    nonisolated static func display(_ id: CGDirectDisplayID, avService: UInt64? = nil) -> DiscoveredDisplay {
        DiscoveredDisplay(
            id: id,
            identity: DisplayIdentity(vendor: 19501, model: 3148, serial: id),
            name: "Monitor \(id)",
            kind: .external(avServiceID: avService),
            link: nil
        )
    }

    /// Ohne AV-Service dimmen beide Monitore per Gamma. Monitor 2 steht auf 70, Monitor 3
    /// ist mit 3 dunkler als der Deckel.
    private func makeManager(fade: Duration = .zero, sleeper: ManualSleeper? = nil) -> DisplayManager {
        let setup = setup
        let manager = DisplayManager(
            store: BrightnessStore(storage: setup.preferences),
            timing: .immediate,
            probeRetryDelay: .milliseconds(1),
            probeLateRetryDelay: .milliseconds(1),
            fadeDuration: fade,
            systemFadeDuration: .zero,
            sleep: { duration in
                if let sleeper { await sleeper.sleep(duration) } else { try? await Task.sleep(for: duration) }
            },
            gamma: setup.gamma,
            overlay: setup.overlay,
            blanker: StubBlanker(),
            discover: { _ in setup.displays },
            makeExternalControl: { avServiceID, _, _ in setup.makeControl(avServiceID) }
        )
        manager.refresh(force: true)
        for monitor in manager.monitors where monitor.usesSoftwareDimming {
            manager.setBrightness(monitor.id == 2 ? 70 : 3, for: monitor.id)
        }
        return manager
    }

    private func makeDimmer(_ manager: DisplayManager, enabled: Bool = true) -> IdleDimmer {
        let setup = setup
        let sleeper = setup.sleeper
        let dimmer = IdleDimmer(
            manager: manager,
            preferences: setup.preferences,
            input: setup.input,
            sleep: { await sleeper.sleep($0) }
        )
        dimmer.setTimeout(timeout)
        dimmer.setLevel(5)
        dimmer.setEnabled(enabled)
        setup.dimmer = dimmer
        return dimmer
    }

    private func monitor(_ manager: DisplayManager, _ id: CGDirectDisplayID) -> DisplayManager.Monitor? {
        manager.monitors.first { $0.id == id }
    }

    /// Startet abgedunkelt: Die Zeit seit der letzten Eingabe ist schon um. Abgedunkelt
    /// beginnt die Prüfung auf Tasten mit einem Schlaf von `inputCheckInterval`.
    private func startDimmed(_ manager: DisplayManager) -> IdleDimmer {
        setup.input.timeSinceLastInput = timeout
        let dimmer = makeDimmer(manager)
        dimmer.start()
        return dimmer
    }

    // MARK: Ablauf

    @Test("Aus (Standard): auch nach langer Zeit ohne Eingabe bleibt alles, wie es ist")
    func disabledByDefault() async {
        let manager = makeManager()
        setup.input.timeSinceLastInput = .seconds(7200)
        let dimmer = IdleDimmer(manager: manager, preferences: setup.preferences, input: setup.input)
        #expect(!dimmer.isEnabled)
        #expect(dimmer.timeout == IdleDimmer.defaultTimeout)
        #expect(dimmer.level == IdleDimmer.defaultLevel)
        dimmer.start()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!manager.isIdleDimmed)
        #expect(setup.gamma.levels[2] == 70)
    }

    @Test("Zeit um: Ausgabe höchstens 5 %, eingestellter und gespeicherter Wert bleiben, dunklere Monitore auch")
    func dimsOutputOnly() async {
        let manager = makeManager()
        let key = monitor(manager, 2)!.storageKey
        var jobs: [BrightnessJob] = []
        manager.onBrightnessJob = { jobs.append($0) }
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        _ = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        #expect(manager.isIdleDimmed)
        #expect(setup.gamma.levels[2] == 5)
        #expect(setup.gamma.levels[3] == 3)
        #expect(monitor(manager, 2)?.brightness == 70)
        #expect(BrightnessStore(storage: setup.preferences).brightness(for: key, mode: .software) == 70)
        #expect(jobs.map(\.reason) == [.idleDim])
        #expect(jobs.first?.storageKey == key)
        #expect(jobs.first?.target == 5)
    }

    @Test("Wartet ohne Takt bis zum frühesten Ablauf und rechnet nach einer Eingabe neu")
    func waitsUntilTimeout() async {
        let manager = makeManager()
        setup.input.timeSinceLastInput = .seconds(600)
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        let dimmer = makeDimmer(manager)
        dimmer.start()
        #expect(await started.next() == .seconds(300))

        // Zwischendurch benutzt: wieder die volle Zeit ab der letzten Eingabe.
        setup.input.timeSinceLastInput = .seconds(100)
        sleeper.wake()
        #expect(await started.next() == .seconds(800))
        #expect(!manager.isIdleDimmed)

        setup.input.timeSinceLastInput = timeout
        sleeper.wake()
        #expect(await started.next() == IdleDimmer.inputCheckInterval)
        #expect(manager.isIdleDimmed)
        #expect(dimmer.isDimmed)
    }

    @Test("Mausbewegung: Helligkeit sofort zurück, danach wieder Warten auf den Ablauf")
    func mouseRestores() async {
        let manager = makeManager()
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        let dimmer = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        setup.input.timeSinceLastInput = .zero
        setup.input.fire()
        #expect(!manager.isIdleDimmed)
        #expect(!dimmer.isDimmed)
        #expect(setup.gamma.levels[2] == 70)
        #expect(setup.gamma.levels[3] == 3)
        #expect(await started.next() == timeout)
        #expect(!setup.input.isObserving)
    }

    @Test("Taste ohne Event-Monitor: Die Prüfung je Sekunde sieht die neue Eingabe")
    func keyRestores() async {
        let manager = makeManager()
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        let dimmer = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        // Ohne Eingabe wächst die Zeit nur weiter: abgedunkelt bleiben.
        setup.input.timeSinceLastInput = timeout + .seconds(1)
        sleeper.wake()
        #expect(await started.next() == IdleDimmer.inputCheckInterval)
        #expect(dimmer.isDimmed)

        setup.input.timeSinceLastInput = .milliseconds(300)
        sleeper.wake()
        #expect(await started.next() == timeout - .milliseconds(300))
        #expect(!dimmer.isDimmed)
        #expect(setup.gamma.levels[2] == 70)
    }

    @Test("Nur Eingaben zählen: nach dem Zurückholen beim nächsten Ablauf wieder abdunkeln")
    func dimsAgainAfterNextTimeout() async {
        let manager = makeManager()
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        _ = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        setup.input.timeSinceLastInput = .zero
        setup.input.fire()
        #expect(await started.next() == timeout)
        #expect(!manager.isIdleDimmed)

        // Wieder die volle Zeit ohne Eingabe, etwa während ein Video läuft.
        setup.input.timeSinceLastInput = timeout
        sleeper.wake()
        #expect(await started.next() == IdleDimmer.inputCheckInterval)
        #expect(manager.isIdleDimmed)
        #expect(setup.gamma.levels[2] == 5)
    }

    @Test("Bildschirme schlafen: nichts beobachten; beim Aufwachen kurz danach Helligkeit zurück")
    func screensSleepAndWake() async {
        let manager = makeManager()
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        let dimmer = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        dimmer.screensDidSleep()
        #expect(!setup.input.isObserving)
        #expect(manager.isIdleDimmed)

        dimmer.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        #expect(manager.isIdleDimmed)
        setup.input.timeSinceLastInput = .zero
        sleeper.wake()
        #expect(await started.next() == timeout)
        #expect(!manager.isIdleDimmed)
        #expect(setup.gamma.levels[2] == 70)
    }

    @Test("Bildschirme schlafen, bevor die Zeit um ist: kein Abdunkeln, nach dem Aufwachen neu warten")
    func screensSleepBeforeTimeout() async {
        let manager = makeManager()
        setup.input.timeSinceLastInput = .seconds(600)
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        let dimmer = makeDimmer(manager)
        dimmer.start()
        #expect(await started.next() == .seconds(300))

        dimmer.screensDidSleep()
        setup.input.timeSinceLastInput = timeout
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!manager.isIdleDimmed)

        setup.input.timeSinceLastInput = .seconds(1)
        dimmer.screensDidWake()
        #expect(await started.next() == timeout - .seconds(1))
        #expect(!manager.isIdleDimmed)
    }

    // MARK: Zusammenspiel mit dem Manager

    @Test("Licht während der Dimmung: Wert folgt, Ausgabe bleibt gedeckelt; danach gilt der neue Wert")
    func lightWhileDimmed() async {
        let manager = makeManager()
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        _ = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        manager.fadeBrightness(to: 80, for: 2, reason: .profileChange)
        #expect(monitor(manager, 2)?.brightness == 80)
        #expect(setup.gamma.levels[2] == 5)

        setup.input.timeSinceLastInput = .zero
        setup.input.fire()
        #expect(setup.gamma.levels[2] == 80)
        _ = await started.next()
    }

    @Test("Regler oder Tastenkürzel heben die Dimmung sofort auf")
    func manualEndsDim() async {
        let manager = makeManager()
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        _ = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        manager.setBrightness(60, for: 2)
        #expect(!manager.isIdleDimmed)
        #expect(setup.gamma.levels[2] == 60)
        #expect(setup.gamma.levels[3] == 3)
    }

    @Test("DDC: Deckel per Write, gleiche Werte gehen nicht noch einmal raus, gespeichert bleibt der eingestellte Wert")
    func ddcCapped() async {
        let control = StubControl(read: .success(VCPReading(current: 50, maximum: 100)))
        setup.displays = [Self.display(4, avService: 0x100)]
        setup.makeControl = { _ in control }
        let manager = makeManager()
        let key = Self.display(4).identity.storageKey
        #expect(await eventually { monitor(manager, 4)?.state == .ready })
        manager.setBrightness(70, for: 4)
        #expect(await eventually { control.writes == [70] })

        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        _ = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)
        #expect(await eventually { control.writes == [70, 5] })

        // Licht verstellt den Wert; die Ausgabe bleibt 5 und wird nicht wiederholt.
        manager.fadeBrightness(to: 80, for: 4, reason: .profileChange)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(control.writes == [70, 5])
        #expect(BrightnessStore(storage: setup.preferences).brightness(for: key, mode: .ddc) == 80)

        setup.input.timeSinceLastInput = .zero
        setup.input.fire()
        #expect(await eventually { control.writes == [70, 5, 80] })
        _ = await started.next()
    }

    @Test("Abdunkeln überblendet je Monitor anteilig über die ganze Dauer")
    func dimFades() async {
        let fadeSleeper = ManualSleeper()
        let manager = makeManager(fade: .seconds(2), sleeper: fadeSleeper)
        var steps = fadeSleeper.started.makeAsyncIterator()
        manager.beginIdleDim(to: 5)
        #expect(setup.gamma.levels[2] == 70)

        var seen: [Double] = []
        while let interval = await steps.next() {
            #expect(interval == .milliseconds(50))
            let before = setup.gamma.levels[2]
            fadeSleeper.wake()
            #expect(await eventually { setup.gamma.levels[2] != before })
            seen.append(setup.gamma.levels[2]!)
            if seen.last == 5 { break }
        }
        #expect(seen.first == 68) // 70 − 65/40, gerundet
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(setup.gamma.levels[3] == 3)

        // Zurück mit der kurzen Dauer (hier ohne Überblendung).
        manager.endIdleDim()
        #expect(setup.gamma.levels[2] == 70)
    }

    // MARK: Einstellungen

    @Test("Einstellungen bleiben erhalten; Helligkeit auf 0…50 begrenzt")
    func settingsPersist() async {
        let manager = makeManager()
        let dimmer = makeDimmer(manager)
        dimmer.setTimeout(.seconds(300))
        dimmer.setLevel(80)
        #expect(dimmer.level == 50)
        #expect(dimmer.timeoutMinutes == 5)

        let reloaded = IdleDimmer(manager: manager, preferences: setup.preferences, input: setup.input)
        #expect(reloaded.isEnabled)
        #expect(reloaded.timeout == .seconds(300))
        #expect(reloaded.level == 50)
    }

    @Test("Ausschalten während abgedunkelt: Helligkeit zurück, kein Warten mehr")
    func disableWhileDimmed() async {
        let manager = makeManager()
        let sleeper = setup.sleeper
        var started = sleeper.started.makeAsyncIterator()
        let dimmer = startDimmed(manager)
        #expect(await started.next() == IdleDimmer.inputCheckInterval)

        dimmer.setEnabled(false)
        #expect(!manager.isIdleDimmed)
        #expect(!setup.input.isObserving)
        #expect(setup.gamma.levels[2] == 70)
    }
}
