import CoreGraphics
import Foundation
import Security
import Testing
@testable import ScreenDimKit

@MainActor
@Suite("SensorController: Anwesenheit, Licht, Kopplung")
struct SensorControllerTests {
    private static let host = "screendim-desk-a1b2c3.local"
    private static let sensor = DiscoveredSensor(name: "screendim-desk-a1b2c3", hostname: host, firmware: "1.0.0")
    private static let code = PairingCode(normalizing: "ABCD-EFGH")!

    private let preferences = MemoryPreferences()
    private let credentials = MemoryCredentials()
    private let http = StubSensorHTTP()
    private let input = StubInput()
    private let blanker = StubBlanker()
    private let gamma = StubDimmer()
    private let displaySleep = StubDisplaySleep()
    /// Warten bis zum Ausschalten und nach dem Aufwachen.
    private let sleeper = ManualSleeper()
    private let source = StubSensorSource()
    private let clock = ManualNow()
    /// Was die Fabrik für „Helligkeit automatisch anpassen“ meldet.
    private let autoBrightness = AutoBrightnessFlag()
    private let manager: DisplayManager

    init() {
        manager = DisplayManager(
            store: BrightnessStore(storage: preferences),
            timing: .immediate,
            fadeDuration: .zero,
            systemFadeDuration: .zero,
            gamma: gamma,
            overlay: StubDimmer(),
            blanker: blanker,
            discover: { _ in
                [DiscoveredDisplay(
                    id: 7,
                    identity: DisplayIdentity(vendor: 1, model: 2, serial: 3),
                    name: "Monitor 7",
                    kind: .external(avServiceID: nil)
                )]
            }
        )
        manager.refresh(force: true)
    }

    private func makeController(
        paired: Bool = true,
        demo: Bool = false,
        manager: DisplayManager? = nil
    ) -> SensorController {
        if paired {
            preferences.set(true, forKey: SensorController.Keys.enabled)
            preferences.set(Self.host, forKey: SensorController.Keys.hostname)
            try? credentials.save(Self.code, for: Self.host)
        }
        let source = source
        let sleeper = sleeper
        return SensorController(
            manager: manager ?? self.manager,
            preferences: preferences,
            credentials: credentials,
            http: http,
            input: input,
            displaySleep: displaySleep,
            wait: { await sleeper.sleep($0) },
            demoAtLaunch: demo,
            makeLiveSource: { _, _ in source },
            makeSimulation: { SimulatedSensorSource(schedule: $0, seed: 1) },
            isAutoBrightnessEnabled: { [autoBrightness] in autoBrightness.read() },
            now: { [clock] in clock.instant }
        )
    }

    /// MacBook mit offenem Deckel (eingebautes Display 1) und externem Monitor 7.
    private func makeLaptopManager(
        builtInControl: StubControl,
        fade: Duration = .zero,
        sleeper: ManualSleeper? = nil
    ) -> DisplayManager {
        let manager = DisplayManager(
            store: BrightnessStore(storage: preferences),
            timing: .immediate,
            fadeDuration: fade,
            systemFadeDuration: .zero,
            sleep: { duration in
                if let sleeper { await sleeper.sleep(duration) } else { try? await Task.sleep(for: duration) }
            },
            gamma: StubDimmer(),
            overlay: StubDimmer(),
            blanker: blanker,
            discover: { _ in
                [
                    DiscoveredDisplay(
                        id: 1, identity: DisplayIdentity(vendor: 1552, model: 1, serial: 1), name: "MacBook", kind: .builtIn
                    ),
                    DiscoveredDisplay(
                        id: 7, identity: DisplayIdentity(vendor: 1, model: 2, serial: 3), name: "Monitor 7",
                        kind: .external(avServiceID: nil)
                    ),
                ]
            },
            makeBuiltInControl: { _ in builtInControl }
        )
        manager.refresh(force: true)
        return manager
    }

    private var brightness: Double? { manager.monitors.first?.brightness }

    /// Helligkeit aus dem Licht nur für Monitor 7.
    private static func monitor7(_ percent: Double) -> [LightLevel] {
        [LightLevel(storageKey: "1-2-3", name: "Monitor 7", percent: percent)]
    }

    @Test("Ohne Einstellung: kein Sensor, keine Abfrage")
    func offByDefault() {
        let controller = makeController(paired: false)
        controller.start()
        #expect(controller.status == .off)
        #expect(!controller.isEnabled)
        #expect(!controller.isDemoActive)
        #expect(http.requests.isEmpty)
    }

    @Test("Weg: erst abdunkeln, nach der Zeit schlafen die Displays; da weckt sie, Helligkeit nach dem Aufwachen")
    func twoStageAbsence() async {
        let controller = makeController()
        var arrivals = 0
        controller.onArrival = { arrivals += 1 }
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .presence(true), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
        #expect(manager.dimCauses == [.absence])
        #expect(gamma.levels[7] == SensorController.defaultAbsenceLevel)
        #expect(brightness == 100)
        #expect(input.isObserving)
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)
        #expect(displaySleep.sleeps == 0)

        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .off })
        #expect(displaySleep.sleeps == 1)
        #expect(blanker.blanked.isEmpty)
        // Bis macOS den Schlaf meldet, holt die Maus sie zurück; danach weckt macOS selbst.
        #expect(input.isObserving)
        controller.screensDidSleep()
        #expect(!input.isObserving)

        source.send(.presence(true))
        #expect(await eventually { displaySleep.wakes == 1 })
        #expect(arrivals == 1)
        // Erst nach dem Aufwachen: Schlafende Monitore nehmen keine Helligkeit an.
        #expect(controller.absenceStage == .off)
        #expect(manager.dimCauses == [.absence])

        controller.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .none })
        #expect(manager.dimCauses.isEmpty)
        #expect(gamma.levels[7] == 100)
    }

    @Test("Eingabe gewinnt: kurz vorher getippt bleibt an, Maus holt sofort zurück")
    func inputWins() async {
        let controller = makeController()
        controller.start()
        input.timeSinceLastInput = .seconds(1)
        source.send(.connection(.connected), .presence(false))
        #expect(await eventually { controller.presence == false })
        #expect(controller.absenceStage == .none)

        input.timeSinceLastInput = .seconds(60)
        source.send(.presence(true), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
        input.fire()
        #expect(controller.absenceStage == .none)
        #expect(manager.dimCauses.isEmpty)
        #expect(!input.isObserving)
        // Weiter „weg“ ohne Wechsel dunkelt nicht erneut ab.
        source.send(.presence(false), .heartbeat)
        #expect(await eventually { controller.presence == false })
        #expect(controller.absenceStage == .none)
    }

    @Test("Eingabe ohne Event-Monitor (Taste, Kürzel) seit dem Abdunkeln: nicht ausschalten")
    func inputSinceDimKeepsScreensOn() async {
        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)

        clock.advance(by: .seconds(300))
        input.timeSinceLastInput = .seconds(10)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .none })
        #expect(displaySleep.sleeps == 0)
        #expect(manager.dimCauses.isEmpty)
    }

    @Test("Regler während der Abwesenheit: Abwesenheit endet, nichts geht mehr aus")
    func manualEndsAbsence() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })

        manager.setBrightness(60, for: 7)
        #expect(controller.absenceStage == .none)
        #expect(manager.dimCauses.isEmpty)
        #expect(gamma.levels[7] == 60)
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(displaySleep.sleeps == 0)
    }

    @Test("„Nie“ bleibt abgedunkelt; kürzeste Zeit 30 s, auch für das gespeicherte „Sofort“")
    func offDelayChoices() async {
        // Von einer älteren Version gespeichert: 0 hieß „sofort“.
        preferences.set(0.0, forKey: SensorController.Keys.absenceOffDelay)
        let controller = makeController()
        #expect(controller.absenceOffDelay == SensorController.minimumAbsenceOffDelay)
        #expect(preferences.object(forKey: SensorController.Keys.absenceOffDelay) as? Double == 30)
        controller.setAbsenceOffDelay(.zero)
        #expect(controller.absenceOffDelay == .seconds(30))
        #expect(SensorController.absenceOffChoices.compactMap(\.self).min() == 30)

        var started = sleeper.started.makeAsyncIterator()
        controller.setAbsenceOffDelay(nil)
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.absenceStage == .dimmed)
        #expect(displaySleep.sleeps == 0)

        source.send(.presence(true))
        #expect(await eventually { controller.absenceStage == .none })
        // Auch die kürzeste Zeit dunkelt erst ab.
        controller.setAbsenceOffDelay(.seconds(30))
        source.send(.presence(false))
        #expect(await started.next() == .seconds(30))
        #expect(controller.absenceStage == .dimmed)
        #expect(displaySleep.sleeps == 0)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .off })
        #expect(displaySleep.sleeps == 1)
    }

    @Test("Mitteilung weckt, Person bleibt weg: Abwesenheit beginnt von vorn, ohne Aufhellen dazwischen")
    func notificationWakeRestartsAbsence() async throws {
        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .presence(true), .presence(false))
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .off })
        controller.screensDidSleep()
        #expect(displaySleep.sleeps == 1)
        controller.setDebugMonitoring(true)

        // Eine Mitteilung weckt die Displays. Seit dem Weggehen keine Eingabe, der Sensor
        // meldet weiter „abwesend“.
        controller.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        sleeper.wake()
        // Scheitern statt hängen: Ohne neue Abwesenheit startet auch kein neuer Timer.
        try #require(await eventually { controller.absenceStage == .dimmed })
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)
        #expect(manager.dimCauses == [.absence])
        #expect(gamma.levels[7] == SensorController.defaultAbsenceLevel)
        #expect(!controller.debugLog.contains { $0.job?.reason == .absenceEnd })
        #expect(controller.debugLog.contains { $0.kind == .absence(.dimmed) })
        #expect(input.isObserving)
        #expect(displaySleep.wakes == 0)

        // Nach der Zeit schlafen sie wieder.
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .off })
        #expect(displaySleep.sleeps == 2)

        // Kommt doch jemand, ist es wie immer vorbei.
        controller.screensDidSleep()
        source.send(.presence(true))
        #expect(await eventually { displaySleep.wakes == 1 })
        controller.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .none })
        #expect(manager.dimCauses.isEmpty)
    }

    @Test("Eingabe weckt die Displays, der Sensor meldet weiter „abwesend“: Helligkeit zurück, keine neue Abwesenheit")
    func inputWakeEndsAbsence() async {
        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .off })
        controller.screensDidSleep()

        // Die Maus weckt sie; danach rührt sich niemand, bis die Helligkeit zurückkommt.
        input.timeSinceLastInput = .milliseconds(100)
        controller.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        clock.advance(by: IdleDimmer.screenWakeSettle)
        input.timeSinceLastInput = IdleDimmer.screenWakeSettle + .milliseconds(100)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .none })
        #expect(manager.dimCauses.isEmpty)
        #expect(!input.isObserving)
        #expect(displaySleep.sleeps == 1)
    }

    @Test("„Bei Abwesenheit reagieren“ aus: laufende Abwesenheit endet, nichts dunkelt ab oder weckt")
    func absenceReactionCanBeDisabled() async {
        let controller = makeController()
        #expect(controller.reactsToAbsence)
        var arrivals = 0
        controller.onArrival = { arrivals += 1 }
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
        #expect(controller.activePresenceOrigin == .deskSensor)

        controller.setReactsToAbsence(false)
        #expect(controller.absenceStage == .none)
        #expect(manager.dimCauses.isEmpty)
        #expect(!input.isObserving)
        #expect(controller.activePresenceOrigin == nil)
        #expect(preferences.object(forKey: SensorController.Keys.reactsToAbsence) as? Bool == false)

        // Annäherung weckt schlafende Displays nicht und zählt nicht als Rückkehr.
        controller.screensDidSleep()
        source.send(.presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(displaySleep.wakes == 0)
        #expect(arrivals == 0)

        // Weggehen dunkelt nicht ab; angezeigt wird es trotzdem.
        controller.screensDidWake()
        source.send(.presence(false), .lux(500))
        #expect(await eventually { controller.lux == 500 })
        #expect(controller.presence == false)
        #expect(controller.absenceStage == .none)
        #expect(manager.dimCauses.isEmpty)
        #expect(displaySleep.sleeps == 0)

        // Wieder an: Die nächste Meldung „abwesend“ gilt.
        controller.setReactsToAbsence(true)
        source.send(.presence(true), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
    }

    @Test("Lux außerhalb 0…200 000 lx wird verworfen; die Grenzen selbst gelten")
    func luxOutOfRangeIsDropped() async {
        #expect(SensorController.luxRange == 0...200_000)
        let controller = makeController()
        controller.start()
        controller.setDebugMonitoring(true)
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { brightness == 20 })
        let entries = controller.debugLog.count

        source.send(.lux(-1), .lux(200_001), .lux(1e9), .lux(.infinity), .lux(.nan), .presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(controller.lux == 10)
        #expect(brightness == 20)
        // Nur die Anwesenheit steht im Protokoll, kein verworfener Wert.
        #expect(controller.debugLog.count == entries + 1)

        source.send(.lux(200_000))
        #expect(await eventually { controller.lux == 200_000 })
        #expect(brightness == 100)
        source.send(.lux(0))
        #expect(await eventually { controller.lux == 0 })
        #expect(brightness == 20)
    }

    @Test("Annäherung weckt schlafende Displays immer, auch ohne Abwesenheit; nicht die erste Meldung nach dem Verbinden")
    func arrivalAlwaysWakes() async {
        let controller = makeController()
        var arrivals = 0
        controller.onArrival = { arrivals += 1 }
        controller.start()
        // Displays schlafen schon, der Sensor meldet beim Verbinden jemanden: kein Wecken.
        controller.screensDidSleep()
        source.send(.connection(.connected), .presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(displaySleep.wakes == 0)
        #expect(arrivals == 0)

        // Gerade getippt: Die Abwesenheit beginnt nicht. Später zurück: trotzdem wecken.
        input.timeSinceLastInput = .seconds(1)
        source.send(.presence(false))
        #expect(await eventually { controller.presence == false })
        #expect(controller.absenceStage == .none)
        source.send(.presence(true))
        #expect(await eventually { displaySleep.wakes == 1 })
        #expect(controller.absenceStage == .none)
        #expect(arrivals == 1)

        // Wach: nichts zu wecken.
        controller.screensDidWake()
        source.send(.presence(false), .presence(true))
        #expect(await eventually { arrivals == 2 })
        #expect(displaySleep.wakes == 1)
    }

    @Test("macOS schaltet aus: nichts mehr dimmen oder warten, die Rückkehr weckt")
    func macOSSleepsDisplays() async {
        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)
        #expect(controller.absenceStage == .dimmed)

        // Während des Abdunkelns (Zeit aus den Systemeinstellungen kürzer).
        controller.screensDidSleep()
        #expect(controller.absenceStage == .off)
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(displaySleep.sleeps == 0)
        source.send(.presence(true))
        #expect(await eventually { displaySleep.wakes == 1 })

        // Schon vor der Abwesenheit aus: kein Deckel, nur wecken.
        controller.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .none })
        controller.screensDidSleep()
        source.send(.presence(false))
        #expect(await eventually { controller.absenceStage == .off })
        #expect(manager.dimCauses.isEmpty)
        #expect(displaySleep.sleeps == 0)
        source.send(.presence(true))
        #expect(await eventually { displaySleep.wakes == 2 })
    }

    @Test("Verbindung weg: Normalzustand, nichts mehr ausschalten")
    func disconnectRestores() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })

        source.send(.connection(.searching))
        #expect(await eventually { controller.status == .searching })
        #expect(controller.absenceStage == .none)
        #expect(manager.dimCauses.isEmpty)
        #expect(controller.presence == nil)
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(displaySleep.sleeps == 0)
    }

    @Test("Einstellungen der Abwesenheit bleiben erhalten; Helligkeit auf 0…50 begrenzt; Reaktion standardmäßig an")
    func absenceSettingsPersist() {
        let controller = makeController()
        #expect(controller.absenceLevel == SensorController.defaultAbsenceLevel)
        #expect(controller.absenceOffDelay == SensorController.defaultAbsenceOffDelay)
        controller.setAbsenceLevel(80)
        #expect(controller.absenceLevel == 50)
        controller.setAbsenceOffDelay(nil)
        #expect(makeController().absenceOffDelay == nil)
        controller.setAbsenceOffDelay(.seconds(600))
        #expect(controller.reactsToAbsence)
        controller.setReactsToAbsence(false)
        let reloaded = makeController()
        #expect(reloaded.absenceOffDelay == .seconds(600))
        #expect(reloaded.absenceOffSeconds == 600)
        #expect(reloaded.absenceLevel == 50)
        #expect(!reloaded.reactsToAbsence)
    }

    @Test("401 auf dem Strom: Kopplung nötig")
    func pairingLost() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .connection(.pairingRequired))
        #expect(await eventually { controller.status == .pairingRequired })
    }

    @Test("Licht regelt die Helligkeit mit Hysterese")
    func ambientLight() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { brightness == 100 })
        source.send(.lux(900)) // 98 %: unter der Hysterese
        #expect(await eventually { controller.lux == 900 })
        #expect(brightness == 100)
        source.send(.lux(10))
        #expect(await eventually { brightness == 20 })

        controller.setLightSource(.off)
        source.send(.lux(1000))
        #expect(await eventually { controller.lux == 1000 })
        #expect(brightness == 20)
    }

    @Test("Ignorierter Monitor folgt keinem Licht; mit ihm schlafen die Displays nicht, die übrigen werden schwarz")
    func ignoredMonitor() async {
        manager.setBrightnessMethod(.ignored, for: 7)
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.lux == 10 })
        #expect(brightness == 100)
        #expect(controller.lightLevels.isEmpty)

        var started = sleeper.started.makeAsyncIterator()
        source.send(.presence(true), .presence(false))
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)
        sleeper.wake()
        #expect(await eventually { manager.screensBlanked })
        #expect(controller.absenceStage == .off)
        #expect(displaySleep.sleeps == 0)
        #expect(blanker.blanked.isEmpty)

        // Wieder Gamma: Schwarzschalten und Licht gelten wieder.
        manager.setBrightnessMethod(.gamma, for: 7)
        #expect(blanker.blanked == [7])
        source.send(.presence(true), .lux(1000))
        #expect(await eventually { brightness == 100 && controller.lux == 1000 && !manager.screensBlanked })
        source.send(.lux(10))
        #expect(await eventually { brightness == 20 })
    }

    @Test("Jeder Monitor folgt seinem eigenen Profil; eins ohne Licht bleibt stehen")
    func perMonitorProfiles() async {
        let laptop = makeLaptopManager(builtInControl: StubControl())
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        func builtIn() -> Double? { laptop.monitors.first { $0.isBuiltIn }?.brightness }
        let macBook = laptop.monitors.first { $0.isBuiltIn }!
        let monitor7 = laptop.monitors.first { $0.id == 7 }!
        let controller = makeController(manager: laptop)
        controller.setLightProfile(
            LightProfile(followsLight: true, curve: LightCurve(points: [.init(lux: 100, percent: 10), .init(lux: 500, percent: 70)])),
            for: monitor7
        )
        // Eingebautes Display: Standard ist „folgt nicht“; ausdrücklich aus bleibt aus.
        #expect(!controller.lightProfile(for: macBook).followsLight)
        controller.setLightProfile(LightProfile(followsLight: false, curve: .standard), for: macBook)
        controller.start()
        let before = builtIn()

        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { external(laptop) == 70 })
        #expect(builtIn() == before)
        #expect(controller.lightLevels == Self.monitor7(70))

        // Profile überdauern einen Neustart des Controllers.
        let reloaded = makeController(manager: laptop)
        #expect(reloaded.lightProfile(for: monitor7).curve.points.map(\.percent) == [10, 70])
        #expect(!reloaded.lightProfile(for: macBook).followsLight)
    }

    @Test("Geändertes Profil gilt sofort mit dem aktuellen Licht, auch innerhalb der Hysterese")
    func profileChangeAppliesImmediately() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .lux(100))
        #expect(await eventually { brightness == 60 })

        let monitor = manager.monitors[0]
        var profile = controller.lightProfile(for: monitor)
        profile.curve.insert(.init(lux: 100, percent: 62))
        controller.setLightProfile(profile, for: monitor)
        #expect(brightness == 62)

        // Zurück auf Standard: Der gespeicherte Eintrag verschwindet.
        controller.setLightProfile(.standard, for: monitor)
        #expect(brightness == 60)
        #expect(preferences.object(forKey: "lightProfile.1-2-3") == nil)
    }

    @Test("Alter Schalter „Helligkeit anpassen: aus“ wird zu Lichtquelle „aus“")
    func migratesAdjustsBrightness() {
        preferences.set(false, forKey: SensorController.Keys.adjustsBrightness)
        #expect(makeController().lightSource == .off)
        preferences.set(true, forKey: SensorController.Keys.adjustsBrightness)
        #expect(makeController().lightSource == .deskSensorOnly)
    }

    @Test("Gespeicherte Wahl mit eingebautem Lichtsensor wird „Schreibtisch-Sensor“ und umgeschrieben", arguments: [
        ("deskSensor", SensorController.LightSource.deskSensorOnly),
        ("builtIn", .deskSensorOnly),
        ("deskSensorFirst", .deskSensorOnly),
        ("builtInFirst", .deskSensorOnly),
        ("builtInOnly", .deskSensorOnly),
        ("deskSensorOnly", .deskSensorOnly),
        ("off", .off),
    ])
    func migratesStoredLightSource(stored: String, expected: SensorController.LightSource) {
        preferences.set(stored, forKey: SensorController.Keys.lightSource)
        let controller = makeController(paired: false)
        #expect(controller.lightSource == expected)
        #expect(preferences.string(forKey: SensorController.Keys.lightSource) == expected.rawValue)
    }

    @Test("Altwert vom MacBook („builtInOnly“): Licht kommt vom Schreibtisch-Sensor, getrennt von keinem")
    func migratedChoiceUsesDeskSensor() async {
        preferences.set("builtInOnly", forKey: SensorController.Keys.lightSource)
        let controller = makeController()
        controller.start()
        #expect(controller.activeLightOrigin == nil)
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { brightness == 20 })
        #expect(controller.activeLightOrigin == .deskSensor)
        #expect(controller.isDeskSensorLightAvailable)

        source.send(.connection(.searching))
        #expect(await eventually { controller.activeLightOrigin == nil })
        #expect(!controller.isDeskSensorLightAvailable)
    }

    @Test("Ein Schreiber: eingebautes Display standardmäßig nicht; mit Profil nur ohne macOS-Auto-Helligkeit")
    func builtInDisplayHasOneWriter() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let macBook = laptop.monitors.first { $0.isBuiltIn }!
        let controller = makeController(manager: laptop)
        controller.start()

        // Standard: Nur der externe Monitor folgt.
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { external(laptop) == 20 })
        #expect(control.writes.isEmpty)

        // Mit Profil und ohne Auto-Helligkeit regelt ScreenDim auch das eingebaute Display.
        autoBrightness.value = false
        controller.setLightProfile(LightProfile(followsLight: true, curve: .standard), for: macBook)
        #expect(await eventually { control.writes.last == 20 })
        let writes = control.writes.count

        // macOS regelt selbst: kein zweiter Schreiber, auch wenn das Licht sich ändert.
        autoBrightness.value = true
        controller.refreshAutoBrightness() // wie beim Aktivieren der App
        source.send(.lux(1000))
        #expect(await eventually { external(laptop) == 100 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(control.writes.count == writes)
    }

    @Test("Licht während der DDC-Prüfung: Der Monitor holt den Wert danach nach, ohne neue Lichtänderung")
    func lightAppliedAfterProbe() async throws {
        let gate = GatedControl()
        let laptop = DisplayManager(
            store: BrightnessStore(storage: preferences),
            timing: .immediate,
            probeRetryDelay: .zero,
            fadeDuration: .zero,
            systemFadeDuration: .zero,
            gamma: StubDimmer(),
            overlay: StubDimmer(),
            blanker: blanker,
            discover: { _ in
                [
                    DiscoveredDisplay(
                        id: 1, identity: DisplayIdentity(vendor: 1552, model: 1, serial: 1), name: "MacBook", kind: .builtIn
                    ),
                    DiscoveredDisplay(
                        id: 7, identity: DisplayIdentity(vendor: 1, model: 2, serial: 3), name: "Monitor 7",
                        kind: .external(avServiceID: 42)
                    ),
                ]
            },
            makeExternalControl: { _, _, _ in gate },
            makeBuiltInControl: { _ in StubControl() }
        )
        laptop.refresh(force: true)
        func external() -> DisplayManager.Monitor? { laptop.monitors.first { $0.id == 7 } }
        let key = try #require(external()?.storageKey)
        BrightnessStore(storage: preferences).setBrightness(89, for: key, mode: .software)
        #expect(external()?.state == .probing)

        let controller = makeController(manager: laptop)
        controller.start()
        source.send(.connection(.connected), .lux(3))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor && controller.lux == 3 })

        controller.setDebugMonitoring(true)

        // Die Prüfung scheitert wie bei einem Monitor hinter dem Dock: Software-Dimmung
        // (vom ungedimmten Stand zum gespeicherten Wert), danach sofort der ausstehende
        // Lichtwert, ohne neues Lux.
        gate.release(with: .failure(.timeout))
        #expect(await eventually { external()?.usesSoftwareDimming == true })
        #expect(await eventually { external()?.brightness == 20 })
        let reasons = controller.debugLog.compactMap { $0.job?.reason }
        #expect(reasons == [.softwareFallback, .pendingAfterProbe])
    }

    @Test("Diagnose: Rollen und Wirkung im Protokoll")
    func debugLogShowsSourcesAndEffects() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let controller = makeController(manager: laptop)
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        controller.setDebugMonitoring(true)

        source.send(.connection(.connected), .lux(10), .presence(true), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
        #expect(controller.activePresenceOrigin == .deskSensor)
        #expect(controller.activeLightOrigin == .deskSensor)
        #expect(controller.lightLevels == Self.monitor7(20))
        #expect(controller.lightBrightnessOrigin == .deskSensor)

        #expect(controller.debugLog.contains {
            $0.origin == .deskSensor && $0.event == .lux(10) && $0.effect == .brightness(Self.monitor7(20))
        })
        // Je Auftrag ein Eintrag mit Grund, Start und Ziel.
        #expect(controller.debugLog.contains {
            $0.job?.reason == .lux(raw: 10, filtered: 10, origin: .deskSensor) && $0.job?.target == 20 && $0.job?.remembered == 100
        })
        #expect(controller.debugLog.contains { $0.origin == .deskSensor && $0.effect == .absence(.dimmed) })
        #expect(controller.debugLog.contains { $0.job?.reason == .absenceDim })
        #expect(controller.debugLog.contains { $0.kind == .lightSourceSwitch(from: nil, to: .deskSensor) })
        // Zeit um: eigener Eintrag, kein Ereignis.
        #expect(await started.next() == SensorController.defaultAbsenceOffDelay)
        sleeper.wake()
        #expect(await eventually { controller.debugLog.contains { $0.kind == .absence(.off) } })

        // Ohne offene Diagnose wird nichts protokolliert.
        controller.setDebugMonitoring(false)
        controller.screensDidSleep()
        source.send(.presence(true))
        #expect(await eventually { displaySleep.wakes == 1 })
        controller.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        sleeper.wake()
        #expect(await eventually { controller.absenceStage == .none })
        #expect(controller.debugLog.isEmpty)
    }

    // MARK: Lichtquelle

    private func external(_ manager: DisplayManager) -> Double? {
        manager.monitors.first { $0.id == 7 }?.brightness
    }

    @Test("Licht wieder an: Der letzte Wert blendet vom aktuellen Stand über")
    func reenablingLightFades() async {
        let sleeper = ManualSleeper()
        let laptop = makeLaptopManager(builtInControl: StubControl(), fade: .seconds(2), sleeper: sleeper)
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let controller = makeController(manager: laptop)
        controller.setLightSource(.off)
        controller.start()
        controller.setDebugMonitoring(true)
        // 700 lx sind 94 %: außerhalb der Hysterese von 3 Punkten.
        source.send(.connection(.connected), .lux(700))
        #expect(await eventually { controller.lux == 700 && controller.isDeskSensorLightAvailable })
        #expect(controller.activeLightOrigin == nil)
        #expect(external(laptop) == 100)

        var started = sleeper.started.makeAsyncIterator()
        controller.setLightSource(.deskSensorOnly)
        #expect(controller.activeLightOrigin == .deskSensor)
        // Überblendung vom aktuellen Wert, nicht Sprung: erster Schritt 99 (100 → 94 in 6).
        let job = controller.debugLog.compactMap(\.job).last
        #expect(job?.reason == .sourceSwitch(from: nil, to: .deskSensor))
        #expect(job?.remembered == 100)
        #expect(job?.target == 94)
        #expect(job?.duration == .seconds(2))
        _ = await started.next()
        sleeper.wake()
        #expect(await eventually { external(laptop) == 99 })
        #expect(controller.debugLog.contains {
            $0.kind == .lightSourceSwitch(from: nil, to: .deskSensor) && $0.effect == .brightness(Self.monitor7(94))
        })
    }

    @Test("Licht wieder an: innerhalb der Hysterese bleibt die Helligkeit stehen")
    func reenablingLightKeepsHysteresis() async {
        let controller = makeController()
        controller.setLightSource(.off)
        controller.start()
        controller.setDebugMonitoring(true)
        source.send(.connection(.connected), .lux(900)) // 98 %
        #expect(await eventually { controller.lux == 900 })
        controller.setLightSource(.deskSensorOnly)
        #expect(controller.activeLightOrigin == .deskSensor)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(brightness == 100)
        #expect(controller.debugLog.allSatisfy { $0.job == nil })
    }

    @Test("Abgelaufene Quelle: 45 s ohne jedes Ereignis gilt der Schreibtisch-Sensor als weg")
    func staleDeskSensor() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor })
        let luxAt = clock.instant
        // Der einzige Termin ist der Ablauf knapp nach 45 s.
        #expect(controller.lightExpiryDeadline == luxAt + .seconds(45) + .milliseconds(10))

        clock.advance(by: .seconds(45))
        controller.updateActiveLight()
        #expect(controller.isDeskSensorLightAvailable) // genau 45 s: noch gültig

        clock.advance(by: .seconds(1))
        controller.updateActiveLight()
        #expect(!controller.isDeskSensorLightAvailable)
        #expect(controller.activeLightOrigin == nil)
        #expect(controller.lightExpiryDeadline == nil)
    }

    @Test("ESP32 mit Lux nur bei Änderung und Lebenszeichen alle 30 s bleibt aktiv")
    func deskSensorHeartbeatKeepsSource() async {
        let controller = makeController()
        controller.start()
        controller.setDebugMonitoring(true)
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor && brightness == 20 })

        // Zwei Minuten gleiches Licht: nur Lebenszeichen.
        for _ in 1...4 {
            clock.advance(by: .seconds(30))
            let entries = controller.debugLog.count
            source.send(.heartbeat)
            #expect(await eventually { controller.debugLog.count == entries + 1 })
            controller.updateActiveLight() // wie der Ablauf-Task
            #expect(controller.activeLightOrigin == .deskSensor)
            #expect(controller.isDeskSensorLightAvailable)
        }
        #expect(!controller.debugLog.contains { if case .lightSourceSwitch(.deskSensor?, _) = $0.kind { true } else { false } })
    }

    @Test("Auto-Helligkeit wird gemerkt: höchstens alle 10 s neu gelesen, sofort beim Aktivieren")
    func autoBrightnessIsCached() async {
        let laptop = makeLaptopManager(builtInControl: StubControl())
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let macBook = laptop.monitors.first { $0.isBuiltIn }!
        autoBrightness.value = false
        let controller = makeController(manager: laptop)
        controller.setLightProfile(LightProfile(followsLight: true, curve: .standard), for: macBook)
        controller.start()
        #expect(autoBrightness.reads == 1)
        #expect(controller.isMacOSAutoBrightnessEnabled == false)

        source.send(.connection(.connected), .lux(10), .lux(1000), .lux(10), .lux(1000))
        #expect(await eventually { controller.lux == 1000 && external(laptop) == 100 })
        #expect(autoBrightness.reads == 1)

        clock.advance(by: .seconds(11))
        source.send(.lux(10))
        #expect(await eventually { external(laptop) == 20 })
        #expect(autoBrightness.reads == 2)

        // Einstellungen geöffnet bzw. App aktiv: sofort neu, beobachtbar.
        autoBrightness.value = true
        controller.refreshAutoBrightness()
        #expect(autoBrightness.reads == 3)
        #expect(controller.isMacOSAutoBrightnessEnabled == true)
    }

    // MARK: Pausen

    @Test("Fremde Änderung am eingebauten Display: Wert übernehmen, 60 s Pause")
    func externalChangePausesBuiltIn() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let macBook = laptop.monitors.first { $0.isBuiltIn }!
        func builtIn() -> Double? { laptop.monitors.first { $0.isBuiltIn }?.brightness }
        autoBrightness.value = false
        let controller = makeController(manager: laptop)
        controller.setLightProfile(LightProfile(followsLight: true, curve: .standard), for: macBook)
        controller.start()
        controller.setDebugMonitoring(true)
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { builtIn() == 20 })
        #expect(await eventually { control.writes.last == 20 })
        try? await Task.sleep(for: .milliseconds(100)) // Drossel wieder frei, wie nach 1 s

        // Helligkeitstasten: Das Display steht jetzt auf 70.
        control.setRead(.success(VCPReading(current: 70, maximum: 100)))
        let writes = control.writes.count
        source.send(.lux(1000))
        #expect(await eventually { builtIn() == 70 })
        #expect(controller.debugLog.contains { $0.job?.reason == .externalChange && $0.job?.target == 70 })
        #expect(control.writes.count == writes)

        // Während der Pause regelt das Licht das Display nicht.
        clock.advance(by: .seconds(59))
        source.send(.lux(10))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(builtIn() == 70)

        clock.advance(by: .seconds(2))
        control.setRead(.success(VCPReading(current: 70, maximum: 100)))
        source.send(.lux(1000))
        #expect(await eventually { builtIn() == 100 })
    }

    @Test("Wert von Hand hält: Pause bis 5 min oder Licht ändert sich um mehr als Faktor 2")
    func manualValueHolds() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { brightness == 100 })

        manager.setBrightness(50, for: 7)
        source.send(.lux(600)) // 91 %, Faktor < 2
        #expect(await eventually { controller.lux == 600 })
        #expect(brightness == 50)

        // Ablauf nach 5 min.
        clock.advance(by: .seconds(301))
        source.send(.lux(700))
        #expect(await eventually { brightness == 94 })

        // Licht ändert sich stark: Die Pause endet sofort.
        manager.setBrightness(50, for: 7)
        source.send(.lux(10))
        #expect(await eventually { brightness == 20 })
    }

    @Test("Wert von Hand, dann weg und zurück: unter dem Deckel bleibt er, zurück gilt das Lichtprofil")
    func arrivalRestoresLightProfile() async {
        let controller = makeController()
        controller.start()
        controller.setDebugMonitoring(true)
        source.send(.connection(.connected), .presence(true), .lux(1000))
        #expect(await eventually { brightness == 100 })
        manager.setBrightness(50, for: 7)

        source.send(.presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
        #expect(brightness == 50)
        #expect(gamma.levels[7] == SensorController.defaultAbsenceLevel)

        source.send(.presence(true))
        #expect(await eventually { controller.absenceStage == .none })
        #expect(brightness == 100)
        #expect(gamma.levels[7] == 100)
        #expect(manager.dimCauses.isEmpty)
        #expect(controller.debugLog.contains { $0.job?.reason == .presenceChange && $0.job?.target == 100 })
    }

    @Test("Weggehen ohne Abwesenheit (gerade getippt): Lichtprofil sofort, genau, ohne Hysterese")
    func leavingRestoresLightProfile() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .presence(true), .lux(1000))
        #expect(await eventually { brightness == 100 })
        manager.setBrightness(98, for: 7)

        input.timeSinceLastInput = .seconds(1)
        source.send(.presence(false))
        #expect(await eventually { brightness == 100 })
        #expect(controller.absenceStage == .none)
        #expect(gamma.levels[7] == 100)
    }

    @Test("Wert von Hand bei „abwesend“: übersteht die verspätete Meldung „anwesend“, nicht den nächsten Wechsel")
    func manualWhileAbsentSurvivesArrival() async {
        let controller = makeController()
        controller.start()
        input.timeSinceLastInput = .seconds(1)
        source.send(.connection(.connected), .presence(true), .lux(1000), .presence(false))
        #expect(await eventually { controller.presence == false && brightness == 100 })

        manager.setBrightness(40, for: 7)
        source.send(.presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(brightness == 40)

        source.send(.presence(false))
        #expect(await eventually { brightness == 100 })
    }

    @Test("Erste Meldung nach dem Verbinden oder „Bei Abwesenheit reagieren“ aus: Wert von Hand bleibt")
    func presenceKeepsManualValueWhenNotSwitching() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { brightness == 100 })
        manager.setBrightness(50, for: 7)
        source.send(.presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(brightness == 50)

        controller.setReactsToAbsence(false)
        source.send(.presence(false))
        #expect(await eventually { controller.presence == false })
        source.send(.presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(brightness == 50)
    }

    // MARK: Manueller Modus

    @Test("Manuell: Licht und Anwesenheit verstellen nichts, nichts dunkelt ab, schaltet aus oder weckt; bleibt gespeichert")
    func manualModeIgnoresLightAndPresence() async {
        let controller = makeController()
        var arrivals = 0
        controller.onArrival = { arrivals += 1 }
        controller.start()
        source.send(.connection(.connected), .presence(true), .lux(1000))
        #expect(await eventually { brightness == 100 })
        #expect(!controller.isManualMode)

        controller.setManualMode(true)
        #expect(preferences.object(forKey: SensorController.Keys.manualMode) as? Bool == true)
        #expect(controller.activePresenceOrigin == nil)
        manager.setBrightness(40, for: 7)

        // Auch nach Ablauf der Pause vom Regler: Licht und Weggehen ändern nichts.
        clock.advance(by: .seconds(600))
        source.send(.lux(10), .presence(false))
        #expect(await eventually { controller.presence == false })
        #expect(controller.lux == 10)
        #expect(brightness == 40)
        #expect(controller.absenceStage == .none)
        #expect(manager.dimCauses.isEmpty)

        controller.screensDidSleep()
        source.send(.presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(displaySleep.sleeps == 0)
        #expect(displaySleep.wakes == 0)
        #expect(arrivals == 0)
        #expect(brightness == 40)

        controller.stop()
        #expect(makeController().isManualMode)
    }

    @Test("Manuell während der Abwesenheit: Deckel weg, nichts geht aus; zurück auf automatisch gilt sofort das Lichtprofil")
    func manualModeEndsAbsenceAndAutomaticRestoresProfile() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .presence(true), .lux(1000))
        #expect(await eventually { brightness == 100 })
        manager.setBrightness(50, for: 7)
        source.send(.presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })

        controller.setManualMode(true)
        #expect(controller.absenceStage == .none)
        #expect(manager.dimCauses.isEmpty)
        #expect(gamma.levels[7] == 50)
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(displaySleep.sleeps == 0)

        // Automatisch: sofort das Lichtprofil, trotz Wert von Hand. Die Anwesenheit zählt ab
        // dem nächsten Wechsel.
        controller.setManualMode(false)
        #expect(await eventually { brightness == 100 })
        #expect(gamma.levels[7] == 100)
        #expect(controller.absenceStage == .none)
        source.send(.presence(true), .presence(false))
        #expect(await eventually { controller.absenceStage == .dimmed })
    }

    @Test("Wechsel, während macOS die Displays schlafen lässt: Lichtprofil erst nach dem Aufwachen")
    func sleepingDisplaysDeferLightProfile() async {
        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .presence(true), .lux(1000))
        #expect(await eventually { brightness == 100 })
        manager.setBrightness(50, for: 7)

        controller.screensDidSleep()
        input.timeSinceLastInput = .seconds(1)
        source.send(.presence(false), .presence(true))
        #expect(await eventually { displaySleep.wakes == 1 })
        #expect(brightness == 50)

        controller.screensDidWake()
        #expect(await started.next() == IdleDimmer.screenWakeSettle)
        #expect(brightness == 50)
        sleeper.wake()
        #expect(await eventually { brightness == 100 })
    }

    @Test("Demo ersetzt den Schreibtisch-Sensor als Lichtquelle, außer bei „aus“")
    func demoOverridesLightSources() async {
        let controller = makeController(demo: true)
        controller.start()
        #expect(controller.activeLightOrigin == .demo)
        controller.setDemoLux(10)
        #expect(await eventually { controller.lightBrightnessOrigin == .demo })

        controller.setLightSource(.off)
        #expect(controller.activeLightOrigin == nil)
        controller.stop()
    }

    @Test("Kopplung im offenen Fenster: Code abholen, prüfen, speichern")
    func pairsAutomatically() async {
        let controller = makeController(paired: false)
        controller.setEnabled(true)
        #expect(controller.status == .notPaired)
        http.enqueue(.ok(Data(#"{"id":"text_sensor-pairing_code","value":"K7M2-P9QR","state":"K7M2-P9QR"}"#.utf8)),
                     for: SensorProtocol.pairingPath)
        http.enqueue(.ok(Data()), for: SensorProtocol.presencePath)

        controller.beginPairing(with: Self.sensor)
        #expect(await eventually { controller.pairedHostname == Self.host })
        #expect(controller.pairing == .idle)
        #expect(credentials.stored[Self.host]?.raw == "K7M2P9QR")
        #expect(preferences.string(forKey: SensorController.Keys.hostname) == Self.host)
        #expect(controller.status == .searching)
        #expect(http.requests.map(\.path) == [SensorProtocol.pairingPath, SensorProtocol.presencePath])
        #expect(http.requests.map(\.password) == [nil, "K7M2P9QR"])
    }

    @Test("Fenster zu (401): BOOT-Hinweis; falscher Code von Hand wird abgelehnt")
    func manualCode() async {
        let controller = makeController(paired: false)
        controller.setEnabled(true)
        http.enqueue(.unauthorized, for: SensorProtocol.pairingPath)
        controller.beginPairing(with: Self.sensor)
        #expect(await eventually { controller.pairing == .waitingForButton(Self.sensor) })
        #expect(controller.pairing.acceptsManualCode)

        #expect(!controller.submitCode("ABC"))
        http.enqueue(.unauthorized, for: SensorProtocol.pairingPath)
        http.enqueue(.unauthorized, for: SensorProtocol.presencePath)
        #expect(controller.submitCode("abcd efgh"))
        #expect(await eventually { controller.pairing == .failed(Self.sensor, .wrongCode) })
        #expect(controller.pairedHostname == nil)
        #expect(credentials.stored[Self.host] == nil)
        controller.cancelPairing()
    }

    @Test("Code von Hand: Ist der angezeigte Code nicht zu holen, wird nichts gespeichert")
    func manualCodeNeedsShownCode() async {
        let controller = makeController(paired: false)
        controller.setEnabled(true)
        http.enqueue(.unauthorized, for: SensorProtocol.pairingPath)
        controller.beginPairing(with: Self.sensor)
        #expect(await eventually { controller.pairing == .waitingForButton(Self.sensor) })

        // Fenster inzwischen offen (jedes Passwort ginge durch), aber der Code-Abruf scheitert.
        http.enqueue(.timeout, for: SensorProtocol.pairingPath)
        http.enqueue(.ok(Data()), for: SensorProtocol.presencePath)
        #expect(controller.submitCode("abcd efgh"))
        #expect(await eventually { controller.pairing == .failed(Self.sensor, .timeout) })
        #expect(controller.pairedHostname == nil)
        #expect(credentials.stored[Self.host] == nil)
        #expect(!http.requests.contains { $0.path == SensorProtocol.presencePath })
        controller.cancelPairing()
    }

    @Test("Schlüsselbund nicht lesbar: kein „neu koppeln“, Code und Hostname bleiben")
    func keychainUnavailable() {
        let controller = makeController()
        credentials.readFailure.withLock { $0 = errSecInteractionNotAllowed }
        controller.start()
        #expect(controller.status == .keychainUnavailable(errSecInteractionNotAllowed))
        #expect(controller.pairedHostname == Self.host)
        #expect(credentials.stored[Self.host] == Self.code)
        controller.stop()
    }

    @Test("Entkoppeln löscht Code und Hostnamen")
    func unpair() {
        let controller = makeController()
        controller.start()
        #expect(controller.status == .searching)
        controller.unpair()
        #expect(credentials.stored[Self.host] == nil)
        #expect(preferences.string(forKey: SensorController.Keys.hostname) == nil)
        #expect(controller.pairedHostname == nil)
        #expect(controller.status == .notPaired)
    }

    private static let maxDistanceSet = "number/Max Distance/set"
    private static let maxDistanceDetail = SensorNumber(value: 120, range: 30...800, step: 10)

    @Test("Max Distance und Entfernung vom Sensor; Bereich bleibt bei reinen Zustandsmeldungen; Trennen löscht beides")
    func sensorSettingsFromStream() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .maxDistance(Self.maxDistanceDetail), .distance(85))
        #expect(await eventually { controller.distance == 85 })
        #expect(controller.maxDistance == Self.maxDistanceDetail)

        source.send(.maxDistance(SensorNumber(value: 150)), .distance(nil))
        #expect(await eventually { controller.distance == nil })
        #expect(controller.maxDistance == SensorNumber(value: 150, range: 30...800, step: 10))
        // Die Entfernung kommt alle 2 s; sie zählt als Lebenszeichen, nicht im Protokoll.
        controller.setDebugMonitoring(true)
        source.send(.distance(60), .presence(true))
        #expect(await eventually { controller.presence == true })
        #expect(controller.debugLog.map(\.kind) == [.event(.deskSensor, .presence(true))])

        source.send(.connection(.searching))
        #expect(await eventually { controller.maxDistance == nil })
        #expect(controller.distance == nil)
        controller.stop()
    }

    @Test("Max Distance setzen: entprellt, auf den Schritt gerundet, ein POST mit Code; der Sensor meldet zurück")
    func setMaxDistance() async {
        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .maxDistance(Self.maxDistanceDetail))
        #expect(await eventually { controller.maxDistance != nil })
        http.enqueuePost(.ok(Data()), for: Self.maxDistanceSet)

        // Gleicher Wert: nichts zu tun.
        controller.setMaxDistance(120)
        #expect(controller.maxDistanceWrite == .idle)

        controller.setMaxDistance(130)
        controller.setMaxDistance(144)
        #expect(controller.maxDistanceWrite == .saving)
        #expect(await started.next() == SensorController.settingWriteDelay)
        #expect(await started.next() == SensorController.settingWriteDelay)
        #expect(http.posts.isEmpty)
        sleeper.wake()
        #expect(await eventually { controller.maxDistanceWrite == .idle })
        #expect(http.posts == [StubSensorHTTP.Post(path: Self.maxDistanceSet, query: "value=140", password: Self.code.raw)])
        // Den neuen Wert bestätigt der Sensor im Strom.
        #expect(controller.maxDistance?.value == 120)
        source.send(.maxDistance(SensorNumber(value: 140)))
        #expect(await eventually { controller.maxDistance?.value == 140 })
        controller.stop()
    }

    @Test("Max Distance: Bereich begrenzt; abgelehnt, unbekannt oder unerreichbar heißt „nicht gespeichert“", arguments: [
        (SensorResponse.unauthorized, SensorController.SettingWriteFailure.unauthorized),
        (.status(404), .unsupported),
        (.status(500), .unreachable),
        (.timeout, .unreachable),
    ])
    func setMaxDistanceFails(_ response: SensorResponse, _ failure: SensorController.SettingWriteFailure) async {
        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        source.send(.connection(.connected), .maxDistance(Self.maxDistanceDetail))
        #expect(await eventually { controller.maxDistance != nil })
        http.enqueuePost(response, for: Self.maxDistanceSet)

        controller.setMaxDistance(5000)
        _ = await started.next()
        sleeper.wake()
        #expect(await eventually { controller.maxDistanceWrite == .failed(failure) })
        #expect(http.posts.map(\.query) == ["value=800"])
        #expect(controller.maxDistance?.value == 120)
        // Zurück auf den Wert des Sensors: Der Fehler ist erledigt.
        controller.setMaxDistance(120)
        #expect(controller.maxDistanceWrite == .idle)
        controller.stop()
    }

    @Test("Max Distance: ohne Verbindung oder in der Demo nichts; Trennen verwirft einen wartenden Write")
    func setMaxDistanceNeedsSensor() async {
        let demo = makeController(demo: true)
        demo.start()
        #expect(await eventually { demo.presence != nil })
        demo.setMaxDistance(200)
        #expect(demo.maxDistance == nil)
        #expect(demo.maxDistanceWrite == .idle)
        demo.stop()

        let controller = makeController()
        var started = sleeper.started.makeAsyncIterator()
        controller.start()
        controller.setMaxDistance(200)
        #expect(controller.maxDistanceWrite == .idle)
        source.send(.connection(.connected), .maxDistance(Self.maxDistanceDetail))
        #expect(await eventually { controller.maxDistance != nil })
        controller.setMaxDistance(200)
        _ = await started.next()
        source.send(.connection(.searching))
        #expect(await eventually { controller.maxDistance == nil })
        #expect(controller.maxDistanceWrite == .idle)
        sleeper.wake()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(http.posts.isEmpty)
        controller.stop()
    }

    @Test("Runden auf den Schritt ab der Untergrenze, dann in den Bereich")
    func normalizeSetting() {
        #expect(SensorController.normalize(144, range: 30...800, step: 10) == 140)
        #expect(SensorController.normalize(35, range: 30...800, step: 10) == 40)
        #expect(SensorController.normalize(25, range: 30...800, step: 10) == 30)
        #expect(SensorController.normalize(805, range: 30...800, step: 10) == 800)
        #expect(SensorController.normalize(57, range: 25...800, step: 10) == 55)
    }

    @Test("Demo und echter Sensor schließen sich aus")
    func demoExcludesSensor() async {
        let controller = makeController(demo: true)
        controller.start()
        #expect(controller.isDemoActive)
        #expect(controller.status == .demo)
        // Die Live-Quelle läuft nicht: Ihre Ereignisse kommen nicht an.
        source.send(.connection(.pairingRequired))
        #expect(await eventually { controller.presence == true })
        #expect(controller.status == .demo)

        controller.setDemoActive(false)
        #expect(controller.status == .searching)
        controller.stop()
    }
}

/// Antwort der Fabrik für „Helligkeit automatisch anpassen“; `nil`: unbekannt.
@MainActor
final class AutoBrightnessFlag {
    var value: Bool?
    private(set) var reads = 0

    func read() -> Bool? {
        reads += 1
        return value
    }
}
