import AppKit
import CoreGraphics
import Foundation
import Observation

/// Verbindet den optionalen Schreibtisch-Sensor (oder die Simulation) mit dem
/// `DisplayManager`: Abwesenheit schaltet die Bildschirme schwarz, Umgebungslicht regelt
/// die Helligkeit. Ohne Sensor passiert nichts; Standard ist „aus“.
///
/// Das Licht kann außer vom Schreibtisch-Sensor auch vom eingebauten Lichtsensor des Macs
/// kommen (MacBook, iMac; Quelle per Fabrik, derzeit reicht die App keine herein). Welche Quelle gilt,
/// entscheidet `LightSourceSelector` nach Wahl
/// (`LightSource`) und Verfügbarkeit; die andere springt bei Ausfall ein.
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
        /// Der Schlüsselbund gibt den Code nicht her (gesperrt, Zugriff verweigert). Der Code
        /// ist womöglich da; eine Neukopplung würde ihn nur überschreiben.
        case keychainUnavailable(OSStatus)
    }

    /// Woher das Umgebungslicht für die Helligkeit kommt, mit Vorrang. Die Fälle mit dem
    /// eingebauten Lichtsensor sind nur wählbar, wenn es ihn gibt.
    public enum LightSource: String, CaseIterable, Sendable {
        /// Schreibtisch-Sensor; fällt er aus, der eingebaute Sensor. Standard.
        case deskSensorFirst
        /// Eingebauter Sensor; fällt er aus (Deckel zu), der Schreibtisch-Sensor.
        case builtInFirst
        case deskSensorOnly
        case builtInOnly
        case off
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
        static let lightSource = "sensorLightSource"
        /// Alt (Schalter „Helligkeit ans Umgebungslicht anpassen“); nur noch gelesen, um
        /// die Einstellung in `lightSource` zu übernehmen.
        static let adjustsBrightness = "sensorAdjustsBrightness"
        /// Startargument `-ScreenDimDemo YES`; wird nie geschrieben.
        static let demo = "ScreenDimDemo"
    }

    public static let codePollInterval: Duration = .seconds(2)
    public static let pairingWindow: Duration = .seconds(180)
    /// Mindestabstand in Prozentpunkten zwischen neuem Ziel und dem Wert, auf den der
    /// Monitor gerade zugeht, bevor Licht ihn verstellt. Hält DDC-Writes selten.
    public static let lightHysteresis: Double = 3
    /// Nach Regler oder Tastenkürzel ruht die Lichtregelung dieses Monitors so lange, oder
    /// bis sich das Licht um mehr als `manualHoldLuxFactor` ändert.
    public static let manualHold: Duration = .seconds(300)
    nonisolated public static let manualHoldLuxFactor: Double = 2
    /// Nach einer fremden Änderung (macOS, Helligkeitstasten) ruht die Lichtregelung dieses
    /// Displays so lange.
    public static let externalChangeHold: Duration = .seconds(60)
    /// So lange gilt der gelesene Zustand der Auto-Helligkeit; danach liest der nächste
    /// Lichtwert neu. Wird die App aktiv (etwa die Einstellungen geöffnet), liest sie sofort.
    public static let autoBrightnessMaxAge: Duration = .seconds(10)
    /// Faktor für die Lux des eingebauten Sensors vor der Kurve. Er sitzt hinter dem
    /// Displayglas; kalibriert ist der Wert noch nicht.
    public static let builtInLuxFactor: Double = 1.0
    /// So viele Einträge behält das Protokoll der Sensor-Diagnose.
    public static let debugLogLimit = 200

    public private(set) var status: Status = .off
    public private(set) var pairing: Pairing = .idle
    public private(set) var pairedHostname: String?
    public private(set) var isEnabled: Bool
    public private(set) var isDemoActive: Bool
    public private(set) var demoSchedule = SimulationSchedule()
    public private(set) var demoLux: Double?
    /// Letzte Meldungen des Sensors; `nil` ohne Verbindung.
    public private(set) var presence: Bool?
    /// Letztes Lux, roh und geglättet (`LuxFilter`); geglättet geht es in die Kurven.
    public private(set) var lux: Double?
    public private(set) var filteredLux: Double?
    /// Gespeicherte Wahl. Sie bleibt erhalten, auch wenn dieser Mac sie nicht kann; was
    /// wirkt, steht in `effectiveLightSource`.
    public private(set) var lightSource: LightSource
    /// Quelle, deren Licht gerade die Helligkeit regelt; `nil`, wenn keine.
    public private(set) var activeLightOrigin: SensorOrigin?
    /// Verfügbarkeit nach `LightSourceSelector`, Stand der letzten Prüfung.
    public private(set) var isDeskSensorLightAvailable = false
    public private(set) var isBuiltInLightAvailable = false
    /// Letzter Wert des eingebauten Lichtsensors; `nil`, solange er nicht läuft (weder
    /// Lichtquelle noch Sensor-Diagnose offen) oder der Deckel zu ist.
    public private(set) var builtInLux: Double?
    public private(set) var builtInFilteredLux: Double?
    /// Zeit des letzten Ereignisses vom Schreibtisch-Sensor bzw. der Demo und vom
    /// eingebauten Lichtsensor.
    public private(set) var lastEventDate: Date?
    public private(set) var builtInLastEventDate: Date?
    /// Letzte Helligkeit aus dem Licht je angeschlossenem Monitor und woher das Licht kam.
    public private(set) var lightLevels: [LightLevel] = []
    public private(set) var lightBrightnessOrigin: SensorOrigin?
    /// Geänderte Lichtprofile dieser Sitzung; die übrigen liegen in `profileStore`.
    private var lightProfiles: [String: LightProfile] = [:]
    /// Aus dem Speicher gelesene Profile, damit nicht jeder Zugriff dekodiert. Nicht
    /// beobachtet: Das Füllen beim Lesen darf kein Neurendern auslösen.
    @ObservationIgnored private var loadedProfiles: [String: LightProfile] = [:]
    /// Sensor-Diagnose offen: Ereignisse werden protokolliert, und der eingebaute
    /// Lichtsensor liest mit, auch wenn er nicht die Lichtquelle ist.
    public private(set) var isDebugMonitoring = false
    public private(set) var debugLog: [SensorDebugEntry] = []

    /// Dieser Mac hat einen Lichtsensor, und die Variante darf ihn lesen.
    public var hasBuiltInLightSensor: Bool { builtInLightSensor != nil }

    /// Deckel zu: Das eingebaute Display ist nicht online, der Sensor liegt im Dunkeln und
    /// seine Werte zählen nicht.
    public var isBuiltInLightSensorCovered: Bool {
        !manager.monitors.contains(where: \.isBuiltIn)
    }

    /// Was diese Wahl hier bewirkt: Ohne eingebauten Sensor wirkt jede Wahl außer „aus“
    /// wie „nur Schreibtisch-Sensor“.
    public var effectiveLightSource: LightSource {
        LightSourceSelector.effectiveChoice(lightSource, builtInPresent: hasBuiltInLightSensor)
    }

    /// Wählbare Lichtquellen: ohne eingebauten Sensor nur Schreibtisch-Sensor oder aus.
    public var availableLightSources: [LightSource] {
        hasBuiltInLightSensor ? LightSource.allCases : [.deskSensorOnly, .off]
    }

    /// Die aktive Quelle ist nicht die bevorzugte, sondern springt für sie ein.
    public var isLightFallback: Bool {
        guard let activeLightOrigin, activeLightOrigin != .demo else { return false }
        return activeLightOrigin != effectiveLightSource.order.first
    }

    /// Quelle, deren Anwesenheit gerade die Bildschirme schaltet; `nil`, wenn keine.
    public var activePresenceOrigin: SensorOrigin? {
        if isDemoActive { return .demo }
        return status == .connected ? .deskSensor : nil
    }

    public var screensBlanked: Bool { manager.screensBlanked }

    /// Der eingebaute Lichtsensor soll lesen: Er kann aktiv oder Rückfall sein (nicht in der
    /// Demo), oder die Sensor-Diagnose ist offen.
    private var readsBuiltInLight: Bool {
        guard hasBuiltInLightSensor else { return false }
        return isDebugMonitoring || (!isDemoActive && effectiveLightSource.order.contains(.builtIn))
    }

    @ObservationIgnored private let manager: DisplayManager
    @ObservationIgnored private let preferences: any PreferenceStorage
    @ObservationIgnored private let credentials: any SensorCredentialStore
    @ObservationIgnored private let profileStore: LightProfileStore
    @ObservationIgnored private let http: any SensorHTTP
    @ObservationIgnored private let input: any InputActivityMonitoring
    @ObservationIgnored private let makeLiveSource: @MainActor (SensorEndpoint, PairingCode) -> any SensorSource
    @ObservationIgnored private let makeSimulation: @MainActor (SimulationSchedule) -> SimulatedSensorSource
    @ObservationIgnored private let builtInLightSensor: (any SensorSource)?
    @ObservationIgnored private let readAutoBrightness: @MainActor () -> Bool?
    @ObservationIgnored private var autoBrightnessReadAt: ContinuousClock.Instant?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    @ObservationIgnored private var simulation: SimulatedSensorSource?
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var builtInLightTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var connection: SensorConnection?
    @ObservationIgnored private var lastEventAt: ContinuousClock.Instant?
    @ObservationIgnored private var deskFilter = LuxFilter(.deskSensor)
    @ObservationIgnored private var builtInFilter = LuxFilter(.builtIn)
    /// Pausen der Lichtregelung je Monitor (`storageKey`).
    @ObservationIgnored private var holds: [String: LightHold] = [:]
    /// Monitore, die beim letzten Setzen noch in der DDC-Prüfung waren und den Wert nicht
    /// übernommen haben; der nächste Lux-Wert holt ihn nach, auch innerhalb der Hysterese.
    @ObservationIgnored private var pendingLight: Set<String> = []
    /// Letzter Wert des eingebauten Sensors. Beim Schreibtisch-Sensor zählt jedes
    /// Ereignis (`lastEventAt`).
    @ObservationIgnored private var builtInLuxAt: ContinuousClock.Instant?
    @ObservationIgnored private var lightSwitchedAt: ContinuousClock.Instant?
    /// Ein einzelner Schlaf bis zum nächsten Zeitpunkt, an dem eine Quelle abläuft oder die
    /// Wechselsperre endet.
    @ObservationIgnored private var lightExpiry: Task<Void, Never>?
    @ObservationIgnored private(set) var lightExpiryDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var nextDebugID = 0

    /// - Parameters:
    ///   - makeBuiltInLightSensor: eingebauter Lichtsensor; `nil` ohne Sensor (Mac mini,
    ///     Mac Studio) oder ohne Fabrik (die App reicht derzeit keine herein).
    ///   - isAutoBrightnessEnabled: ob macOS das eingebaute Display selbst regelt
    ///     („Helligkeit automatisch anpassen“); `nil`, wenn unbekannt (keine Fabrik).
    public convenience init(
        manager: DisplayManager,
        makeBuiltInLightSensor: @MainActor () -> (any SensorSource)? = { nil },
        isAutoBrightnessEnabled: @escaping @MainActor () -> Bool? = { nil }
    ) {
        self.init(
            manager: manager,
            preferences: UserDefaults.standard,
            credentials: SensorKeychain(),
            http: URLSessionSensorHTTP(),
            input: SystemInputActivity(),
            demoAtLaunch: UserDefaults.standard.bool(forKey: Keys.demo),
            makeLiveSource: { SSESensorSource(endpoint: $0, code: $1) },
            makeSimulation: { SimulatedSensorSource(schedule: $0) },
            makeBuiltInLightSensor: makeBuiltInLightSensor,
            isAutoBrightnessEnabled: isAutoBrightnessEnabled
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
        makeBuiltInLightSensor: @MainActor () -> (any SensorSource)? = { nil },
        isAutoBrightnessEnabled: @escaping @MainActor () -> Bool? = { nil },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.manager = manager
        self.preferences = preferences
        self.credentials = credentials
        profileStore = LightProfileStore(storage: preferences)
        self.http = http
        self.input = input
        self.makeLiveSource = makeLiveSource
        self.makeSimulation = makeSimulation
        self.now = now
        builtInLightSensor = makeBuiltInLightSensor()
        readAutoBrightness = isAutoBrightnessEnabled
        isEnabled = preferences.object(forKey: Keys.enabled) as? Bool ?? false
        // Ohne Lichtsensor wirkt „eingebaut“ wie der Schreibtisch-Sensor (`effectiveLightSource`);
        // gespeichert bleibt die Wahl trotzdem.
        lightSource = preferences.string(forKey: Keys.lightSource).flatMap(LightSource.init(storedValue:))
            ?? ((preferences.object(forKey: Keys.adjustsBrightness) as? Bool ?? true) ? .deskSensorFirst : .off)
        pairedHostname = preferences.string(forKey: Keys.hostname)
        // Der Demo-Modus ist nach jedem Start aus, außer per Startargument.
        isDemoActive = demoAtLaunch
        manager.onBrightnessJob = { [weak self] job in self?.handleJob(job) }
        manager.onMonitorReady = { [weak self] id in self?.monitorReady(id) }
    }

    public func start() {
        refreshAutoBrightness()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAutoBrightness() }
        }
        restartSource()
        restartBuiltInLight()
    }

    public func stop() {
        activationObserver.map(NotificationCenter.default.removeObserver)
        activationObserver = nil
        pairingTask?.cancel()
        sourceTask?.cancel()
        sourceTask = nil
        builtInLightTask?.cancel()
        builtInLightTask = nil
        lightExpiry?.cancel()
        lightExpiry = nil
        lightExpiryDeadline = nil
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
        restartBuiltInLight()
    }

    public func setLightSource(_ source: LightSource) {
        guard source != lightSource, availableLightSources.contains(source) else { return }
        lightSource = source
        preferences.set(source.rawValue, forKey: Keys.lightSource)
        // Der eingebaute Sensor startet oder stoppt nur, wenn er dazukommt oder wegfällt;
        // sonst bleibt sein letzter Wert gültig.
        if (builtInLightTask != nil) != readsBuiltInLight {
            restartBuiltInLight()
        } else {
            updateActiveLight()
        }
    }

    /// Sensor-Diagnose geöffnet bzw. geschlossen. Beim Schließen wird das Protokoll gelöscht.
    public func setDebugMonitoring(_ monitoring: Bool) {
        guard monitoring != isDebugMonitoring else { return }
        let wasReading = builtInLightTask != nil
        isDebugMonitoring = monitoring
        if !monitoring { debugLog.removeAll() }
        if wasReading != readsBuiltInLight {
            restartBuiltInLight()
        }
    }

    public func clearDebugLog() {
        debugLog.removeAll()
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
        // Status und Demo stehen erst am Ende fest.
        defer { updateActiveLight() }
        sourceTask?.cancel()
        sourceTask = nil
        simulation = nil
        connection = nil
        presence = nil
        lux = nil
        filteredLux = nil
        deskFilter.reset()
        lastEventAt = nil
        lastEventDate = nil
        if lightBrightnessOrigin != .builtIn {
            lightLevels = []
            lightBrightnessOrigin = nil
        }
        restoreScreens()

        let source: any SensorSource
        if isDemoActive {
            let simulation = makeSimulation(demoSchedule)
            simulation.setLux(demoLux)
            self.simulation = simulation
            source = simulation
            status = .demo
        } else if isEnabled, let host = pairedHostname {
            let code: PairingCode
            do throws(SensorKeychain.Failure) {
                guard let stored = try credentials.code(for: host) else {
                    status = .pairingRequired
                    return
                }
                code = stored
            } catch {
                sensorLog.error("Schlüsselbund nicht lesbar (Status \(error.status)); keine Neukopplung")
                status = .keychainUnavailable(error.status)
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
        let origin: SensorOrigin = isDemoActive ? .demo : .deskSensor
        let blankedBefore = manager.screensBlanked
        var applied: [LightLevel] = []
        defer { record(origin, event, blankedBefore: blankedBefore, applied: applied) }
        if event != .connection(.searching), event != .connection(.pairingRequired) {
            lastEventDate = Date()
        }
        switch event {
        case .connection(let connection):
            if self.connection != connection { self.connection = connection }
            if !isDemoActive {
                let new: Status = switch connection {
                case .searching: .searching
                case .connected: .connected
                case .pairingRequired: .pairingRequired
                }
                // Jeder Verbindungsversuch meldet „suchen“; ohne Änderung kein Neurendern.
                if status != new { status = new }
            }
            guard connection == .connected else {
                // Getrennt: Normalzustand, nichts mehr ausschalten.
                lastEventAt = nil
                presence = nil
                restoreScreens()
                updateActiveLight()
                return
            }
            lastEventAt = now()
            updateActiveLight()
        case .presence(let present):
            lastEventAt = now()
            let changed = presence != present
            presence = present
            if present {
                restoreScreens()
            } else if changed, PresenceGate.shouldBlank(
                presence: present,
                connected: connection == .connected,
                sinceLastInput: input.timeSinceLastInput
            ) {
                blankScreens()
            }
        case .lux(let value):
            lastEventAt = now()
            lux = value
            let filtered = deskFilter.add(value, at: now())
            filteredLux = filtered
            updateActiveLight(trigger: origin)
            if activeLightOrigin == origin {
                applied = applyAmbientLight(filtered, from: origin, reason: .lux(raw: value, filtered: filtered, origin: origin))
            }
        case .heartbeat:
            lastEventAt = now()
        }
    }

    private var lastEventAge: Duration? {
        lastEventAt.map { now() - $0 }
    }

    /// Jeder Monitor folgt seinem eigenen Lichtprofil, gleich aus welcher Quelle das Licht
    /// kommt. Ausgelassen werden Monitore ohne „folgt dem Licht“, in einer Pause (Regler,
    /// fremde Änderung) und das eingebaute Display, solange macOS es selbst regelt: Es gibt
    /// nur einen Schreiber. Die Hysterese gilt gegen den Wert, auf den der Monitor gerade
    /// zugeht; neue Werte blendet der `DisplayManager` vom echten Wert aus über.
    /// - Parameters:
    ///   - lux: geglättetes Lux der Quelle.
    ///   - only: nur diesen Monitor (`storageKey`), etwa nach geändertem Profil.
    ///   - ignoresHysteresis: neues Profil oder nachgeholter Wert nach der Prüfung.
    /// - Returns: die beauftragten Helligkeiten; leer, wenn sich nichts geändert hat.
    @discardableResult
    private func applyAmbientLight(
        _ lux: Double,
        from origin: SensorOrigin,
        reason: BrightnessJob.Reason,
        only: String? = nil,
        ignoresHysteresis: Bool = false
    ) -> [LightLevel] {
        guard !manager.screensBlanked else { return [] }
        let value = origin == .builtIn ? lux * Self.builtInLuxFactor : lux
        let at = now()
        var applied: [LightLevel] = []
        for monitor in manager.monitors {
            let key = monitor.storageKey
            let profile = lightProfile(for: monitor)
            guard only == nil || only == key, profile.followsLight, !macOSRegulates(monitor) else { continue }
            if let hold = holds[key] {
                if hold.isActive(at: at, lux: value) { continue }
                holds[key] = nil
            }
            let target = profile.curve.percent(forLux: value)
            let reference = manager.brightnessTarget(for: monitor.id) ?? monitor.brightness
            if abs(reference - target) < Self.lightHysteresis, !ignoresHysteresis, !pendingLight.contains(key) {
                continue
            }
            if manager.fadeBrightness(to: target, for: monitor.id, reason: reason) {
                pendingLight.remove(key)
            } else {
                pendingLight.insert(key)
            }
            applied.append(LightLevel(storageKey: key, name: monitor.name, percent: target))
        }
        if !applied.isEmpty {
            // Je Monitor der neueste Wert, nur angeschlossene.
            let previous = Dictionary(lightLevels.map { ($0.storageKey, $0) }, uniquingKeysWith: { $1 })
            let new = Dictionary(applied.map { ($0.storageKey, $0) }, uniquingKeysWith: { $1 })
            lightLevels = manager.monitors.compactMap { new[$0.storageKey] ?? previous[$0.storageKey] }
            lightBrightnessOrigin = origin
        }
        return applied
    }

    /// macOS regelt das eingebaute Display selbst („Helligkeit automatisch anpassen“).
    /// Software-Dimmung wirkt zusätzlich zur Hintergrundbeleuchtung und stört nicht.
    private func macOSRegulates(_ monitor: DisplayManager.Monitor) -> Bool {
        guard monitor.isBuiltIn, !monitor.usesSoftwareDimming else { return false }
        refreshAutoBrightness(force: false)
        return isMacOSAutoBrightnessEnabled == true
    }

    // MARK: - Pausen und Aufträge

    /// Pause der Lichtregelung eines Monitors.
    struct LightHold {
        let until: ContinuousClock.Instant
        /// Licht beim Beginn; ändert es sich um mehr als den Faktor, endet die Pause.
        let lux: Double?

        func isActive(at instant: ContinuousClock.Instant, lux current: Double) -> Bool {
            guard instant < until else { return false }
            guard let lux else { return true }
            let ratio = (current + 1) / (lux + 1)
            return ratio <= SensorController.manualHoldLuxFactor && ratio >= 1 / SensorController.manualHoldLuxFactor
        }
    }

    /// Jeder Auftrag des `DisplayManager`: protokollieren; Regler und fremde Änderungen
    /// pausieren die Lichtregelung dieses Monitors, ihr Wert ist der neue Bezug.
    func handleJob(_ job: BrightnessJob) {
        switch job.reason {
        case .manual:
            holds[job.storageKey] = LightHold(until: now() + Self.manualHold, lux: activeLux)
            pendingLight.remove(job.storageKey)
        case .externalChange:
            holds[job.storageKey] = LightHold(until: now() + Self.externalChangeHold, lux: nil)
        default:
            break
        }
        appendDebug(.brightnessJob(job), effect: nil)
    }

    /// Nach der Prüfung: Licht, das währenddessen kam, gilt jetzt.
    private func monitorReady(_ id: CGDirectDisplayID) {
        guard let monitor = manager.monitors.first(where: { $0.id == id }), pendingLight.contains(monitor.storageKey),
              let origin = activeLightOrigin, let lux = currentLux(of: origin)
        else { return }
        applyAmbientLight(lux, from: origin, reason: .pendingAfterProbe, only: monitor.storageKey, ignoresHysteresis: true)
    }

    // MARK: - Lichtprofile

    /// Geglättetes Lux der aktiven Lichtquelle, so wie es in die Kurven eingeht; `nil` ohne
    /// Quelle.
    public var activeLux: Double? {
        guard let origin = activeLightOrigin, let lux = currentLux(of: origin) else { return nil }
        return origin == .builtIn ? lux * Self.builtInLuxFactor : lux
    }

    /// Ob macOS das eingebaute Display selbst regelt, Stand des letzten Lesens; `nil`, wenn
    /// unbekannt. Beobachtbar für die Einstellungen; Lesen nur über `refreshAutoBrightness`.
    public private(set) var isMacOSAutoBrightnessEnabled: Bool?

    /// Liest „Helligkeit automatisch anpassen“ neu: immer mit `force`, sonst nur, wenn der
    /// gemerkte Zustand älter als `autoBrightnessMaxAge` ist. Kein Takt: gelesen wird beim
    /// Start, wenn die App aktiv wird, und höchstens alle 10 s beim nächsten Lichtwert.
    public func refreshAutoBrightness(force: Bool = true) {
        let at = now()
        if !force, let read = autoBrightnessReadAt, at - read < Self.autoBrightnessMaxAge { return }
        autoBrightnessReadAt = at
        let value = readAutoBrightness()
        if value != isMacOSAutoBrightnessEnabled {
            isMacOSAutoBrightnessEnabled = value
        }
    }

    /// Lichtprofil eines Monitors; ohne eigenes das Standardprofil. Das eingebaute Display
    /// folgt dem Licht standardmäßig nicht: Es regelt meist macOS.
    public func lightProfile(for monitor: DisplayManager.Monitor) -> LightProfile {
        lightProfile(forKey: monitor.storageKey, isBuiltIn: monitor.isBuiltIn)
    }

    /// Gespeicherte Profile werden beim ersten Lesen dekodiert und gemerkt: Die Oberfläche
    /// und jedes Lux-Ereignis fragen je Monitor mehrfach.
    public func lightProfile(forKey key: String, isBuiltIn: Bool) -> LightProfile {
        if let profile = lightProfiles[key] ?? loadedProfiles[key] { return profile }
        let profile = profileStore.profile(for: key) ?? Self.defaultProfile(isBuiltIn: isBuiltIn)
        loadedProfiles[key] = profile
        return profile
    }

    static func defaultProfile(for monitor: DisplayManager.Monitor) -> LightProfile {
        defaultProfile(isBuiltIn: monitor.isBuiltIn)
    }

    static func defaultProfile(isBuiltIn: Bool) -> LightProfile {
        isBuiltIn ? LightProfile(followsLight: false, curve: .standard) : .standard
    }

    /// Speichert das Profil und wendet es sofort mit dem aktuellen Licht an, ohne Hysterese.
    /// Eine Pause dieses Monitors endet.
    public func setLightProfile(_ profile: LightProfile, for monitor: DisplayManager.Monitor) {
        setLightProfile(profile, forKey: monitor.storageKey, isBuiltIn: monitor.isBuiltIn)
    }

    public func setLightProfile(_ profile: LightProfile, forKey key: String, isBuiltIn: Bool) {
        guard profile != lightProfile(forKey: key, isBuiltIn: isBuiltIn) else { return }
        lightProfiles[key] = profile
        profileStore.setProfile(profile == Self.defaultProfile(isBuiltIn: isBuiltIn) ? nil : profile, for: key)
        holds[key] = nil
        if let origin = activeLightOrigin, let lux = currentLux(of: origin) {
            applyAmbientLight(lux, from: origin, reason: .profileChange, only: key, ignoresHysteresis: true)
        }
    }

    // MARK: - Auswahl der Lichtquelle

    /// Prüft, welche Lichtquelle gilt, und wechselt bei Bedarf. Läuft nach jedem Ereignis,
    /// jeder Einstellung und einmal, wenn eine Quelle abläuft oder die Wechselsperre endet.
    /// - Parameter trigger: Quelle, deren Lux gerade ankommt. Wird sie aktiv, setzt der
    ///   Aufrufer ihren Wert; sonst gilt der letzte Wert der neuen Quelle sofort.
    func updateActiveLight(trigger: SensorOrigin? = nil) {
        let at = now()
        let deskAvailable = LightSourceSelector.isDeskSensorAvailable(
            connected: status == .connected,
            eventAge: lux == nil ? nil : lastEventAt.map { at - $0 }
        )
        let builtInAvailable = LightSourceSelector.isBuiltInAvailable(
            present: hasBuiltInLightSensor,
            covered: isBuiltInLightSensorCovered,
            luxAge: builtInLuxAt.map { at - $0 }
        )
        // Läuft nach jedem Ereignis (auch Pings); beobachtete Werte nur bei Änderung setzen.
        if isDeskSensorLightAvailable != deskAvailable { isDeskSensorLightAvailable = deskAvailable }
        if isBuiltInLightAvailable != builtInAvailable { isBuiltInLightAvailable = builtInAvailable }
        func select(current: SensorOrigin?, sinceLastSwitch: Duration?) -> SensorOrigin? {
            LightSourceSelector.select(
                choice: effectiveLightSource,
                demo: isDemoActive,
                deskAvailable: isDeskSensorLightAvailable,
                builtInAvailable: isBuiltInLightAvailable,
                current: current,
                sinceLastSwitch: sinceLastSwitch
            )
        }
        let selected = select(current: activeLightOrigin, sinceLastSwitch: lightSwitchedAt.map { at - $0 })
        if selected != activeLightOrigin {
            let previous = activeLightOrigin
            activeLightOrigin = selected
            lightSwitchedAt = at
            // Die Hysterese bleibt: Die neue Quelle blendet mit ihrem geglätteten Wert vom
            // aktuellen Stand aus über, nur wenn er deutlich abweicht.
            var applied: [LightLevel] = []
            if let selected, selected != trigger, let value = currentLux(of: selected) {
                applied = applyAmbientLight(value, from: selected, reason: .sourceSwitch(from: previous, to: selected))
            }
            sensorLog.notice(
                "Lichtquelle: \(previous?.rawValue ?? "-", privacy: .public) → \(selected?.rawValue ?? "-", privacy: .public)"
            )
            appendDebug(.lightSourceSwitch(from: previous, to: selected), effect: applied.isEmpty ? nil : .brightness(applied))
        }
        // Hält die Sperre gerade einen Wechsel zurück?
        let held = select(current: nil, sinceLastSwitch: nil) != activeLightOrigin
        scheduleLightExpiry(at: at, held: held)
    }

    /// Geglättetes Lux einer Quelle.
    private func currentLux(of origin: SensorOrigin) -> Double? {
        switch origin {
        case .deskSensor, .demo: filteredLux
        case .builtIn: builtInFilteredLux
        }
    }

    /// Weckt einmal, wenn sich ohne neues Ereignis etwas ändern kann: Eine verfügbare Quelle
    /// läuft ab, oder die Wechselsperre gibt einen zurückgehaltenen Wechsel frei. Ein
    /// früherer, noch ausstehender Termin bleibt stehen; wacht er zu früh auf, prüft er nur
    /// und plant neu.
    private func scheduleLightExpiry(at: ContinuousClock.Instant, held: Bool) {
        // Knapp nach der Grenze, denn genau auf ihr gilt die Quelle noch.
        let margin: Duration = .milliseconds(10)
        var deadlines: [ContinuousClock.Instant] = []
        if isDeskSensorLightAvailable, let lastEventAt {
            deadlines.append(lastEventAt + LightSourceSelector.deskSensorMaxAge + margin)
        }
        if isBuiltInLightAvailable, let builtInLuxAt {
            deadlines.append(builtInLuxAt + LightSourceSelector.builtInMaxAge + margin)
        }
        if held, let lightSwitchedAt {
            deadlines.append(lightSwitchedAt + LightSourceSelector.minimumHold)
        }
        guard let next = deadlines.min() else {
            lightExpiry?.cancel()
            lightExpiry = nil
            lightExpiryDeadline = nil
            return
        }
        if lightExpiry != nil, let lightExpiryDeadline, lightExpiryDeadline > at, lightExpiryDeadline <= next { return }
        lightExpiry?.cancel()
        lightExpiryDeadline = next
        lightExpiry = Task { [weak self] in
            try? await Task.sleep(for: next - at)
            guard !Task.isCancelled, let self else { return }
            self.lightExpiry = nil
            self.lightExpiryDeadline = nil
            self.updateActiveLight()
        }
    }

    // MARK: - Protokoll

    /// Protokoll der Sensor-Diagnose; nur, solange sie offen ist.
    private func record(_ origin: SensorOrigin, _ event: SensorEvent, blankedBefore: Bool, applied: [LightLevel]) {
        let effect: SensorDebugEntry.Effect? = if !applied.isEmpty {
            .brightness(applied)
        } else if manager.screensBlanked != blankedBefore {
            manager.screensBlanked ? .screensOff : .screensOn
        } else {
            nil
        }
        appendDebug(.event(origin, event), effect: effect)
    }

    private func appendDebug(_ kind: SensorDebugEntry.Kind, effect: SensorDebugEntry.Effect?) {
        guard isDebugMonitoring else { return }
        // Ein gezogener Regler meldet viele manuelle Aufträge: nur den letzten behalten.
        if case .brightnessJob(let job) = kind, job.reason == .manual, let last = debugLog.last?.job,
           last.reason == .manual, last.storageKey == job.storageKey {
            debugLog[debugLog.count - 1] = SensorDebugEntry(
                id: debugLog[debugLog.count - 1].id, date: Date(), kind: kind, effect: effect
            )
            return
        }
        nextDebugID += 1
        debugLog.append(SensorDebugEntry(id: nextDebugID, date: Date(), kind: kind, effect: effect))
        if debugLog.count > Self.debugLogLimit {
            debugLog.removeFirst(debugLog.count - Self.debugLogLimit)
        }
    }

    // MARK: - Eingebauter Lichtsensor

    /// Läuft, solange er aktiv oder Rückfall sein kann (ohne Demo) oder die Sensor-Diagnose
    /// offen ist. Ein eigenes Abfragen gibt es nicht; die Werte kommen im Takt des Sensors.
    private func restartBuiltInLight() {
        defer { updateActiveLight() }
        builtInLightTask?.cancel()
        builtInLightTask = nil
        builtInLux = nil
        builtInFilteredLux = nil
        builtInFilter.reset()
        builtInLuxAt = nil
        builtInLastEventDate = nil
        if lightBrightnessOrigin == .builtIn {
            lightLevels = []
            lightBrightnessOrigin = nil
        }
        guard readsBuiltInLight, let sensor = builtInLightSensor else { return }
        builtInLightTask = Task { [weak self] in
            for await event in sensor.events() {
                guard !Task.isCancelled, let self else { return }
                self.handleBuiltInLight(event)
            }
        }
    }

    func handleBuiltInLight(_ event: SensorEvent) {
        var applied: [LightLevel] = []
        defer { record(.builtIn, event, blankedBefore: manager.screensBlanked, applied: applied) }
        builtInLastEventDate = Date()
        guard case .lux(let value) = event else { return }
        // Bei zugeklapptem Deckel meldet der Sensor Dunkelheit und würde die Monitore
        // abdunkeln. Ist er wieder offen, gilt der nächste Wert.
        guard !isBuiltInLightSensorCovered else {
            builtInLux = nil
            builtInFilteredLux = nil
            builtInFilter.reset()
            builtInLuxAt = nil
            updateActiveLight()
            return
        }
        builtInLux = value
        builtInLuxAt = now()
        // Auch in Bereitschaft filtern: Springt der Sensor ein, ist sein Mittel schon da.
        let filtered = builtInFilter.add(value, at: now())
        builtInFilteredLux = filtered
        updateActiveLight(trigger: .builtIn)
        // Sonst nur Diagnose oder Rückfall in Bereitschaft: anzeigen, nicht regeln.
        if activeLightOrigin == .builtIn {
            applied = applyAmbientLight(filtered, from: .builtIn, reason: .lux(raw: value, filtered: filtered, origin: .builtIn))
        }
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
        if typed {
            // Im offenen Kopplungsfenster nimmt der Sensor jedes Passwort an; dann muss ein
            // eingetippter Code dem angezeigten gleichen. Ist der gerade nicht zu holen, wird
            // nichts gespeichert: Der Digest-Login bewiese im Fenster nichts.
            let shownResponse = await http.get(sensor.endpoint.url(SensorProtocol.pairingPath), password: nil)
            guard !Task.isCancelled else { return }
            switch shownResponse {
            case .ok(let data):
                guard let shown = PairingCode.fromPairingResponse(data) else {
                    pairing = .failed(sensor, .unreachable)
                    return
                }
                if shown != code {
                    pairing = .failed(sensor, .wrongCode)
                    return
                }
            case .unauthorized:
                break // Fenster zu: Der Digest-Login prüft den Code wirklich.
            case .timeout:
                pairing = .failed(sensor, .timeout)
                return
            case .unreachable, .status:
                pairing = .failed(sensor, .unreachable)
                return
            }
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
