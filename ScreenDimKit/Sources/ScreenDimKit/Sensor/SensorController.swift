import AppKit
import CoreGraphics
import Foundation
import Observation

/// Verbindet den optionalen Schreibtisch-Sensor (oder die Simulation) mit dem
/// `DisplayManager`: Abwesenheit dunkelt die Bildschirme ab und schaltet sie nach einer
/// Weile aus (`AbsenceStage`, abschaltbar mit `reactsToAbsence`), Umgebungslicht regelt
/// die Helligkeit (`LightSource`). Ohne Sensor passiert nichts; Standard ist „aus“. Im
/// manuellen Modus (`isManualMode`, Umschalter im Menü) ruht beides.
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

    /// Ob das Umgebungslicht die Helligkeit regelt. Es kommt vom Schreibtisch-Sensor oder,
    /// im Demo-Modus, aus der Simulation. Ältere gespeicherte Wahlen mit dem früheren
    /// eingebauten Lichtsensor werden zu `deskSensorOnly` (`init(storedValue:)`).
    public enum LightSource: String, CaseIterable, Sendable {
        /// Standard.
        case deskSensorOnly
        case off
    }

    /// Stand des letzten Schreibens einer Einstellung in den Sensor („Max Distance“).
    public enum SettingWrite: Equatable, Sendable {
        case idle
        /// Wartet auf weitere Änderungen (Stepper) oder auf die Antwort des Sensors.
        case saving
        /// Nicht gespeichert; im Sensor gilt der bisherige Wert.
        case failed(SettingWriteFailure)
    }

    public enum SettingWriteFailure: Equatable, Sendable {
        /// Der Sensor lehnt den Code ab (401).
        case unauthorized
        /// Die Firmware kennt die Einstellung nicht (404, ältere Firmware).
        case unsupported
        /// Keine Antwort, Zeitüberschreitung oder anderer HTTP-Status.
        case unreachable
    }

    /// Wie weit die Abwesenheit die Bildschirme zurückgenommen hat.
    public enum AbsenceStage: Equatable, Sendable {
        /// Niemand weg, oder Eingabe hat gewonnen.
        case none
        /// Ausgabe auf `absenceLevel` gedeckelt; nach `absenceOffDelay` folgt `off`.
        case dimmed
        /// Displays im Ruhezustand von macOS. Ist ein Monitor ignoriert (Beamer), schlafen
        /// sie nicht; dann sind die übrigen schwarz.
        case off

        public var logName: String {
            switch self {
            case .none: "an"
            case .dimmed: "abgedunkelt"
            case .off: "aus"
            }
        }
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
        /// „Bei Abwesenheit reagieren“; fehlt der Eintrag, gilt an.
        static let reactsToAbsence = "sensorReactsToAbsence"
        static let manualMode = "sensorManualMode"
        static let absenceLevel = "sensorAbsenceLevel"
        /// Sekunden bis zum Ausschalten; negativ: nie.
        static let absenceOffDelay = "sensorAbsenceOffDelay"
        /// Startargument `-ScreenDimDemo YES`; wird nie geschrieben.
        static let demo = "ScreenDimDemo"
    }

    public static let codePollInterval: Duration = .seconds(2)
    public static let pairingWindow: Duration = .seconds(180)
    /// Mindestabstand in Prozentpunkten zwischen neuem Ziel und dem Wert, auf den der
    /// Monitor gerade zugeht, bevor Licht ihn verstellt. Hält DDC-Writes selten.
    public static let lightHysteresis: Double = 3
    /// Nach Regler oder Tastenkürzel ruht die Lichtregelung dieses Monitors so lange, bis
    /// sich das Licht um mehr als `manualHoldLuxFactor` ändert oder bis zum nächsten Wechsel
    /// der Anwesenheit (`resumeLightProfiles`).
    public static let manualHold: Duration = .seconds(300)
    nonisolated public static let manualHoldLuxFactor: Double = 2
    /// Nach einer fremden Änderung (macOS, Helligkeitstasten) ruht die Lichtregelung dieses
    /// Displays so lange.
    public static let externalChangeHold: Duration = .seconds(60)
    /// So lange gilt der gelesene Zustand der Auto-Helligkeit; danach liest der nächste
    /// Lichtwert neu. Wird die App aktiv (etwa die Einstellungen geöffnet), liest sie sofort.
    public static let autoBrightnessMaxAge: Duration = .seconds(10)
    /// Gültige Lux-Werte. Direkte Sonne bringt etwa 100 000 lx; alles außerhalb ist ein
    /// Messfehler und wird verworfen.
    nonisolated public static let luxRange: ClosedRange<Double> = 0...200_000
    /// So viele Einträge behält das Protokoll der Sensor-Diagnose.
    public static let debugLogLimit = 200
    /// Wählbare Zeiten bis zum Ausschalten in Sekunden; `nil`: nie.
    public static let absenceOffChoices: [Int?] = [nil, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 2700, 3600]
    /// Kürzeste Zeit bis zum Ausschalten. Ein „sofort“ gibt es nicht mehr: Eine einzelne
    /// Fehlmeldung des Radars schickte sonst alle Displays schlafen. Ältere gespeicherte
    /// Werte darunter (0: „sofort“) werden darauf angehoben.
    public static let minimumAbsenceOffDelay: Duration = .seconds(30)
    public static let defaultAbsenceOffDelay: Duration? = .seconds(5 * 60)
    public static let absenceLevelRange: ClosedRange<Double> = 0...50
    public static let defaultAbsenceLevel: Double = 5
    /// So lange sammelt `setMaxDistance` Änderungen, bevor es schreibt: Klicks auf den
    /// Stepper gehen als ein Write raus.
    public static let settingWriteDelay: Duration = .milliseconds(500)

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
    public private(set) var lightSource: LightSource
    /// Quelle, deren Licht gerade die Helligkeit regelt; `nil`, wenn keine.
    public private(set) var activeLightOrigin: SensorOrigin?
    /// Verfügbarkeit nach `LightSourceSelector`, Stand der letzten Prüfung.
    public private(set) var isDeskSensorLightAvailable = false
    /// Zeit des letzten Ereignisses vom Schreibtisch-Sensor bzw. der Demo.
    public private(set) var lastEventDate: Date?
    /// „Max Distance“ des verbundenen Sensors (cm): Bis dahin zählt jemand als anwesend.
    /// `nil` ohne Verbindung, in der Demo und bei Firmware ohne die Einstellung.
    public private(set) var maxDistance: SensorNumber?
    /// Entfernung der Person laut Radar (cm); `nil`, wenn es niemanden sieht oder ohne
    /// Verbindung. Hilft beim Wählen von `maxDistance`.
    public private(set) var distance: Double?
    public private(set) var maxDistanceWrite: SettingWrite = .idle
    /// Letzte Helligkeit aus dem Licht je angeschlossenem Monitor und woher das Licht kam.
    public private(set) var lightLevels: [LightLevel] = []
    public private(set) var lightBrightnessOrigin: SensorOrigin?
    /// Geänderte Lichtprofile dieser Sitzung; die übrigen liegen in `profileStore`.
    private var lightProfiles: [String: LightProfile] = [:]
    /// Aus dem Speicher gelesene Profile, damit nicht jeder Zugriff dekodiert. Nicht
    /// beobachtet: Das Füllen beim Lesen darf kein Neurendern auslösen.
    @ObservationIgnored private var loadedProfiles: [String: LightProfile] = [:]
    /// Sensor-Diagnose offen: Ereignisse werden protokolliert.
    public private(set) var isDebugMonitoring = false
    public private(set) var debugLog: [SensorDebugEntry] = []
    public private(set) var absenceStage: AbsenceStage = .none
    /// „Bei Abwesenheit reagieren“: Aus, schaltet die Anwesenheit nichts, weder abdunkeln
    /// und ausschalten noch wecken. Licht und Anzeige laufen weiter. Standard an.
    public private(set) var reactsToAbsence: Bool
    /// „Manuell“ (Umschalter im Menü): Weder Licht noch Anwesenheit verstellen etwas, der
    /// Wert von Regler oder Tasten bleibt dauerhaft; nichts dunkelt ab, schaltet aus oder
    /// weckt. Die Einstellungen bleiben, wie sie sind. Gespeichert; Standard automatisch.
    public private(set) var isManualMode: Bool
    /// Höchste Helligkeit in Prozent, solange niemand da ist.
    public private(set) var absenceLevel: Double
    /// Wie lange abgedunkelt bleibt, bevor die Displays schlafen; `nil`: nie, sonst
    /// mindestens `minimumAbsenceOffDelay`.
    public private(set) var absenceOffDelay: Duration?

    /// Für die Auswahl in den Einstellungen; `nil`: nie.
    public var absenceOffSeconds: Int? {
        absenceOffDelay.map { Int($0.components.seconds) }
    }

    /// Der Sensor meldet wieder jemanden, nachdem er „weg“ gemeldet hatte. Die App gibt das
    /// an die Leerlauf-Dimmung weiter (`IdleDimmer.noteActivity`).
    @ObservationIgnored public var onArrival: (@MainActor () -> Void)?

    /// Quelle, deren Anwesenheit gerade die Bildschirme schaltet; `nil`, wenn keine (auch
    /// wenn „Bei Abwesenheit reagieren“ aus ist).
    public var activePresenceOrigin: SensorOrigin? {
        guard reactsToPresence else { return nil }
        if isDemoActive { return .demo }
        return status == .connected ? .deskSensor : nil
    }

    /// Ob die Anwesenheit etwas schaltet: „Bei Abwesenheit reagieren“ an und nicht manuell.
    private var reactsToPresence: Bool {
        reactsToAbsence && !isManualMode
    }

    @ObservationIgnored private let manager: DisplayManager
    @ObservationIgnored private let preferences: any PreferenceStorage
    @ObservationIgnored private let credentials: any SensorCredentialStore
    @ObservationIgnored private let profileStore: LightProfileStore
    @ObservationIgnored private let http: any SensorHTTP
    @ObservationIgnored private let input: any InputActivityMonitoring
    @ObservationIgnored private let makeLiveSource: @MainActor (SensorEndpoint, PairingCode) -> any SensorSource
    @ObservationIgnored private let makeSimulation: @MainActor (SimulationSchedule) -> SimulatedSensorSource
    @ObservationIgnored private let readAutoBrightness: @MainActor () -> Bool?
    @ObservationIgnored private var autoBrightnessReadAt: ContinuousClock.Instant?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let displaySleep: any DisplaySleeping
    @ObservationIgnored private let notificationCenter: NotificationCenter
    /// Warten bis zum Ausschalten und nach dem Aufwachen. In Tests ersetzbar.
    @ObservationIgnored private let wait: @Sendable (Duration) async -> Void
    @ObservationIgnored private var screenObservers: [any NSObjectProtocol] = []

    @ObservationIgnored private var simulation: SimulatedSensorSource?
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    /// Adresse und Code der laufenden echten Quelle, für Writes an den Sensor.
    @ObservationIgnored private var liveEndpoint: SensorEndpoint?
    @ObservationIgnored private var liveCode: PairingCode?
    /// Entprellen und Schreiben von „Max Distance“; ein neuer Wert ersetzt den alten.
    @ObservationIgnored private var maxDistanceTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Warten bis zum Ausschalten oder, nach dem Aufwachen, bis die Helligkeit zurückkommt.
    @ObservationIgnored private var absenceTask: Task<Void, Never>?
    @ObservationIgnored private var absentSince: ContinuousClock.Instant?
    /// Laut `NSWorkspace`; dann keine DDC-Writes, die Helligkeit kommt nach dem Aufwachen.
    @ObservationIgnored private var displaysAsleep = false
    /// Wann die Displays zuletzt aufgewacht sind; für die Schonfrist danach.
    @ObservationIgnored private var displaysWokeAt: ContinuousClock.Instant?
    /// Ein Ereignis wird gerade verarbeitet: Ändert es die Stufe, steht das als Wirkung an
    /// seinem Eintrag im Protokoll, nicht als eigener Eintrag.
    @ObservationIgnored private var handlingEvent = false
    @ObservationIgnored private var connection: SensorConnection?
    @ObservationIgnored private var lastEventAt: ContinuousClock.Instant?
    @ObservationIgnored private var deskFilter = LuxFilter(.deskSensor)
    /// Pausen der Lichtregelung je Monitor (`storageKey`).
    @ObservationIgnored private var holds: [String: LightHold] = [:]
    /// Die Anwesenheit hat gewechselt, das Lichtprofil gilt wieder, ist aber noch nicht
    /// gesetzt: Abwesenheit oder schlafende Displays schieben es auf (`applyLightProfilesIfDue`).
    @ObservationIgnored private var lightProfilesDue = false
    /// Monitore, die beim letzten Setzen noch in der DDC-Prüfung waren und den Wert nicht
    /// übernommen haben; der nächste Lux-Wert holt ihn nach, auch innerhalb der Hysterese.
    @ObservationIgnored private var pendingLight: Set<String> = []
    /// Ein einzelner Schlaf bis zu dem Zeitpunkt, an dem der Schreibtisch-Sensor als
    /// Lichtquelle abläuft.
    @ObservationIgnored private var lightExpiry: Task<Void, Never>?
    @ObservationIgnored private(set) var lightExpiryDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var nextDebugID = 0

    /// - Parameter isAutoBrightnessEnabled: ob macOS das eingebaute Display selbst regelt
    ///   („Helligkeit automatisch anpassen“); `nil`, wenn unbekannt (keine Fabrik).
    public convenience init(
        manager: DisplayManager,
        isAutoBrightnessEnabled: @escaping @MainActor () -> Bool? = { nil }
    ) {
        self.init(
            manager: manager,
            preferences: UserDefaults.standard,
            credentials: SensorKeychain(),
            http: URLSessionSensorHTTP(),
            input: SystemInputActivity(),
            displaySleep: SystemDisplaySleep(),
            notificationCenter: NSWorkspace.shared.notificationCenter,
            demoAtLaunch: UserDefaults.standard.bool(forKey: Keys.demo),
            makeLiveSource: { SSESensorSource(endpoint: $0, code: $1) },
            makeSimulation: { SimulatedSensorSource(schedule: $0) },
            isAutoBrightnessEnabled: isAutoBrightnessEnabled
        )
    }

    init(
        manager: DisplayManager,
        preferences: any PreferenceStorage,
        credentials: any SensorCredentialStore,
        http: any SensorHTTP,
        input: any InputActivityMonitoring,
        displaySleep: any DisplaySleeping,
        notificationCenter: NotificationCenter = NotificationCenter(),
        wait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        demoAtLaunch: Bool,
        makeLiveSource: @escaping @MainActor (SensorEndpoint, PairingCode) -> any SensorSource,
        makeSimulation: @escaping @MainActor (SimulationSchedule) -> SimulatedSensorSource,
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
        self.displaySleep = displaySleep
        self.notificationCenter = notificationCenter
        self.wait = wait
        readAutoBrightness = isAutoBrightnessEnabled
        isEnabled = preferences.object(forKey: Keys.enabled) as? Bool ?? false
        let storedLightSource = preferences.string(forKey: Keys.lightSource)
        if let storedLightSource, let source = LightSource(storedValue: storedLightSource) {
            lightSource = source
            // Ältere Wahl mit dem eingebauten Lichtsensor: einmal umschreiben.
            if source.rawValue != storedLightSource { preferences.set(source.rawValue, forKey: Keys.lightSource) }
        } else {
            lightSource = (preferences.object(forKey: Keys.adjustsBrightness) as? Bool ?? true) ? .deskSensorOnly : .off
        }
        pairedHostname = preferences.string(forKey: Keys.hostname)
        reactsToAbsence = preferences.object(forKey: Keys.reactsToAbsence) as? Bool ?? true
        isManualMode = preferences.object(forKey: Keys.manualMode) as? Bool ?? false
        absenceLevel = (preferences.object(forKey: Keys.absenceLevel) as? Double).map(Self.clampAbsenceLevel)
            ?? Self.defaultAbsenceLevel
        if let seconds = preferences.object(forKey: Keys.absenceOffDelay) as? Double {
            if seconds < 0 {
                absenceOffDelay = nil
            } else {
                let delay = Self.clampAbsenceOffDelay(.seconds(seconds))
                absenceOffDelay = delay
                // Altwert „sofort“ (0) oder kürzer als erlaubt: angehoben speichern.
                if delay != .seconds(seconds) { preferences.set(Double(delay.components.seconds), forKey: Keys.absenceOffDelay) }
            }
        } else {
            absenceOffDelay = Self.defaultAbsenceOffDelay
        }
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
        screenObservers = [
            notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensDidSleep() }
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensDidWake() }
            },
        ]
        restartSource()
    }

    public func stop() {
        activationObserver.map(NotificationCenter.default.removeObserver)
        activationObserver = nil
        screenObservers.forEach(notificationCenter.removeObserver)
        screenObservers = []
        pairingTask?.cancel()
        sourceTask?.cancel()
        sourceTask = nil
        lightExpiry?.cancel()
        lightExpiry = nil
        lightExpiryDeadline = nil
        endAbsence()
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

    /// Aus: Eine laufende Abwesenheit endet, und die Anwesenheit schaltet nichts mehr.
    /// Wieder an, gilt erst die nächste Meldung „abwesend“.
    public func setReactsToAbsence(_ reacts: Bool) {
        guard reacts != reactsToAbsence else { return }
        reactsToAbsence = reacts
        preferences.set(reacts, forKey: Keys.reactsToAbsence)
        sensorLog.notice("Bei Abwesenheit reagieren: \(reacts ? "an" : "aus", privacy: .public)")
        if !reacts { returnFromAbsence(wake: false) }
    }

    /// Manuell: Eine laufende Abwesenheit endet, Licht und Anwesenheit verstellen nichts
    /// mehr; die Helligkeit bleibt, wo sie ist. Zurück auf automatisch: Jeder Monitor geht
    /// sofort auf sein Lichtprofil, Pausen vom Regler enden; bei der Anwesenheit gilt erst
    /// der nächste Wechsel.
    public func setManualMode(_ manual: Bool) {
        guard manual != isManualMode else { return }
        isManualMode = manual
        preferences.set(manual, forKey: Keys.manualMode)
        sensorLog.notice("Modus: \(manual ? "manuell" : "automatisch", privacy: .public)")
        if manual {
            lightProfilesDue = false
            returnFromAbsence(wake: false)
        } else {
            holds = [:]
            lightProfilesDue = true
            applyLightProfilesIfDue()
        }
    }

    /// Gilt ab der nächsten Abwesenheit.
    public func setAbsenceLevel(_ level: Double) {
        let level = Self.clampAbsenceLevel(level)
        guard level != absenceLevel else { return }
        absenceLevel = level
        preferences.set(level, forKey: Keys.absenceLevel)
    }

    /// `nil`: nie ausschalten; sonst mindestens `minimumAbsenceOffDelay`. Während
    /// abgedunkelt ist, zählt die neue Zeit ab dem Beginn der Abwesenheit.
    public func setAbsenceOffDelay(_ delay: Duration?) {
        let delay = delay.map(Self.clampAbsenceOffDelay)
        guard delay != absenceOffDelay else { return }
        absenceOffDelay = delay
        // Ausdrücklich `Double`: Im Kontext `Any?` würde aus `-1` sonst ein `Int`.
        let seconds: Double = delay.map { Double($0.components.seconds) } ?? -1
        preferences.set(seconds, forKey: Keys.absenceOffDelay)
        if absenceStage == .dimmed { scheduleOff() }
    }

    private static func clampAbsenceLevel(_ level: Double) -> Double {
        min(max(level.rounded(), absenceLevelRange.lowerBound), absenceLevelRange.upperBound)
    }

    private static func clampAbsenceOffDelay(_ delay: Duration) -> Duration {
        max(delay, minimumAbsenceOffDelay)
    }

    public func setLightSource(_ source: LightSource) {
        guard source != lightSource else { return }
        lightSource = source
        preferences.set(source.rawValue, forKey: Keys.lightSource)
        updateActiveLight()
    }

    /// Sensor-Diagnose geöffnet bzw. geschlossen. Beim Schließen wird das Protokoll gelöscht.
    public func setDebugMonitoring(_ monitoring: Bool) {
        guard monitoring != isDebugMonitoring else { return }
        isDebugMonitoring = monitoring
        if !monitoring { debugLog.removeAll() }
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
        lightLevels = []
        lightBrightnessOrigin = nil
        liveEndpoint = nil
        liveCode = nil
        resetSensorSettings()
        returnFromAbsence(wake: false)

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
            let endpoint = SensorEndpoint(hostname: host)
            source = makeLiveSource(endpoint, code)
            liveEndpoint = endpoint
            liveCode = code
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
        if case .lux(let value) = event, !Self.luxRange.contains(value) {
            // Auch NaN landet hier. Kein Lebenszeichen: Ein kaputter Messwert hält den
            // Sensor nicht als Lichtquelle am Leben.
            sensorLog.notice("Lux \(value, privacy: .public) außerhalb 0…200000 lx, verworfen")
            return
        }
        let origin: SensorOrigin = isDemoActive ? .demo : .deskSensor
        let stageBefore = absenceStage
        var applied: [LightLevel] = []
        handlingEvent = true
        defer {
            handlingEvent = false
            record(origin, event, stageBefore: stageBefore, applied: applied)
        }
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
                // Getrennt: Normalzustand, nichts mehr ausschalten. Schlafende Displays weckt
                // erst eine Eingabe.
                lastEventAt = nil
                presence = nil
                resetSensorSettings()
                returnFromAbsence(wake: false)
                updateActiveLight()
                return
            }
            lastEventAt = now()
            updateActiveLight()
        case .presence(let present):
            lastEventAt = now()
            let previous = presence
            presence = present
            // Abgeschaltet oder manuell: anzeigen, sonst nichts.
            guard reactsToPresence else { break }
            // Jeder Wechsel, nicht die erste Meldung nach dem Verbinden: Das Lichtprofil geht
            // wieder vor einem Wert von Hand.
            if let previous, previous != present { resumeLightProfiles(arriving: present) }
            if present {
                // Annäherung weckt schlafende Displays immer, auch ohne Abwesenheit von
                // ScreenDim (etwa nach „Eingabe gewinnt“, oder macOS hat ausgeschaltet).
                // Nur beim Wechsel von „abwesend“, nicht bei der ersten Meldung nach dem
                // Verbinden.
                let wakesWithoutAbsence = previous == false && displaysAsleep && absenceStage == .none
                returnFromAbsence(wake: true)
                if wakesWithoutAbsence { displaySleep.wakeDisplays() }
                if previous == false { onArrival?() }
            } else if previous != present, PresenceGate.startsAbsence(
                presence: present,
                connected: connection == .connected,
                sinceLastInput: input.timeSinceLastInput
            ) {
                beginAbsence()
            }
            // Ohne Abwesenheit sofort; sonst setzt es `endAbsence`.
            applied = applyLightProfilesIfDue()
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
        case .maxDistance(let number):
            lastEventAt = now()
            // Nach dem Verbinden kommen Bereich und Schritt mit, danach nur der Wert.
            let merged = SensorNumber(
                value: number.value,
                range: number.range ?? maxDistance?.range,
                step: number.step ?? maxDistance?.step
            )
            if maxDistance != merged { maxDistance = merged }
        case .distance(let cm):
            lastEventAt = now()
            if distance != cm { distance = cm }
        }
    }

    // MARK: - Einstellungen im Sensor

    /// Setzt „Max Distance“ im Sensor (cm), gerundet auf den Schritt und begrenzt auf den
    /// Bereich der Firmware. Geschrieben wird erst nach `settingWriteDelay` ohne weitere
    /// Änderung, es gilt der letzte Wert. Den neuen Wert meldet der Sensor über den
    /// SSE-Strom zurück. Nur mit verbundenem echtem Sensor, der den Wert gemeldet hat.
    public func setMaxDistance(_ cm: Double) {
        guard status == .connected, let current = maxDistance, let endpoint = liveEndpoint, let code = liveCode,
              cm.isFinite
        else { return }
        let value = Self.normalize(
            cm,
            range: current.range ?? SensorProtocol.maxDistanceRange,
            step: current.step ?? SensorProtocol.maxDistanceStep
        )
        // Wartet oder läuft schon ein Write, geht auch der bisherige Wert noch einmal raus:
        // Ein laufender könnte schon angekommen sein.
        let busy = maxDistanceTask != nil
        maxDistanceTask?.cancel()
        maxDistanceTask = nil
        guard value != current.value || busy else {
            if maxDistanceWrite != .idle { maxDistanceWrite = .idle }
            return
        }
        maxDistanceWrite = .saving
        let url = endpoint.url(
            SensorProtocol.setPath(SensorProtocol.maxDistancePath),
            query: [URLQueryItem(name: "value", value: value == value.rounded() ? String(Int(value)) : String(value))]
        )
        let http = http
        let wait = wait
        maxDistanceTask = Task { [weak self] in
            await wait(Self.settingWriteDelay)
            guard !Task.isCancelled else { return }
            let response = await http.post(url, password: code.raw)
            guard !Task.isCancelled, let self else { return }
            self.maxDistanceTask = nil
            switch response {
            case .ok:
                sensorLog.notice("Sensor \(endpoint.hostname, privacy: .public): Max Distance \(Int(value)) cm")
                self.maxDistanceWrite = .idle
            case .unauthorized:
                sensorLog.notice("Sensor \(endpoint.hostname, privacy: .public): Max Distance abgelehnt (401)")
                self.maxDistanceWrite = .failed(.unauthorized)
            case .status(404):
                sensorLog.notice("Sensor \(endpoint.hostname, privacy: .public): Max Distance unbekannt (404)")
                self.maxDistanceWrite = .failed(.unsupported)
            case .status(let status):
                sensorLog.notice("Sensor \(endpoint.hostname, privacy: .public): Max Distance, HTTP \(status)")
                self.maxDistanceWrite = .failed(.unreachable)
            case .timeout, .unreachable:
                sensorLog.notice("Sensor \(endpoint.hostname, privacy: .public): Max Distance nicht gesendet, nicht erreichbar")
                self.maxDistanceWrite = .failed(.unreachable)
            }
        }
    }

    /// Auf den Schritt ab der Untergrenze gerundet, dann in den Bereich. So schreibt
    /// `setMaxDistance`; die Einstellungen zeigen damit gleich den Wert, der rausgeht.
    nonisolated public static func normalize(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let stepped = step > 0 ? range.lowerBound + ((value - range.lowerBound) / step).rounded() * step : value.rounded()
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// Ohne Verbindung gibt es nichts einzustellen; ein offener Write verfällt.
    private func resetSensorSettings() {
        maxDistanceTask?.cancel()
        maxDistanceTask = nil
        if maxDistance != nil { maxDistance = nil }
        if distance != nil { distance = nil }
        if maxDistanceWrite != .idle { maxDistanceWrite = .idle }
    }

    private var lastEventAge: Duration? {
        lastEventAt.map { now() - $0 }
    }

    /// Jeder Monitor folgt seinem eigenen Lichtprofil, gleich aus welcher Quelle das Licht
    /// kommt. Ausgelassen werden ignorierte Monitore, Monitore ohne „folgt dem Licht“, in
    /// einer Pause (Regler, fremde Änderung) und das eingebaute Display, solange macOS es
    /// selbst regelt: Es gibt nur einen Schreiber. Die Hysterese gilt gegen den Wert, auf den der Monitor gerade
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
        // Niemand da: Die Ausgabe ist gedeckelt oder die Displays schlafen. Zurück gilt der
        // nächste Wert. Manuell: Der Wert vom Regler bleibt.
        guard absenceStage == .none, !isManualMode else { return [] }
        let at = now()
        var applied: [LightLevel] = []
        for monitor in manager.monitors {
            let key = monitor.storageKey
            let profile = lightProfile(for: monitor)
            guard only == nil || only == key, !monitor.isIgnored, profile.followsLight, !macOSRegulates(monitor) else { continue }
            if let hold = holds[key] {
                if hold.isActive(at: at, lux: lux) { continue }
                holds[key] = nil
            }
            let target = profile.curve.percent(forLux: lux)
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
        /// Begann, während der Sensor „abwesend“ meldete: Wer den Wert setzte, war schon da.
        /// Die folgende Meldung „anwesend“ beendet die Pause deshalb nicht.
        var beganWhileAbsent = false

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
            holds[job.storageKey] = LightHold(until: now() + Self.manualHold, lux: activeLux, beganWhileAbsent: presence == false)
            pendingLight.remove(job.storageKey)
            // Wer am Regler zieht, ist da. Den Deckel hat `setBrightness` schon aufgehoben.
            if absenceStage != .none { returnFromAbsence(wake: false) }
        case .externalChange:
            holds[job.storageKey] = LightHold(until: now() + Self.externalChangeHold, lux: nil, beganWhileAbsent: presence == false)
        default:
            break
        }
        appendDebug(.brightnessJob(job), effect: nil)
    }

    /// Nach der Prüfung: Licht, das währenddessen kam, gilt jetzt.
    private func monitorReady(_ id: CGDirectDisplayID) {
        guard let monitor = manager.monitors.first(where: { $0.id == id }), pendingLight.contains(monitor.storageKey),
              let origin = activeLightOrigin, let lux = activeLux
        else { return }
        applyAmbientLight(lux, from: origin, reason: .pendingAfterProbe, only: monitor.storageKey, ignoresHysteresis: true)
    }

    /// Die Anwesenheit wechselt: Die Lichtprofile gehen wieder vor einem Wert von Regler oder
    /// Tasten, ihre Pausen enden. Nur eine Pause, die während „abwesend“ begann, übersteht
    /// die folgende Rückkehr: Der Sensor meldet dann nur verspätet, wer schon am Regler war.
    /// Gesetzt wird beim nächsten `applyLightProfilesIfDue`.
    private func resumeLightProfiles(arriving: Bool) {
        if arriving {
            holds = holds.filter(\.value.beganWhileAbsent).mapValues { LightHold(until: $0.until, lux: $0.lux) }
        } else {
            holds = [:]
        }
        lightProfilesDue = true
    }

    /// Setzt nach einem Wechsel der Anwesenheit jeden Monitor auf sein Lichtprofil, genau,
    /// ohne Hysterese. Wartet, solange die Ausgabe gedeckelt ist (dann vor dem Aufheben des
    /// Deckels, siehe `endAbsence`) oder die Displays schlafen (dann nach dem Aufwachen).
    /// Ohne Licht bleibt es bei den beendeten Pausen; der nächste Lux-Wert regelt.
    @discardableResult
    private func applyLightProfilesIfDue() -> [LightLevel] {
        guard lightProfilesDue, absenceStage == .none, !displaysAsleep else { return [] }
        lightProfilesDue = false
        guard let origin = activeLightOrigin, let lux = activeLux else { return [] }
        return applyAmbientLight(lux, from: origin, reason: .presenceChange, ignoresHysteresis: true)
    }

    // MARK: - Lichtprofile

    /// Geglättetes Lux der aktiven Lichtquelle, so wie es in die Kurven eingeht; `nil` ohne
    /// Quelle. Schreibtisch-Sensor und Demo teilen sich den Wert.
    public var activeLux: Double? {
        activeLightOrigin == nil ? nil : filteredLux
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
        if let origin = activeLightOrigin, let lux = activeLux {
            applyAmbientLight(lux, from: origin, reason: .profileChange, only: key, ignoresHysteresis: true)
        }
    }

    // MARK: - Auswahl der Lichtquelle

    /// Prüft, ob Licht kommt, und wechselt bei Bedarf. Läuft nach jedem Ereignis, jeder
    /// Einstellung und einmal, wenn der Schreibtisch-Sensor als Quelle abläuft.
    /// - Parameter trigger: Quelle, deren Lux gerade ankommt. Wird sie aktiv, setzt der
    ///   Aufrufer ihren Wert; sonst gilt der letzte Wert sofort.
    func updateActiveLight(trigger: SensorOrigin? = nil) {
        let at = now()
        let deskAvailable = LightSourceSelector.isDeskSensorAvailable(
            connected: status == .connected,
            eventAge: lux == nil ? nil : lastEventAt.map { at - $0 }
        )
        // Läuft nach jedem Ereignis (auch Pings); beobachtete Werte nur bei Änderung setzen.
        if isDeskSensorLightAvailable != deskAvailable { isDeskSensorLightAvailable = deskAvailable }
        let selected = LightSourceSelector.select(choice: lightSource, demo: isDemoActive, deskAvailable: deskAvailable)
        if selected != activeLightOrigin {
            let previous = activeLightOrigin
            activeLightOrigin = selected
            // Die Hysterese bleibt: Der letzte geglättete Wert blendet vom aktuellen Stand
            // aus über, nur wenn er deutlich abweicht.
            var applied: [LightLevel] = []
            if let selected, selected != trigger, let value = filteredLux {
                applied = applyAmbientLight(value, from: selected, reason: .sourceSwitch(from: previous, to: selected))
            }
            sensorLog.notice(
                "Lichtquelle: \(previous?.rawValue ?? "-", privacy: .public) → \(selected?.rawValue ?? "-", privacy: .public)"
            )
            appendDebug(.lightSourceSwitch(from: previous, to: selected), effect: applied.isEmpty ? nil : .brightness(applied))
        }
        scheduleLightExpiry(at: at)
    }

    /// Weckt einmal, wenn der Schreibtisch-Sensor ohne neues Ereignis abläuft. Ein früherer,
    /// noch ausstehender Termin bleibt stehen; wacht er zu früh auf, prüft er nur und plant
    /// neu.
    private func scheduleLightExpiry(at: ContinuousClock.Instant) {
        // Knapp nach der Grenze, denn genau auf ihr gilt die Quelle noch.
        let margin: Duration = .milliseconds(10)
        guard isDeskSensorLightAvailable, let lastEventAt else {
            lightExpiry?.cancel()
            lightExpiry = nil
            lightExpiryDeadline = nil
            return
        }
        let next = lastEventAt + LightSourceSelector.deskSensorMaxAge + margin
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
    private func record(_ origin: SensorOrigin, _ event: SensorEvent, stageBefore: AbsenceStage, applied: [LightLevel]) {
        // Die Entfernung kommt alle 2 s und schaltet nichts; sie verdrängte das Übrige.
        if case .distance = event { return }
        let effect: SensorDebugEntry.Effect? = if !applied.isEmpty {
            .brightness(applied)
        } else if absenceStage != stageBefore {
            .absence(absenceStage)
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

    // MARK: - Abwesenheit

    /// Der Sensor meldet niemanden: abdunkeln, nach `absenceOffDelay` ausschalten. Eingabe
    /// gewinnt immer; ein veralteter Sensor holt die Bildschirme zurück.
    /// - Parameter restart: Die Displays sind nach einer Abwesenheit wieder aufgewacht, und
    ///   noch immer ist niemand da: von vorn, ohne die Helligkeit dazwischen zurückzuholen.
    private func beginAbsence(restart: Bool = false) {
        guard absenceStage == .none || restart else { return }
        absentSince = now()
        startWatchdog()
        guard !displaysAsleep else {
            // Schon aus (macOS): nichts dimmen; die Rückkehr weckt sie.
            setAbsenceStage(.off)
            return
        }
        // Bis die Displays schlafen; danach weckt macOS sie selbst bei einer Eingabe.
        input.startObserving { [weak self] in self?.returnFromAbsence(wake: false) }
        // Nach dem Aufwachen: Schwarz (ignorierter Monitor) wird wieder zum Deckel.
        manager.setScreensBlanked(false)
        setAbsenceStage(.dimmed)
        manager.beginDim(.absence, to: absenceLevel)
        scheduleOff()
    }

    /// Wartet die Zeit bis zum Ausschalten ab, gezählt ab dem Beginn der Abwesenheit.
    private func scheduleOff() {
        absenceTask?.cancel()
        absenceTask = nil
        guard let delay = absenceOffDelay else { return }
        let remaining = max(delay - (absentSince.map { now() - $0 } ?? .zero), .zero)
        let wait = wait
        absenceTask = Task { [weak self] in
            await wait(remaining)
            guard !Task.isCancelled, let self else { return }
            self.absenceTask = nil
            self.turnScreensOffIfStillAway()
        }
    }

    /// Zeit um. Gab es seitdem eine Eingabe, die der Event-Monitor nicht sieht (Tasten ohne
    /// Bedienungshilfen, Tastenkürzel), oder hat der Regler den Deckel aufgehoben, ist
    /// jemand da: zurück statt aus.
    private func turnScreensOffIfStillAway() {
        guard absenceStage == .dimmed else { return }
        let away = absentSince.map { now() - $0 } ?? .zero
        guard input.timeSinceLastInput >= away, manager.dimCauses.contains(.absence) else {
            sensorLog.notice("Abwesenheit: Eingabe seit dem Abdunkeln, nicht ausschalten")
            returnFromAbsence(wake: false)
            return
        }
        turnScreensOff()
    }

    /// Displays schlafen lassen. Ein ignorierter Monitor (Beamer) muss an bleiben, der
    /// Ruhezustand träfe aber alle; dann werden nur die übrigen schwarz.
    private func turnScreensOff() {
        setAbsenceStage(.off)
        if manager.monitors.contains(where: \.isIgnored) {
            manager.setScreensBlanked(true)
        } else {
            displaySleep.sleepDisplays()
        }
    }

    /// Jemand ist zurück, oder der Sensor taugt nicht mehr als Grund. Schlafen die Displays,
    /// kommt die Helligkeit erst nach ihrem Aufwachen zurück (DDC nimmt vorher nichts an).
    /// - Parameter wake: schlafende Displays wecken (der Sensor meldet jemanden). Sonst weckt
    ///   sie erst eine Eingabe.
    private func returnFromAbsence(wake: Bool) {
        guard absenceStage != .none else {
            endAbsence()
            return
        }
        if displaysAsleep {
            absenceTask?.cancel()
            absenceTask = nil
            watchdog?.cancel()
            watchdog = nil
            input.stopObserving()
            if wake { displaySleep.wakeDisplays() }
            return
        }
        endAbsence()
    }

    /// Normalzustand: kein Deckel, nichts schwarz, nichts wartet.
    private func endAbsence() {
        absenceTask?.cancel()
        absenceTask = nil
        watchdog?.cancel()
        watchdog = nil
        input.stopObserving()
        absentSince = nil
        guard absenceStage != .none else { return }
        setAbsenceStage(.none)
        manager.setScreensBlanked(false)
        // Noch unter dem Deckel: Die Ausgabe steigt danach gleich zum Wert des Profils.
        applyLightProfilesIfDue()
        manager.endDim(.absence)
    }

    /// Meldet der Sensor nichts mehr, kommen die Bildschirme zurück („im Zweifel an“).
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var wait = PresenceGate.staleAfter
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                let age = self.lastEventAge
                if PresenceGate.isStale(connected: self.connection == .connected, lastEventAge: age) {
                    self.returnFromAbsence(wake: false)
                    return
                }
                wait = PresenceGate.staleAfter - (age ?? .zero)
            }
        }
    }

    /// Bildschirme aus, von ScreenDim oder von macOS: bis zum Aufwachen nichts beobachten
    /// und nichts schreiben. Während der Abwesenheit gilt das als „aus“; dann weckt die
    /// Rückkehr sie.
    func screensDidSleep() {
        displaysAsleep = true
        guard absenceStage != .none else { return }
        absenceTask?.cancel()
        absenceTask = nil
        input.stopObserving()
        setAbsenceStage(.off)
    }

    /// Bildschirme wieder an (Rückkehr, Eingabe, Mitteilung): Helligkeit kurz danach zurück,
    /// wie beim Leerlauf. Meldet der Sensor dann weiter niemanden und hat keine Eingabe sie
    /// geweckt, beginnt die Abwesenheit von vorn.
    func screensDidWake() {
        displaysAsleep = false
        displaysWokeAt = now()
        guard absenceStage != .none else {
            if lightProfilesDue { applyLightProfilesAfterWake() }
            return
        }
        absenceTask?.cancel()
        let wait = wait
        absenceTask = Task { [weak self] in
            await wait(IdleDimmer.screenWakeSettle)
            guard !Task.isCancelled, let self else { return }
            self.absenceTask = nil
            if self.isStillAwayAfterWake {
                sensorLog.notice("Abwesenheit: nach dem Aufwachen weiter niemand da, beginnt neu")
                self.beginAbsence(restart: true)
            } else {
                self.endAbsence()
            }
        }
    }

    /// Die Anwesenheit wechselte, während die Displays ohne Abwesenheit schliefen (macOS):
    /// Das Lichtprofil gilt kurz nach dem Aufwachen, wenn DDC wieder etwas annimmt.
    private func applyLightProfilesAfterWake() {
        absenceTask?.cancel()
        let wait = wait
        absenceTask = Task { [weak self] in
            await wait(IdleDimmer.screenWakeSettle)
            guard !Task.isCancelled, let self else { return }
            self.absenceTask = nil
            self.applyLightProfilesIfDue()
        }
    }

    /// Nach dem Aufwachen weiter niemand da, etwa weil eine Mitteilung die Displays geweckt
    /// hat: Der Sensor ist verbunden, frisch und meldet „abwesend“, und seit kurz vor dem
    /// Aufwachen gab es keine Eingabe (`PresenceGate.restartsAbsenceAfterWake`).
    private var isStillAwayAfterWake: Bool {
        guard reactsToPresence, let displaysWokeAt else { return false }
        let connected = connection == .connected
        guard !PresenceGate.isStale(connected: connected, lastEventAge: lastEventAge) else { return false }
        return PresenceGate.restartsAbsenceAfterWake(
            presence: presence,
            connected: connected,
            sinceLastInput: input.timeSinceLastInput,
            sinceWake: now() - displaysWokeAt
        )
    }

    private func setAbsenceStage(_ stage: AbsenceStage) {
        guard stage != absenceStage else { return }
        absenceStage = stage
        sensorLog.notice("Abwesenheit: Bildschirme \(stage.logName, privacy: .public)")
        // Ohne auslösendes Ereignis (Zeit um, Aufwachen, Eingabe) ein eigener Eintrag.
        if !handlingEvent { appendDebug(.absence(stage), effect: nil) }
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
