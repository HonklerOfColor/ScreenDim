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

    private func makeController(paired: Bool = true, demo: Bool = false) -> SensorController {
        if paired {
            preferences.set(true, forKey: SensorController.Keys.enabled)
            preferences.set(Self.host, forKey: SensorController.Keys.hostname)
            try? credentials.save(Self.code, for: Self.host)
        }
        let source = source
        return SensorController(
            manager: manager,
            preferences: preferences,
            credentials: credentials,
            http: http,
            input: input,
            demoAtLaunch: demo,
            makeLiveSource: { _, _ in source },
            makeSimulation: { SimulatedSensorSource(schedule: $0, seed: 1) }
        )
    }

    private var brightness: Double? { manager.monitors.first?.brightness }

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

        controller.adjustsBrightness = false
        source.send(.lux(1000))
        #expect(await eventually { controller.lux == 1000 })
        #expect(brightness == 20)
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
