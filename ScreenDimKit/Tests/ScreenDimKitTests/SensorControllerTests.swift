import CoreGraphics
import Foundation
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
            gamma: StubDimmer(),
            overlay: StubDimmer(),
            blanker: blanker,
            discover: {
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
        manager: DisplayManager? = nil,
        builtInLight: (any SensorSource)? = nil
    ) -> SensorController {
        if paired {
            preferences.set(true, forKey: SensorController.Keys.enabled)
            preferences.set(Self.host, forKey: SensorController.Keys.hostname)
            try? credentials.save(Self.code, for: Self.host)
        }
        let source = source
        return SensorController(
            manager: manager ?? self.manager,
            preferences: preferences,
            credentials: credentials,
            http: http,
            input: input,
            demoAtLaunch: demo,
            makeLiveSource: { _, _ in source },
            makeSimulation: { SimulatedSensorSource(schedule: $0, seed: 1) },
            makeBuiltInLightSensor: { builtInLight },
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
            discover: {
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

    @Test("Weg schaltet aus, da wieder an")
    func blanksWhenAway() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .presence(true), .presence(false))
        #expect(await eventually { manager.screensBlanked })
        #expect(blanker.blanked == [7])
        #expect(controller.status == .connected)

        source.send(.presence(true))
        #expect(await eventually { !manager.screensBlanked })
        #expect(blanker.blanked.isEmpty)
    }

    @Test("Eingabe gewinnt: kurz vorher getippt bleibt an, Maus weckt sofort")
    func inputWins() async {
        let controller = makeController()
        controller.start()
        input.timeSinceLastInput = .seconds(1)
        source.send(.connection(.connected), .presence(false))
        #expect(await eventually { controller.presence == false })
        #expect(!manager.screensBlanked)

        input.timeSinceLastInput = .seconds(60)
        source.send(.presence(true), .presence(false))
        #expect(await eventually { manager.screensBlanked })
        input.fire()
        #expect(!manager.screensBlanked)
        // Weiter „weg“ ohne Wechsel schaltet nicht erneut aus.
        source.send(.presence(false), .heartbeat)
        #expect(await eventually { controller.presence == false })
        #expect(!manager.screensBlanked)
    }

    @Test("Verbindung weg: Normalzustand, nichts mehr ausschalten")
    func disconnectRestores() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .presence(false))
        #expect(await eventually { manager.screensBlanked })

        source.send(.connection(.searching))
        #expect(await eventually { controller.status == .searching })
        #expect(!manager.screensBlanked)
        #expect(controller.presence == nil)
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
        #expect(makeController().lightSource == .deskSensorFirst)
    }

    @Test("Gespeicherte Werte der alten Wahl werden übernommen", arguments: [
        ("deskSensor", SensorController.LightSource.deskSensorFirst),
        ("builtIn", .builtInFirst),
        ("off", .off),
        ("builtInOnly", .builtInOnly),
    ])
    func migratesStoredLightSource(stored: String, expected: SensorController.LightSource) {
        preferences.set(stored, forKey: SensorController.Keys.lightSource)
        let controller = makeController(builtInLight: StubSensorSource())
        #expect(controller.lightSource == expected)
        #expect(controller.effectiveLightSource == expected)
        // Gelesen, nicht umgeschrieben.
        #expect(preferences.string(forKey: SensorController.Keys.lightSource) == stored)
    }

    @Test("Ohne Fabrik (App Store, Mac mini): „eingebaut“ wirkt wie Schreibtisch-Sensor, Wahl bleibt gespeichert")
    func builtInLightUnavailable() async {
        let controller = makeController()
        #expect(!controller.hasBuiltInLightSensor)
        #expect(controller.availableLightSources == [.deskSensorOnly, .off])
        controller.setLightSource(.builtInFirst)
        controller.setLightSource(.builtInOnly)
        #expect(controller.lightSource == .deskSensorFirst)
        #expect(controller.effectiveLightSource == .deskSensorOnly)

        // Gespeicherte Wahl von einem MacBook, jetzt ohne Sensor.
        preferences.set("builtIn", forKey: SensorController.Keys.lightSource)
        let migrated = makeController()
        #expect(migrated.lightSource == .builtInFirst)
        #expect(migrated.effectiveLightSource == .deskSensorOnly)
        migrated.start()
        #expect(migrated.activeLightOrigin == nil)
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { brightness == 20 })
        #expect(migrated.activeLightOrigin == .deskSensor)
        #expect(!migrated.isLightFallback)
        #expect(preferences.string(forKey: SensorController.Keys.lightSource) == "builtIn")

        // Getrennt: kein Rückfall, keine Quelle.
        source.send(.connection(.searching))
        #expect(await eventually { migrated.activeLightOrigin == nil })
        #expect(!migrated.isBuiltInLightAvailable)
    }

    @Test("Ein Schreiber: eingebautes Display standardmäßig nicht; mit Profil nur ohne macOS-Auto-Helligkeit")
    func builtInDisplayHasOneWriter() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let macBook = laptop.monitors.first { $0.isBuiltIn }!
        let light = StubSensorSource()
        let controller = makeController(paired: false, manager: laptop, builtInLight: light)
        controller.start()
        controller.setLightSource(.builtInFirst)

        // Standard: Nur der externe Monitor folgt.
        light.send(.connection(.connected), .lux(10))
        #expect(await eventually { external(laptop) == 20 })
        #expect(controller.builtInLux == 10)
        #expect(control.writes.isEmpty)

        // Mit Profil und ohne Auto-Helligkeit regelt ScreenDim auch das eingebaute Display.
        autoBrightness.value = false
        controller.setLightProfile(LightProfile(followsLight: true, curve: .standard), for: macBook)
        #expect(await eventually { control.writes.last == 20 })
        let writes = control.writes.count

        // macOS regelt selbst: kein zweiter Schreiber, auch wenn das Licht sich ändert.
        autoBrightness.value = true
        controller.refreshAutoBrightness() // wie beim Aktivieren der App
        for _ in 1...3 { light.send(.lux(1000)) } // drei Werte: anhaltender Sprung
        #expect(await eventually { external(laptop) == 100 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(control.writes.count == writes)

        controller.setLightSource(.off)
        #expect(controller.builtInLux == nil)
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
            discover: {
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

        let light = StubSensorSource()
        let controller = makeController(paired: false, manager: laptop, builtInLight: light)
        controller.start()
        controller.setLightSource(.builtInOnly)
        light.send(.connection(.connected), .lux(3))
        #expect(await eventually { controller.activeLightOrigin == .builtIn })

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

    @Test("Deckel zu: Werte des eingebauten Lichtsensors zählen nicht")
    func builtInLightIgnoredWhenLidClosed() async {
        // Der Standard-Manager kennt nur den externen Monitor, wie bei zugeklapptem Deckel.
        let light = StubSensorSource()
        let controller = makeController(paired: false, builtInLight: light)
        controller.setLightSource(.builtInFirst)
        controller.start()
        #expect(controller.isBuiltInLightSensorCovered)
        #expect(brightness == 100)
        light.send(.connection(.connected), .lux(1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(brightness == 100)
        #expect(controller.builtInLux == nil)
        #expect(!controller.isBuiltInLightAvailable)
        #expect(controller.activeLightOrigin == nil)
    }

    @Test("Ist der eingebaute Sensor die Lichtquelle, zählt das Licht des Schreibtisch-Sensors nicht")
    func deskLuxIgnoredForBuiltInSource() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let controller = makeController(manager: laptop, builtInLight: StubSensorSource())
        controller.setLightSource(.builtInOnly)
        controller.start()
        let before = laptop.monitors.first { $0.id == 7 }?.brightness
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.lux == 10 })
        #expect(before == 100)
        #expect(laptop.monitors.first { $0.id == 7 }?.brightness == 100)
    }

    @Test("Diagnose: eingebauter Sensor liest mit, ohne zu regeln; Schließen stoppt ihn")
    func debugMonitorsBuiltInWithoutApplying() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let light = StubSensorSource()
        preferences.set(SensorController.LightSource.deskSensorOnly.rawValue, forKey: SensorController.Keys.lightSource)
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.start()
        #expect(controller.lightSource == .deskSensorOnly)

        controller.setDebugMonitoring(true)
        light.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.builtInLux == 10 })
        #expect(controller.builtInLastEventDate != nil)
        #expect(controller.activeLightOrigin == nil) // Schreibtisch-Sensor noch nicht verbunden
        #expect(laptop.monitors.first { $0.id == 7 }?.brightness == 100)
        let last = controller.debugLog.last
        #expect(last?.origin == .builtIn)
        #expect(last?.event == .lux(10))
        #expect(last?.effect == nil)

        controller.setDebugMonitoring(false)
        #expect(controller.builtInLux == nil)
        #expect(controller.debugLog.isEmpty)
    }

    @Test("Diagnose: beide Quellen, Rollen und Wirkung im Protokoll")
    func debugLogShowsSourcesAndEffects() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.setLightSource(.builtInOnly)
        controller.start()
        controller.setDebugMonitoring(true)

        source.send(.connection(.connected), .lux(1000), .presence(true), .presence(false))
        light.send(.connection(.connected), .lux(10))
        #expect(await eventually { laptop.screensBlanked && controller.builtInLux == 10 })
        #expect(controller.activePresenceOrigin == .deskSensor)
        #expect(controller.activeLightOrigin == .builtIn)
        #expect(controller.lightLevels == Self.monitor7(20))
        #expect(controller.lightBrightnessOrigin == .builtIn)

        #expect(controller.debugLog.contains { $0.origin == .builtIn && $0.effect == .brightness(Self.monitor7(20)) })
        // Je Auftrag ein Eintrag mit Grund, Start und Ziel.
        #expect(controller.debugLog.contains {
            $0.job?.reason == .lux(raw: 10, filtered: 10, origin: .builtIn) && $0.job?.target == 20 && $0.job?.remembered == 100
        })
        #expect(controller.debugLog.contains { $0.origin == .deskSensor && $0.effect == .screensOff })
        #expect(controller.debugLog.contains { $0.kind == .lightSourceSwitch(from: nil, to: .builtIn) })
        // Licht des Schreibtisch-Sensors steht im Protokoll, wirkt aber nicht.
        #expect(controller.debugLog.contains { $0.origin == .deskSensor && $0.event == .lux(1000) && $0.effect == nil })

        // Ohne offene Diagnose wird nichts protokolliert.
        controller.setDebugMonitoring(false)
        source.send(.presence(true))
        #expect(await eventually { !laptop.screensBlanked })
        #expect(controller.debugLog.isEmpty)
    }

    // MARK: Vorrang und Rückfall

    private func external(_ manager: DisplayManager) -> Double? {
        manager.monitors.first { $0.id == 7 }?.brightness
    }

    @Test("Schreibtisch-Sensor fällt aus: eingebauter springt ein und blendet vom aktuellen Wert über, Hysterese bleibt")
    func fallsBackToBuiltIn() async {
        let control = StubControl()
        let sleeper = ManualSleeper()
        let laptop = makeLaptopManager(builtInControl: control, fade: .seconds(2), sleeper: sleeper)
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        #expect(controller.lightSource == .deskSensorFirst)
        controller.start()
        controller.setDebugMonitoring(true)

        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor })
        // 100 % ist schon der Stand: kein Auftrag, keine Überblendung.
        #expect(external(laptop) == 100)
        #expect(controller.debugLog.allSatisfy { $0.job == nil })

        // 700 lx sind 94 %: außerhalb der Hysterese von 3 Punkten.
        light.send(.connection(.connected), .lux(700))
        #expect(await eventually { controller.isBuiltInLightAvailable })
        #expect(controller.activeLightOrigin == .deskSensor)
        #expect(external(laptop) == 100)

        var started = sleeper.started.makeAsyncIterator()
        source.send(.connection(.searching))
        #expect(await eventually { controller.activeLightOrigin == .builtIn })
        #expect(controller.isLightFallback)
        #expect(!controller.isDeskSensorLightAvailable)
        // Überblendung vom aktuellen Wert, nicht Sprung: erster Schritt 99 (100 → 94 in 6).
        let job = controller.debugLog.compactMap(\.job).last
        #expect(job?.reason == .sourceSwitch(from: .deskSensor, to: .builtIn))
        #expect(job?.remembered == 100)
        #expect(job?.target == 94)
        #expect(job?.duration == .seconds(2))
        _ = await started.next()
        sleeper.wake()
        #expect(await eventually { external(laptop) == 99 })
        #expect(controller.debugLog.contains {
            $0.kind == .lightSourceSwitch(from: .deskSensor, to: .builtIn) && $0.effect == .brightness(Self.monitor7(94))
        })
        #expect(control.writes.isEmpty) // eingebautes Display: Standard „folgt nicht“
    }

    @Test("Quellwechsel ohne Reset: innerhalb der Hysterese bleibt die Helligkeit stehen")
    func sourceSwitchKeepsHysteresis() async {
        let laptop = makeLaptopManager(builtInControl: StubControl())
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.start()
        controller.setDebugMonitoring(true)
        source.send(.connection(.connected), .lux(1000))
        light.send(.connection(.connected), .lux(900)) // 98 %
        #expect(await eventually { external(laptop) == 100 && controller.isBuiltInLightAvailable })

        source.send(.connection(.searching))
        #expect(await eventually { controller.activeLightOrigin == .builtIn })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(external(laptop) == 100)
        #expect(controller.debugLog.allSatisfy { $0.job == nil })
    }

    @Test("Wechselsperre: zurück zur bevorzugten Quelle erst nach 5 s")
    func switchHold() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.start()
        light.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.activeLightOrigin == .builtIn })
        #expect(controller.isLightFallback)
        #expect(await eventually { external(laptop) == 20 })

        clock.advance(by: .seconds(2))
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { controller.isDeskSensorLightAvailable })
        #expect(controller.activeLightOrigin == .builtIn)
        #expect(external(laptop) == 20)
        // Der Ablauf-Termin endet mit der Sperre.
        #expect(controller.lightExpiryDeadline == clock.instant + .seconds(3))

        clock.advance(by: .seconds(3))
        controller.updateActiveLight() // wie der Ablauf-Task
        #expect(controller.activeLightOrigin == .deskSensor)
        #expect(!controller.isLightFallback)
        #expect(await eventually { external(laptop) == 100 })
    }

    @Test("Abgelaufene Quelle: 45 s ohne jedes Ereignis gilt der Schreibtisch-Sensor als weg")
    func staleDeskSensor() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.start()
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor })
        let luxAt = clock.instant
        // Nichts zurückgehalten: Der einzige Termin ist der Ablauf knapp nach 45 s.
        #expect(controller.lightExpiryDeadline == luxAt + .seconds(45) + .milliseconds(10))

        clock.advance(by: .seconds(45))
        controller.updateActiveLight()
        #expect(controller.isDeskSensorLightAvailable) // genau 45 s: noch gültig

        clock.advance(by: .seconds(1))
        controller.updateActiveLight()
        #expect(!controller.isDeskSensorLightAvailable)
        #expect(controller.activeLightOrigin == nil)
        #expect(controller.lightExpiryDeadline == nil)

        light.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.activeLightOrigin == .builtIn })
        #expect(await eventually { external(laptop) == 20 })
    }

    @Test("ESP32 mit Lux nur bei Änderung und Lebenszeichen alle 30 s bleibt aktiv")
    func deskSensorHeartbeatKeepsSource() async {
        let laptop = makeLaptopManager(builtInControl: StubControl())
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.start()
        controller.setDebugMonitoring(true)
        source.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor && external(laptop) == 20 })
        light.send(.connection(.connected), .lux(10))

        // Zwei Minuten gleiches Licht: nur Lebenszeichen, der eingebaute Sensor meldet weiter.
        for _ in 1...4 {
            clock.advance(by: .seconds(30))
            source.send(.heartbeat)
            light.send(.lux(10))
            #expect(await eventually { controller.debugLog.last?.event == .lux(10) })
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

    @Test("Eingebauter Sensor bevorzugt; Deckel zu: Schreibtisch-Sensor springt ein")
    func builtInFirstFallsBackWhenCovered() async {
        let light = StubSensorSource()
        let controller = makeController(builtInLight: light)
        controller.setLightSource(.builtInFirst)
        controller.start()
        // Der Standard-Manager hat kein eingebautes Display: Deckel zu.
        light.send(.connection(.connected), .lux(10))
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor })
        #expect(controller.isLightFallback)
        #expect(controller.isBuiltInLightSensorCovered)
        #expect(brightness == 100)
    }

    @Test("Eingebauter Sensor liest nur, wenn er aktiv oder Rückfall sein kann")
    func builtInRunsOnlyWhenNeeded() async {
        preferences.set(SensorController.LightSource.deskSensorOnly.rawValue, forKey: SensorController.Keys.lightSource)
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.start()
        light.send(.connection(.connected), .lux(10))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.builtInLux == nil)

        controller.setLightSource(.deskSensorFirst)
        #expect(await eventually { controller.builtInLux == 10 })
        controller.setLightSource(.off)
        #expect(controller.builtInLux == nil)
        #expect(controller.activeLightOrigin == nil)
    }

    @Test("Demo übersteuert jede Wahl außer „aus“; der eingebaute Sensor ruht")
    func demoOverridesLightSources() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let light = StubSensorSource()
        let controller = makeController(demo: true, manager: laptop, builtInLight: light)
        controller.setLightSource(.builtInOnly)
        controller.start()
        #expect(controller.activeLightOrigin == .demo)
        #expect(!controller.isLightFallback)
        light.send(.connection(.connected), .lux(10))
        controller.setDemoLux(10)
        #expect(await eventually { controller.lightBrightnessOrigin == .demo })
        #expect(controller.builtInLux == nil)

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
        #expect(credentials.code(for: Self.host)?.raw == "K7M2P9QR")
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
        #expect(credentials.code(for: Self.host) == nil)
        controller.cancelPairing()
    }

    @Test("Entkoppeln löscht Code und Hostnamen")
    func unpair() {
        let controller = makeController()
        controller.start()
        #expect(controller.status == .searching)
        controller.unpair()
        #expect(credentials.code(for: Self.host) == nil)
        #expect(preferences.string(forKey: SensorController.Keys.hostname) == nil)
        #expect(controller.pairedHostname == nil)
        #expect(controller.status == .notPaired)
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
