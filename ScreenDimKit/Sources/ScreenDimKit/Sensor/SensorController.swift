import Foundation
import Observation

/// Verbindet den optionalen Schreibtisch-Sensor (oder die Simulation) mit dem
/// `DisplayManager`: Abwesenheit schaltet die Bildschirme schwarz, Umgebungslicht regelt
/// die Helligkeit. Ohne Sensor passiert nichts; Standard ist „aus“.
///
/// Gekoppelt ist höchstens ein Sensor. Sein Hostname steht in UserDefaults, der Code nur
/// im Schlüsselbund.
@MainActor
@Observable
public final class SensorController {
    public enum Status: Equatable, Sendable {
        /// „Schreibtisch-Sensor verwenden“ ist aus.
        case off
        case demo
        case notPaired
        case searching
        case connected
        /// Der Sensor lehnt den gespeicherten Code ab.
        case pairingRequired
    }

    public enum PairingFailure: Equatable, Sendable {
        case wrongCode
        case timeout
        case unreachable
        /// Drei Minuten lang kam kein Code (BOOT nicht gedrückt).
        case noCodeReceived
        case keychain(OSStatus)
    }

    public enum Pairing: Equatable, Sendable {
        case idle
        /// Erste Abfrage des Codes ohne Login.
        case requesting(DiscoveredSensor)
        /// 401: Kopplungsfenster zu. Fragt alle 2 s nach; manuelle Eingabe möglich.
        case waitingForButton(DiscoveredSensor)
        case verifying(DiscoveredSensor)
        case failed(DiscoveredSensor, PairingFailure)

        public var sensor: DiscoveredSensor? {
            switch self {
            case .idle: nil
            case .requesting(let sensor), .waitingForButton(let sensor), .verifying(let sensor),
                 .failed(let sensor, _): sensor
            }
        }

        public var acceptsManualCode: Bool {
            switch self {
            case .waitingForButton, .failed: true
            default: false
            }
        }
    }

    enum Keys {
        static let enabled = "sensorEnabled"
        static let hostname = "sensorHostname"
        static let adjustsBrightness = "sensorAdjustsBrightness"
        /// Startargument `-ScreenDimDemo YES`; wird nie geschrieben.
        static let demo = "ScreenDimDemo"
    }

    public static let codePollInterval: Duration = .seconds(2)
    public static let pairingWindow: Duration = .seconds(180)
    /// Mindeständerung in Prozentpunkten, bevor Licht die Helligkeit verstellt. Hält
    /// DDC-Writes selten.
    public static let luxHysteresis: Double = 5

    public private(set) var status: Status = .off
    public private(set) var pairing: Pairing = .idle
    public private(set) var pairedHostname: String?
    public private(set) var isEnabled: Bool
    public private(set) var isDemoActive: Bool
    public private(set) var demoSchedule = SimulationSchedule()
    public private(set) var demoLux: Double?
    /// Letzte Meldungen des Sensors; `nil` ohne Verbindung.
    public private(set) var presence: Bool?
    public private(set) var lux: Double?

    public var adjustsBrightness: Bool {
        didSet {
            preferences.set(adjustsBrightness, forKey: Keys.adjustsBrightness)
            lastAppliedBrightness = nil
        }
    }

    @ObservationIgnored private let manager: DisplayManager
    @ObservationIgnored private let preferences: any PreferenceStorage
    @ObservationIgnored private let credentials: any SensorCredentialStore
    @ObservationIgnored private let http: any SensorHTTP
    @ObservationIgnored private let input: any InputActivityMonitoring
    @ObservationIgnored private let makeLiveSource: @MainActor (SensorEndpoint, PairingCode) -> any SensorSource
    @ObservationIgnored private let makeSimulation: @MainActor (SimulationSchedule) -> SimulatedSensorSource
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    @ObservationIgnored private var simulation: SimulatedSensorSource?
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var connection: SensorConnection?
    @ObservationIgnored private var lastEventAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastAppliedBrightness: Double?

    public convenience init(manager: DisplayManager) {
        self.init(
            manager: manager,
            preferences: UserDefaults.standard,
            credentials: SensorKeychain(),
            http: URLSessionSensorHTTP(),
            input: SystemInputActivity(),
            demoAtLaunch: UserDefaults.standard.bool(forKey: Keys.demo),
            makeLiveSource: { SSESensorSource(endpoint: $0, code: $1) },
            makeSimulation: { SimulatedSensorSource(schedule: $0) }
        )
    }

    init(
        manager: DisplayManager,
        preferences: any PreferenceStorage,
        credentials: any SensorCredentialStore,
        http: any SensorHTTP,
        input: any InputActivityMonitoring,
        demoAtLaunch: Bool,
        makeLiveSource: @escaping @MainActor (SensorEndpoint, PairingCode) -> any SensorSource,
        makeSimulation: @escaping @MainActor (SimulationSchedule) -> SimulatedSensorSource,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.manager = manager
        self.preferences = preferences
        self.credentials = credentials
        self.http = http
        self.input = input
        self.makeLiveSource = makeLiveSource
        self.makeSimulation = makeSimulation
        self.now = now
        isEnabled = preferences.object(forKey: Keys.enabled) as? Bool ?? false
        adjustsBrightness = preferences.object(forKey: Keys.adjustsBrightness) as? Bool ?? true
        pairedHostname = preferences.string(forKey: Keys.hostname)
        // Der Demo-Modus ist nach jedem Start aus, außer per Startargument.
        isDemoActive = demoAtLaunch
    }

    public func start() {
        restartSource()
    }

    public func stop() {
        pairingTask?.cancel()
        sourceTask?.cancel()
        sourceTask = nil
        restoreScreens()
    }

    // MARK: - Einstellungen

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        preferences.set(enabled, forKey: Keys.enabled)
        if !enabled { cancelPairing() }
        restartSource()
    }

    /// Demo-Modus und echter Sensor schließen sich aus: Solange die Demo läuft, ist der
    /// Sensor getrennt.
    public func setDemoActive(_ active: Bool) {
        guard active != isDemoActive else { return }
        isDemoActive = active
        if active { cancelPairing() }
        restartSource()
    }

    public func simulateAway() {
        simulation?.simulateAway()
    }

    public func simulateBack() {
        simulation?.simulateBack()
    }

    /// `nil`: Licht wieder als Sinus.
    public func setDemoLux(_ lux: Double?) {
        demoLux = lux
        simulation?.setLux(lux)
    }

    public func setDemoSchedule(_ schedule: SimulationSchedule) {
        demoSchedule = schedule
        simulation?.schedule = schedule
    }

    // MARK: - Quelle

    private func restartSource() {
        sourceTask?.cancel()
        sourceTask = nil
        simulation = nil
        connection = nil
        presence = nil
        lux = nil
        lastEventAt = nil
        lastAppliedBrightness = nil
        restoreScreens()

        let source: any SensorSource
        if isDemoActive {
            let simulation = makeSimulation(demoSchedule)
            simulation.setLux(demoLux)
            self.simulation = simulation
            source = simulation
            status = .demo
        } else if isEnabled, let host = pairedHostname {
            guard let code = credentials.code(for: host) else {
                status = .pairingRequired
                return
            }
            source = makeLiveSource(SensorEndpoint(hostname: host), code)
            status = .searching
        } else {
            status = isEnabled ? .notPaired : .off
            return
        }

        sourceTask = Task { [weak self] in
            for await event in source.events() {
                guard !Task.isCancelled, let self else { return }
                self.handle(event)
            }
        }
    }

    func handle(_ event: SensorEvent) {
        switch event {
        case .connection(let connection):
            self.connection = connection
            if !isDemoActive {
                status = switch connection {
                case .searching: .searching
                case .connected: .connected
                case .pairingRequired: .pairingRequired
                }
            }
            guard connection == .connected else {
                // Getrennt: Normalzustand, nichts mehr ausschalten.
                lastEventAt = nil
                presence = nil
                restoreScreens()
                return
            }
            lastEventAt = now()
        case .presence(let present):
            lastEventAt = now()
            let changed = presence != present
            presence = present
            if present {
                restoreScreens()
            } else if changed, PresenceGate.shouldBlank(
                presence: present,
                connected: connection == .connected,
                lastEventAge: lastEventAge,
                sinceLastInput: input.timeSinceLastInput
            ) {
                blankScreens()
            }
        case .lux(let value):
            lastEventAt = now()
            lux = value
            applyAmbientLight(value)
        case .heartbeat:
            lastEventAt = now()
        }
    }

    private var lastEventAge: Duration? {
        lastEventAt.map { now() - $0 }
    }

    private func applyAmbientLight(_ lux: Double) {
        guard adjustsBrightness, !manager.screensBlanked else { return }
        let target = AmbientLightCurve.percent(forLux: lux)
        if let last = lastAppliedBrightness, abs(last - target) < Self.luxHysteresis { return }
        lastAppliedBrightness = target
        manager.setAllBrightness(target)
    }

    // MARK: - Bildschirme

    private func blankScreens() {
        manager.setScreensBlanked(true)
        // Eingabe gewinnt immer: Maus oder Tastatur weckt sofort.
        input.startObserving { [weak self] in self?.restoreScreens() }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var wait = PresenceGate.staleAfter
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                let age = self.lastEventAge
                if PresenceGate.isStale(connected: self.connection == .connected, lastEventAge: age) {
                    self.restoreScreens()
                    return
                }
                wait = PresenceGate.staleAfter - (age ?? .zero)
            }
        }
    }

    private func restoreScreens() {
        watchdog?.cancel()
        watchdog = nil
        input.stopObserving()
        manager.setScreensBlanked(false)
    }

    // MARK: - Kopplung

    /// Holt den Code im Kopplungsfenster ohne Login. Ist das Fenster zu (401), fragt sie
    /// drei Minuten lang alle 2 s nach, bis jemand kurz BOOT drückt.
    public func beginPairing(with sensor: DiscoveredSensor) {
        pairingTask?.cancel()
        pairing = .requesting(sensor)
        pairingTask = Task { [weak self] in await self?.requestCode(from: sensor) }
    }

    /// Manuell eingegebener Code. `false`, wenn er nicht gültig aussieht.
    @discardableResult
    public func submitCode(_ text: String) -> Bool {
        guard let sensor = pairing.sensor, let code = PairingCode(normalizing: text) else { return false }
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in await self?.verify(code, with: sensor, typed: true) }
        return true
    }

    public func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    /// Löscht Hostname und Code und trennt den Sensor.
    public func unpair() {
        cancelPairing()
        if let pairedHostname { credentials.delete(pairedHostname) }
        pairedHostname = nil
        preferences.set(nil, forKey: Keys.hostname)
        restartSource()
    }

    private func requestCode(from sensor: DiscoveredSensor) async {
        let deadline = now() + Self.pairingWindow
        let url = sensor.endpoint.url(SensorProtocol.pairingPath)
        while !Task.isCancelled {
            let response = await http.get(url, password: nil)
            guard !Task.isCancelled else { return }
            let first = pairing == .requesting(sensor)
            switch response {
            case .ok(let data):
                if let code = PairingCode.fromPairingResponse(data) {
                    await verify(code, with: sensor, typed: false)
                    return
                }
                if first { pairing = .waitingForButton(sensor) }
            case .unauthorized:
                if first { pairing = .waitingForButton(sensor) }
            case .timeout where first:
                pairing = .failed(sensor, .timeout)
                return
            case .unreachable where first, .status where first:
                pairing = .failed(sensor, .unreachable)
                return
            case .timeout, .unreachable, .status:
                break // Während des Wartens zählen nur Code oder Ablauf.
            }
            guard now() < deadline else {
                pairing = .failed(sensor, .noCodeReceived)
                return
            }
            try? await Task.sleep(for: Self.codePollInterval)
        }
    }

    /// Prüft den Code mit `GET /binary_sensor/Presence` per Digest.
    private func verify(_ code: PairingCode, with sensor: DiscoveredSensor, typed: Bool) async {
        pairing = .verifying(sensor)
        // Im offenen Kopplungsfenster nimmt der Sensor jedes Passwort an; dann muss ein
        // eingetippter Code dem angezeigten gleichen.
        if typed, case .ok(let data) = await http.get(sensor.endpoint.url(SensorProtocol.pairingPath), password: nil),
           let shown = PairingCode.fromPairingResponse(data), shown != code {
            guard !Task.isCancelled else { return }
            pairing = .failed(sensor, .wrongCode)
            return
        }
        let response = await http.get(sensor.endpoint.url(SensorProtocol.presencePath), password: code.raw)
        guard !Task.isCancelled else { return }
        switch response {
        case .ok:
            do throws(SensorKeychain.Failure) {
                try credentials.save(code, for: sensor.hostname)
            } catch {
                pairing = .failed(sensor, .keychain(error.status))
                return
            }
            if let old = pairedHostname, old != sensor.hostname { credentials.delete(old) }
            pairedHostname = sensor.hostname
            preferences.set(sensor.hostname, forKey: Keys.hostname)
            sensorLog.notice("Gekoppelt mit \(sensor.hostname, privacy: .public)")
            pairing = .idle
            restartSource()
        case .unauthorized:
            pairing = .failed(sensor, .wrongCode)
        case .timeout:
            pairing = .failed(sensor, .timeout)
        case .unreachable, .status:
            pairing = .failed(sensor, .unreachable)
        }
    }
}
