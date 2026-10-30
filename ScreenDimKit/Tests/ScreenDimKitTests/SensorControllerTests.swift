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
    private let manager: DisplayManager

    init() {
        manager = DisplayManager(
            store: BrightnessStore(storage: preferences),
            timing: .immediate,
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
            now: { [clock] in clock.instant }
        )
    }

    /// MacBook mit offenem Deckel (eingebautes Display 1) und externem Monitor 7.
    private func makeLaptopManager(builtInControl: StubControl) -> DisplayManager {
        let manager = DisplayManager(
            store: BrightnessStore(storage: preferences),
            timing: .immediate,
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

    private static let macBookKey = "1552-1-1"

    /// Helligkeit aus dem Licht nur für Monitor 7.
    private static func monitor7(_ percent: Double) -> [LightLevel] {
        [LightLevel(storageKey: "1-2-3", name: "Monitor 7", percent: percent)]
    }

    /// Helligkeit aus dem Licht für MacBook und Monitor 7 (`makeLaptopManager`).
    private static func laptop(_ percent: Double) -> [LightLevel] {
        [LightLevel(storageKey: macBookKey, name: "MacBook", percent: percent)] + monitor7(percent)
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
        let builtInKey = laptop.monitors.first { $0.isBuiltIn }!.storageKey
        let controller = makeController(manager: laptop)
        controller.setLightProfile(
            LightProfile(followsLight: true, curve: LightCurve(points: [.init(lux: 100, percent: 10), .init(lux: 500, percent: 70)])),
            for: "1-2-3"
        )
        controller.setLightProfile(LightProfile(followsLight: false, curve: .standard), for: builtInKey)
        controller.start()
        let before = builtIn()

        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { external(laptop) == 70 })
        #expect(builtIn() == before)
        #expect(controller.lightLevels == Self.monitor7(70))

        // Profile überdauern einen Neustart des Controllers.
        let reloaded = makeController(manager: laptop)
        #expect(reloaded.lightProfile(for: "1-2-3").curve.points.map(\.percent) == [10, 70])
        #expect(!reloaded.lightProfile(for: builtInKey).followsLight)
    }

    @Test("Geändertes Profil gilt sofort mit dem aktuellen Licht, auch innerhalb der Hysterese")
    func profileChangeAppliesImmediately() async {
        let controller = makeController()
        controller.start()
        source.send(.connection(.connected), .lux(100))
        #expect(await eventually { brightness == 60 })

        var profile = controller.lightProfile(for: "1-2-3")
        profile.curve.insert(.init(lux: 100, percent: 62))
        controller.setLightProfile(profile, for: "1-2-3")
        #expect(brightness == 62)

        // Zurück auf Standard: Der gespeicherte Eintrag verschwindet.
        controller.setLightProfile(.standard, for: "1-2-3")
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

    @Test("Eingebauter Lichtsensor regelt alle Monitore; abgeschaltetes Profil bleibt stehen")
    func builtInLightAdjustsAllMonitors() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let light = StubSensorSource()
        let controller = makeController(paired: false, manager: laptop, builtInLight: light)
        controller.start()
        #expect(controller.hasBuiltInLightSensor)
        controller.setLightSource(.builtInFirst)
        #expect(controller.lightSource == .builtInFirst)

        light.send(.connection(.connected), .lux(10))
        #expect(await eventually { laptop.monitors.first { $0.id == 7 }?.brightness == 20 })
        #expect(controller.builtInLux == 10)
        #expect(await eventually { control.writes.last == 20 })

        controller.setLightProfile(LightProfile(followsLight: false, curve: .standard), for: Self.macBookKey)
        clock.advance(by: .seconds(1))
        light.send(.lux(1000))
        #expect(await eventually { laptop.monitors.first { $0.id == 7 }?.brightness == 100 })
        #expect(laptop.monitors.first { $0.isBuiltIn }?.brightness == 20)

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

        // Die Prüfung scheitert wie bei einem Monitor hinter dem Dock: Software-Dimmung mit
        // dem gespeicherten Wert.
        gate.release(with: .failure(.timeout))
        #expect(await eventually { external()?.usesSoftwareDimming == true })
        #expect(external()?.brightness == 89)

        // Gleiches Licht, innerhalb der Hysterese: Der ausstehende Wert gilt trotzdem.
        clock.advance(by: .seconds(1))
        light.send(.lux(4))
        #expect(await eventually { external()?.brightness == 20 })
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
        #expect(controller.lightLevels == Self.laptop(20))
        #expect(controller.lightBrightnessOrigin == .builtIn)

        #expect(controller.debugLog.contains { $0.origin == .builtIn && $0.effect == .brightness(Self.laptop(20)) })
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

    @Test("Schreibtisch-Sensor fällt aus: eingebauter springt sofort ein, Hysterese neu")
    func fallsBackToBuiltIn() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        #expect(await eventually { laptop.monitors.first { $0.isBuiltIn }?.state == .ready })
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        #expect(controller.lightSource == .deskSensorFirst)
        controller.start()
        controller.setDebugMonitoring(true)

        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor })
        // Der Schreibtisch-Sensor regelt auch das eingebaute Display.
        #expect(await eventually { control.writes.last == 100 })

        // 900 lx sind 98 %: innerhalb der Hysterese, gilt nach dem Wechsel trotzdem sofort.
        light.send(.connection(.connected), .lux(900))
        #expect(await eventually { controller.isBuiltInLightAvailable })
        #expect(controller.activeLightOrigin == .deskSensor)
        #expect(external(laptop) == 100)

        source.send(.connection(.searching))
        #expect(await eventually { controller.activeLightOrigin == .builtIn })
        #expect(controller.isLightFallback)
        #expect(!controller.isDeskSensorLightAvailable)
        #expect(await eventually { external(laptop) == 98 })
        #expect(controller.lightBrightnessOrigin == .builtIn)
        #expect(controller.debugLog.contains {
            $0.kind == .lightSourceSwitch(from: .deskSensor, to: .builtIn) && $0.effect == .brightness(Self.laptop(98))
        })

        // Der eingebaute Sensor regelt auch das eingebaute Display.
        light.send(.lux(10))
        #expect(await eventually { external(laptop) == 20 })
        #expect(await eventually { control.writes.last == 20 })
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

    @Test("Abgelaufene Quelle: ohne neues Lux nach 10 s gilt der Schreibtisch-Sensor als weg")
    func staleDeskSensor() async {
        let control = StubControl()
        let laptop = makeLaptopManager(builtInControl: control)
        let light = StubSensorSource()
        let controller = makeController(manager: laptop, builtInLight: light)
        controller.start()
        source.send(.connection(.connected), .lux(1000))
        #expect(await eventually { controller.activeLightOrigin == .deskSensor })
        let luxAt = clock.instant
        // Nichts zurückgehalten: Der einzige Termin ist der Ablauf knapp nach 10 s.
        #expect(controller.lightExpiryDeadline == luxAt + .seconds(10) + .milliseconds(10))

        clock.advance(by: .seconds(10))
        controller.updateActiveLight()
        #expect(controller.isDeskSensorLightAvailable) // genau 10 s: noch gültig

        clock.advance(by: .seconds(1))
        controller.updateActiveLight()
        #expect(!controller.isDeskSensorLightAvailable)
        #expect(controller.activeLightOrigin == nil)
        #expect(controller.lightExpiryDeadline == nil)

        light.send(.connection(.connected), .lux(10))
        #expect(await eventually { controller.activeLightOrigin == .builtIn })
        #expect(await eventually { external(laptop) == 20 })
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
        controller.setDemoLux(1000)
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
