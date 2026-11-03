import AppKit
import CoreGraphics
import Observation
import os

private let log = ddcLog

/// Hält die Displays (eingebautes und externe), ihren Steuerzustand und ihre Helligkeit.
///
/// Die Steuerkanäle kommen über Fabriken von außen: Die App reicht DDC/CI für externe
/// Monitore herein (`IOAVService`), optional die Steuerung des eingebauten Displays.
/// Displays ohne Kanal dimmt der Manager per Software (Gamma oder Overlay), ebenso
/// externe Monitore, bei denen DDC nicht durchkommt oder die der Nutzer auf Gamma oder
/// Overlay gestellt hat.
@MainActor
@Observable
public final class DisplayManager {
    public struct Monitor: Identifiable, Equatable {
        public let id: CGDirectDisplayID
        public let name: String
        public let storageKey: String
        public let isBuiltIn: Bool
        /// Dock oder Adapter im Signalweg; `nil` bei direktem Anschluss oder unbekannt.
        public var intermediary: DisplayPortLink.Intermediary? = nil
        /// Hersteller des Branch-Device, z. B. „Realtek“.
        public var branchVendor: String? = nil
        /// 0…100
        public var brightness: Double
        public var state: DDCState
        /// DDC kommt nicht durch oder fehlt; die Helligkeit regelt die Software-Dimmung.
        public var usesSoftwareDimming = false
        /// Vom Nutzer gewähltes Verfahren der Software-Dimmung.
        public var preferredDimming: DimmingMethod = .gamma
        /// Die Gamma-Tabelle ließ sich nicht lesen oder setzen; dann bleibt das Overlay.
        public var gammaUnavailable = false
        /// Ein DDC-Kanal ist da oder ließe sich anlegen (externer Monitor mit AV-Service).
        public var canUseDDC = false
        /// DDC/CI für diesen Monitor erlaubt (Einstellung, Standard: ja).
        public var ddcEnabled = true

        /// Verfahren, das tatsächlich dimmt.
        public var dimming: DimmingMethod { gammaUnavailable ? .overlay : preferredDimming }

        /// Verfahren, das der Nutzer gewählt hat: DDC/CI, solange es möglich und nicht
        /// abgewählt ist, sonst das Software-Verfahren. Bei DDC/CI sagt
        /// `usesSoftwareDimming`, ob gerade die Software als Rückfall dimmt.
        public var preferredMethod: BrightnessMethod { canUseDDC && ddcEnabled ? .ddc : BrightnessMethod(dimming) }

        public var isAdjustable: Bool { usesSoftwareDimming || state.isAdjustable }
    }

    /// Ein Steuerkanal überdauert Refreshes. Der Schlüssel ist die Hardware dahinter,
    /// nicht die `CGDirectDisplayID`, die nach Hotplug oder Ruhezustand wechseln kann.
    enum ChannelKey: Hashable {
        case builtIn(CGDirectDisplayID)
        /// RegistryEntryID des `DCPAVServiceProxy`.
        case avService(UInt64)
    }

    public typealias Discover = @MainActor () -> [DiscoveredDisplay]
    public typealias MakeExternalControl = @MainActor (_ avServiceID: UInt64, _ label: String, _ timing: DDCTiming) -> (any DDCControlling)?
    public typealias MakeBuiltInControl = @MainActor (_ displayID: CGDirectDisplayID) -> (any DDCControlling)?

    public static let hotKeyStep: Double = 10
    /// Kürzester Abstand zweier Schritte beim Überblenden; so schnell schickt auch die
    /// DDC-Drossel höchstens.
    static let fadeStepInterval: Duration = .milliseconds(50)
    /// Weicht der gelesene Wert des eingebauten Displays um mehr als so viele Punkte vom
    /// eigenen ab, hat ein anderer Regler gewirkt (macOS, Helligkeitstasten).
    public static let externalChangeThreshold: Double = 3

    public private(set) var monitors: [Monitor] = []
    /// `false`, wenn die globalen Tastenkürzel schon von einer anderen App belegt sind.
    public var hotKeysAvailable = true
    /// Alle Bildschirme schwarz, weil der Schreibtisch-Sensor „weg“ meldet.
    public private(set) var screensBlanked = false

    public let timing: DDCTiming

    /// Kanal je Display der aktuellen Generation.
    @ObservationIgnored private var channels: [CGDirectDisplayID: Channel] = [:]
    /// Alle Kanäle, die noch zu angeschlossener Hardware gehören. Pro Schlüssel gibt es
    /// genau einen Kanal und damit genau eine DDC-Queue.
    @ObservationIgnored private var channelCache: [ChannelKey: Channel] = [:]
    @ObservationIgnored private var discovered: [CGDirectDisplayID: DiscoveredDisplay] = [:]
    @ObservationIgnored private var knownIdentities: [CGDirectDisplayID: DisplayIdentity] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingForcedRefresh = false
    @ObservationIgnored private var pendingResetDimming = false
    @ObservationIgnored private var pendingReconfigured: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let store: BrightnessStore
    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let makeExternalControl: MakeExternalControl
    @ObservationIgnored private let makeBuiltInControl: MakeBuiltInControl
    @ObservationIgnored private let gamma: any SoftwareDimming
    @ObservationIgnored private let overlay: any SoftwareDimming
    @ObservationIgnored private let blanker: any ScreenBlanking
    /// Pause zwischen der ersten und zweiten Probe-Runde eines externen Monitors.
    @ObservationIgnored private let probeRetryDelay: Duration
    /// Pause vor der dritten Runde, die es nur nach einer verstümmelten Antwort gibt:
    /// Der Monitor spricht, ist aber noch nicht hochgefahren.
    @ObservationIgnored private let probeLateRetryDelay: Duration
    /// Dauer einer Überblendung nach Licht, unabhängig von der Größe des Sprungs.
    @ObservationIgnored private let fadeDuration: Duration
    /// Kürzere Überblendung für Wege des Managers selbst: Wert nach der Prüfung,
    /// Software-Rückfall, Aufwachen und Umstecken.
    @ObservationIgnored private let systemFadeDuration: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    /// Laufende Überblendung je Display (auch das Lesen des Startwerts davor).
    @ObservationIgnored private var fades: [CGDirectDisplayID: Task<Void, Never>] = [:]
    /// Ziel der laufenden Überblendung je Display.
    @ObservationIgnored private var fadeTargets: [CGDirectDisplayID: Double] = [:]

    /// Jeder Helligkeitsauftrag (Licht, Regler, Prüfung, Rückfall, …), für Protokoll und
    /// Pausen der Lichtregelung.
    @ObservationIgnored public var onBrightnessJob: (@MainActor (BrightnessJob) -> Void)?
    /// Ein Display ist nach der Prüfung regelbar (DDC bereit oder Software-Dimmung).
    @ObservationIgnored public var onMonitorReady: (@MainActor (CGDirectDisplayID) -> Void)?

    public init(
        store: BrightnessStore = BrightnessStore(),
        timing: DDCTiming = .configured(from: .standard),
        probeRetryDelay: Duration = .seconds(2),
        probeLateRetryDelay: Duration = .seconds(5),
        fadeDuration: Duration = .seconds(2),
        systemFadeDuration: Duration = .milliseconds(500),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        gamma: any SoftwareDimming = GammaDimmer(),
        overlay: any SoftwareDimming = OverlayDimmer(),
        blanker: any ScreenBlanking = ScreenBlanker(),
        discover: @escaping Discover = { DisplayDiscovery.displays() },
        makeExternalControl: @escaping MakeExternalControl = { _, _, _ in nil },
        makeBuiltInControl: @escaping MakeBuiltInControl = { _ in nil }
    ) {
        self.store = store
        self.timing = timing
        self.probeRetryDelay = probeRetryDelay
        self.probeLateRetryDelay = probeLateRetryDelay
        self.fadeDuration = fadeDuration
        self.systemFadeDuration = systemFadeDuration
        self.sleep = sleep
        self.gamma = gamma
        self.overlay = overlay
        self.blanker = blanker
        self.discover = discover
        self.makeExternalControl = makeExternalControl
        self.makeBuiltInControl = makeBuiltInControl
    }

    /// Gibt allen Displays ihre ursprüngliche Kurve zurück und schließt die Overlays
    /// (beim Beenden).
    public func stop() {
        fades.values.forEach { $0.cancel() }
        fades = [:]
        fadeTargets = [:]
        gamma.apply([:])
        overlay.apply([:])
        blanker.blank([])
    }

    // MARK: - Lebenszyklus

    public func start() {
        ReconfigurationRelay.manager = self
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Nach dem Aufwachen braucht der DCP ein paar Sekunden, bis DDC wieder geht.
                ReconfigurationRelay.manager?.scheduleRefresh(force: true, resetDimming: true, after: .seconds(3))
            }
        }
        refresh(force: true)
    }

    /// Sucht die Monitore neu. Ohne `force` passiert nur etwas, wenn sich die Menge der
    /// angeschlossenen Monitore geändert hat (Auflösungswechsel lösen ebenfalls Callbacks aus).
    /// Kanäle bekannter Hardware werden in jedem Fall weiterverwendet; ein neuer
    /// DDC-Kanal entsteht nur für einen neuen `DCPAVServiceProxy`.
    public func refresh(force: Bool) {
        refresh(force: force, resetDimming: false, reconfigured: [])
    }

    /// - Parameters:
    ///   - resetDimming: Kurven komplett neu aufsetzen (nach dem Aufwachen).
    ///   - reconfigured: Displays, die macOS umkonfiguriert hat (Auflösung, Anordnung).
    func refresh(force: Bool, resetDimming: Bool, reconfigured: Set<CGDirectDisplayID>) {
        let displays = discover()
        let identities = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.identity) })
        let changed = identities != knownIdentities

        if changed || resetDimming {
            // Neue Display-Menge oder Aufwachen: macOS kann alle Kurven zurückgesetzt haben.
            gamma.reapply()
            overlay.reapply()
        } else if !reconfigured.isEmpty {
            // Nur einzelne Displays umgebaut (Auflösung): deren Dimmung neu schreiben, ohne
            // die Kurven aller Displays per ColorSync zurückzusetzen.
            gamma.refresh(reconfigured)
            overlay.refresh(reconfigured)
        }
        guard force || changed else { return }

        // Neue Monitorliste: Überblendungen enden, gespeichert ist schon ihr Zielwert. Was
        // per Software gedimmt war, blendet von seinem sichtbaren Stand aus weiter.
        fades.values.forEach { $0.cancel() }
        fades = [:]
        fadeTargets = [:]
        let visible = Dictionary(
            monitors.filter(\.usesSoftwareDimming).map { ($0.storageKey, $0.brightness) },
            uniquingKeysWith: { $1 }
        )
        knownIdentities = identities
        discovered = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        generation += 1

        var cache: [ChannelKey: Channel] = [:]
        channels = [:]
        for display in displays {
            guard let key = channelKey(for: display),
                  let channel = cache[key] ?? channelCache[key] ?? makeChannel(key, for: display)
            else { continue }
            cache[key] = channel
            channels[display.id] = channel
        }
        let reused = channelCache.keys.filter { cache[$0] != nil }.count
        channelCache = cache

        // Wer schon per Software gedimmt wurde, bleibt es während der Probe; sonst würde
        // der Monitor kurz aufhellen. Das eingebaute Display wechselt nur ohne Kanal zur
        // Software; scheitert seine Steuerung, bleibt es beim Hinweis.
        let softwareDimmed = Set(visible.keys)
        var softwareTargets: [CGDirectDisplayID: Double] = [:]
        monitors = displays.map { display in
            let key = display.identity.storageKey
            let software = channels[display.id] == nil || (!display.isBuiltIn && softwareDimmed.contains(key))
            let ddcEnabled = store.isDDCEnabled(for: key)
            if software {
                softwareTargets[display.id] = store.brightness(for: key, mode: .software) ?? 100
            }
            // Software: zuerst der sichtbare Stand (neu angesteckt: nicht abgedunkelt), das
            // Ziel folgt per Überblendung. Eingebaut mit Kanal: Platzhalter bis zur Prüfung,
            // nie Startwert einer Überblendung (während der Prüfung nicht regelbar).
            let brightness: Double = if software {
                visible[key] ?? 100
            } else if display.isBuiltIn {
                50
            } else {
                store.brightness(for: key, mode: .ddc) ?? 50
            }
            return Monitor(
                id: display.id,
                name: display.name,
                storageKey: key,
                isBuiltIn: display.isBuiltIn,
                intermediary: display.link?.intermediary,
                branchVendor: display.link?.branchVendor,
                brightness: brightness,
                state: channels[display.id] != nil ? .probing : initialState(for: display),
                usesSoftwareDimming: software,
                preferredDimming: store.dimmingMethod(for: key) ?? .gamma,
                // Abgewählt: Kein Kanal, aber die Fabrik bekäme einen; sonst zählt der Kanal.
                canUseDDC: display.avServiceID != nil && (channels[display.id] != nil || !ddcEnabled),
                ddcEnabled: ddcEnabled
            )
        }
        syncSoftwareDimming()
        syncBlanking()
        for (id, target) in softwareTargets {
            fadeBrightness(to: target, for: id, reason: .wake, duration: systemFadeDuration)
        }
        log.notice("Displays: \(displays.map { "\($0.name) [\($0.id)] AV-Service: \($0.avServiceID.map { String(format: "0x%llX", $0) } ?? "-") Kanal: \(self.channels[$0.id] != nil)" }.joined(separator: ", "), privacy: .public); \(reused) Kanäle wiederverwendet")

        let generation = generation
        for id in channels.keys {
            Task { await probe(id, generation: generation) }
        }
    }

    /// Hat der Nutzer DDC/CI für einen Monitor abgewählt, bekommt er keinen Kanal; der
    /// des eingebauten Displays ist keiner.
    private func channelKey(for display: DiscoveredDisplay) -> ChannelKey? {
        switch display.kind {
        case .builtIn: .builtIn(display.id)
        case .external(let avServiceID):
            store.isDDCEnabled(for: display.identity.storageKey) ? avServiceID.map(ChannelKey.avService) : nil
        }
    }

    /// Zustand eines Displays ohne Kanal.
    private func initialState(for display: DiscoveredDisplay) -> DDCState {
        guard display.avServiceID != nil, !store.isDDCEnabled(for: display.identity.storageKey) else { return .noChannel }
        return .disabled
    }

    /// Wählt für einen Monitor DDC/CI, Gamma oder Overlay und merkt sich die Wahl.
    /// DDC/CI: neuer Kanal und Prüfung, danach gilt wieder der gespeicherte DDC-Wert.
    /// Gamma oder Overlay bei bisher DDC/CI: Der Kanal wird verworfen (keine weiteren
    /// I2C-Aufrufe), der Monitor dimmt ab jetzt per Software vom ungedimmten Stand aus;
    /// die Hintergrundbeleuchtung bleibt, wie sie steht.
    public func setBrightnessMethod(_ method: BrightnessMethod, for id: CGDirectDisplayID) {
        guard let index = index(of: id) else { return }
        let monitor = monitors[index]
        if let dimming = method.dimming {
            setDimmingMethod(dimming, for: id)
            guard monitor.canUseDDC, monitor.ddcEnabled else { return }
            log.notice("Display \(id): DDC/CI aus, \(dimming.rawValue, privacy: .public)")
            store.setDDCEnabled(false, for: monitor.storageKey)
        } else {
            guard monitor.canUseDDC, !monitor.ddcEnabled else { return }
            log.notice("Display \(id): DDC/CI an")
            store.setDDCEnabled(true, for: monitor.storageKey)
        }
        refresh(force: true)
    }

    public func retry(_ id: CGDirectDisplayID) {
        guard let index = index(of: id), channels[id] != nil else {
            refresh(force: true)
            return
        }
        monitors[index].state = .probing
        let generation = generation
        Task { await probe(id, generation: generation) }
    }

    fileprivate func scheduleRefresh(
        force: Bool,
        resetDimming: Bool = false,
        reconfigured: Set<CGDirectDisplayID> = [],
        after delay: Duration
    ) {
        pendingForcedRefresh = pendingForcedRefresh || force
        pendingResetDimming = pendingResetDimming || resetDimming
        pendingReconfigured.formUnion(reconfigured)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let force = self.pendingForcedRefresh
            let resetDimming = self.pendingResetDimming
            let reconfigured = self.pendingReconfigured
            self.pendingForcedRefresh = false
            self.pendingResetDimming = false
            self.pendingReconfigured = []
            self.refresh(force: force, resetDimming: resetDimming, reconfigured: reconfigured)
        }
    }

    // MARK: - Helligkeit

    /// Durchschnitt der regelbaren Monitore, für den Master-Slider.
    public var masterBrightness: Double {
        let values = monitors.filter(\.isAdjustable).map(\.brightness)
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0, +) / Double(values.count)).rounded()
    }

    /// Wert, auf den das Display gerade zugeht: Ziel der laufenden Überblendung, sonst der
    /// gesetzte Wert. Bezug für die Hysterese der Lichtregelung.
    public func brightnessTarget(for id: CGDirectDisplayID) -> Double? {
        fadeTargets[id] ?? monitors.first { $0.id == id }?.brightness
    }

    /// Setzt die Helligkeit sofort und bricht eine laufende Überblendung ab: Was der Nutzer
    /// einstellt (Regler, Tastenkürzel), gewinnt. Meldet einen Auftrag „manual“.
    /// - Returns: `false`, wenn der Monitor noch geprüft wird und den Wert deshalb nicht
    ///   übernommen hat. Nach der Prüfung steht er auf seinem gespeicherten Wert.
    @discardableResult
    public func setBrightness(_ percent: Double, for id: CGDirectDisplayID) -> Bool {
        fades.removeValue(forKey: id)?.cancel()
        fadeTargets[id] = nil
        guard let before = monitors.first(where: { $0.id == id }) else { return true }
        let accepted = apply(percent, to: id, persist: true)
        if let after = monitors.first(where: { $0.id == id }), after.brightness != before.brightness {
            report(BrightnessJob(
                storageKey: after.storageKey, name: after.name, reason: .manual,
                remembered: before.brightness, actual: nil, target: after.brightness, duration: .zero
            ))
        }
        return accepted
    }

    /// Gleitet in Schritten von höchstens einem Prozentpunkt zum Wert, statt zu springen.
    /// Alle automatischen Wege laufen hierüber.
    ///
    /// Startwert ist der echte Wert, nicht der Merkwert: Beim eingebauten Display wird er
    /// vorher gelesen (nur bei freier Drossel); weicht er um mehr als
    /// `externalChangeThreshold` ab, hat ein anderer Regler gewirkt, sein Wert wird
    /// übernommen und nichts geschrieben (Auftrag „externalChange“). Bei DDC gilt der
    /// zuletzt bestätigte Write, ohne zusätzlichen Read. Gespeichert wird gleich der
    /// Zielwert, damit ein Refresh mitten in der Überblendung nicht auf einem Zwischenwert
    /// landet. Eine neue Überblendung oder `setBrightness` bricht die laufende ab.
    /// - Parameter duration: `nil`: 2 s für Licht (neuer Wert, Quellwechsel, nachgeholt
    ///   nach der Prüfung), sonst die kurze Dauer (etwa beim Ziehen an der Kurve).
    /// - Returns: wie `setBrightness`.
    @discardableResult
    public func fadeBrightness(
        to percent: Double,
        for id: CGDirectDisplayID,
        reason: BrightnessJob.Reason,
        duration: Duration? = nil
    ) -> Bool {
        guard let index = index(of: id) else { return true }
        guard monitors[index].isAdjustable else { return monitors[index].state != .probing }
        fades.removeValue(forKey: id)?.cancel()
        let target = Self.clamp(percent)
        let duration = duration ?? defaultFadeDuration(for: reason)
        fadeTargets[id] = target
        persist(target, at: index)
        let monitor = monitors[index]
        if !monitor.usesSoftwareDimming, monitor.isBuiltIn, let channel = channels[id] {
            fades[id] = Task { [weak self] in
                var actual: Double?
                if channel.throttle.isIdle, let reading = try? await channel.control.read(.brightness),
                   channel.throttle.isIdle {
                    actual = Self.percent(fromRaw: reading.current, maximum: channel.maximum)
                }
                guard !Task.isCancelled, let self else { return }
                self.beginFade(id, to: target, reason: reason, duration: duration, actual: actual, detectsExternal: true)
            }
        } else {
            let channel = monitor.usesSoftwareDimming ? nil : channels[id]
            let confirmed = channel.flatMap { channel in
                channel.confirmed.map { Self.percent(fromRaw: $0, maximum: channel.maximum) }
            }
            beginFade(id, to: target, reason: reason, duration: duration, actual: confirmed, detectsExternal: false)
        }
        return true
    }

    private func defaultFadeDuration(for reason: BrightnessJob.Reason) -> Duration {
        switch reason {
        case .lux, .sourceSwitch, .pendingAfterProbe: fadeDuration
        default: systemFadeDuration
        }
    }

    private func beginFade(
        _ id: CGDirectDisplayID,
        to target: Double,
        reason: BrightnessJob.Reason,
        duration: Duration,
        actual: Double?,
        detectsExternal: Bool
    ) {
        guard let index = index(of: id) else { return }
        let monitor = monitors[index]
        func job(_ reason: BrightnessJob.Reason, target: Double, duration: Duration) -> BrightnessJob {
            BrightnessJob(
                storageKey: monitor.storageKey, name: monitor.name, reason: reason,
                remembered: monitor.brightness, actual: actual, target: target, duration: duration
            )
        }
        if detectsExternal, let actual, abs(actual - monitor.brightness) > Self.externalChangeThreshold {
            monitors[index].brightness = actual
            fadeTargets[id] = nil
            report(job(.externalChange, target: actual, duration: .zero))
            return
        }
        let start = actual ?? monitor.brightness
        monitors[index].brightness = start
        // Schon am Ziel: kein Auftrag, kein Eintrag (etwa Refresh ohne Änderung).
        guard abs(target - start) >= 0.5 else {
            apply(target, to: id, persist: false)
            fadeTargets[id] = nil
            return
        }
        let steps = min(Int(abs(target - start)), Int(duration / Self.fadeStepInterval))
        report(job(reason, target: target, duration: steps > 1 ? duration : .zero))
        guard steps > 1 else {
            apply(target, to: id, persist: false)
            fadeTargets[id] = nil
            return
        }
        let interval = duration / steps
        let sleep = sleep
        fades[id] = Task { [weak self] in
            for step in 1...steps {
                await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                let value = step == steps ? target : start + (target - start) * Double(step) / Double(steps)
                self.apply(value, to: id, persist: false)
            }
            self?.fadeTargets[id] = nil
        }
    }

    /// Licht-Aufträge kommen oft und bleiben auf `info`; alle anderen (Rückfall, Prüfung,
    /// fremde Änderung, …) als `notice`, damit `log show` sie ohne `--info` behält.
    private func report(_ job: BrightnessJob) {
        if case .lux = job.reason {
            lightLog.info("\(job.logDescription, privacy: .public)")
        } else {
            lightLog.notice("\(job.logDescription, privacy: .public)")
        }
        onBrightnessJob?(job)
    }

    @discardableResult
    private func apply(_ percent: Double, to id: CGDirectDisplayID, persist: Bool) -> Bool {
        guard let index = index(of: id) else { return true }
        guard monitors[index].isAdjustable else { return monitors[index].state != .probing }
        let channel = channels[id]
        guard monitors[index].usesSoftwareDimming || channel != nil else { return true }
        let value = Self.clamp(percent)
        guard monitors[index].brightness != value else { return true }
        monitors[index].brightness = value
        if persist {
            self.persist(value, at: index)
        }
        if monitors[index].usesSoftwareDimming {
            syncSoftwareDimming()
        } else if let channel {
            channel.throttle.submit(Self.raw(fromPercent: value, maximum: channel.maximum))
        }
        return true
    }

    private func persist(_ value: Double, at index: Int) {
        // Die Hintergrundbeleuchtung des eingebauten Displays merkt sich macOS selbst.
        guard !monitors[index].isBuiltIn || monitors[index].usesSoftwareDimming else { return }
        let mode: BrightnessStore.Mode = monitors[index].usesSoftwareDimming ? .software : .ddc
        store.setBrightness(Self.clamp(value), for: monitors[index].storageKey, mode: mode)
    }

    /// - Parameter includingBuiltIn: `false` lässt das eingebaute Display aus, etwa wenn
    ///   macOS es per Auto-Helligkeit selbst regelt.
    /// - Returns: `false`, wenn ein betroffener Monitor noch geprüft wird und den Wert
    ///   deshalb nicht übernommen hat. Nach der Prüfung steht er auf seinem gespeicherten Wert.
    @discardableResult
    public func setAllBrightness(_ percent: Double, includingBuiltIn: Bool = true) -> Bool {
        var complete = true
        for monitor in monitors where includingBuiltIn || !monitor.isBuiltIn {
            if !setBrightness(percent, for: monitor.id) { complete = false }
        }
        return complete
    }

    public func stepAll(by delta: Double) {
        Task {
            // Das eingebaute Display kann sich über Helligkeitstasten oder Auto-Helligkeit
            // geändert haben; erst den echten Wert holen, dann relativ verstellen.
            await syncBuiltInBrightness()
            for monitor in monitors where monitor.isAdjustable {
                setBrightness(monitor.brightness + delta, for: monitor.id)
            }
        }
    }

    /// Übernimmt den aktuellen Wert des eingebauten Displays, sofern gerade kein eigener
    /// Write aussteht.
    public func syncBuiltInBrightness() async {
        for monitor in monitors where monitor.isBuiltIn && monitor.state == .ready {
            guard let channel = channels[monitor.id], channel.throttle.isIdle,
                  let reading = try? await channel.control.read(.brightness),
                  channel.throttle.isIdle, let index = index(of: monitor.id)
            else { continue }
            monitors[index].brightness = Self.percent(fromRaw: reading.current, maximum: channel.maximum)
        }
    }

    /// Wählt Gamma oder Overlay für einen externen Monitor oder ein per Software gedimmtes
    /// eingebautes Display. Gamma wird dabei neu versucht, auch wenn es vorher nicht ging.
    public func setDimmingMethod(_ method: DimmingMethod, for id: CGDirectDisplayID) {
        guard let index = index(of: id), !monitors[index].isBuiltIn || monitors[index].usesSoftwareDimming else { return }
        store.setDimmingMethod(method, for: monitors[index].storageKey)
        monitors[index].preferredDimming = method
        if method == .gamma {
            monitors[index].gammaUnavailable = false
        }
        syncSoftwareDimming()
    }

    // MARK: - Schreibtisch-Sensor

    /// Schaltet alle Bildschirme schwarz bzw. wieder sichtbar. Helligkeit, Dimmung und
    /// DDC bleiben dabei unberührt.
    public func setScreensBlanked(_ blanked: Bool) {
        guard blanked != screensBlanked else { return }
        log.notice("Bildschirme \(blanked ? "aus" : "an", privacy: .public) (Sensor)")
        screensBlanked = blanked
        syncBlanking()
    }

    private func syncBlanking() {
        blanker.blank(screensBlanked ? Set(monitors.map(\.id)) : [])
    }

    // MARK: - Steuerkanal

    @MainActor
    private final class Channel {
        let key: ChannelKey
        /// DDC (extern) oder Steuerung des eingebauten Displays.
        let control: any DDCControlling
        let throttle: LatestValueThrottle<UInt16>
        var maximum: UInt16 = 100
        /// Zuletzt bestätigter Wert (gelesen oder geschrieben): Startwert einer Überblendung
        /// ohne zusätzlichen Read.
        var confirmed: UInt16?

        init(key: ChannelKey, control: any DDCControlling, throttle: LatestValueThrottle<UInt16>) {
            self.key = key
            self.control = control
            self.throttle = throttle
        }
    }

    private func makeChannel(_ key: ChannelKey, for display: DiscoveredDisplay) -> Channel? {
        let control: (any DDCControlling)? = switch key {
        case .builtIn(let id): makeBuiltInControl(id)
        case .avService(let avServiceID): makeExternalControl(avServiceID, "\(display.name)[\(display.id)]", timing)
        }
        guard let control else { return nil }
        log.notice("Neuer Kanal für \(display.name, privacy: .public) [\(display.id)]: \(String(describing: key), privacy: .public)")

        let throttle = LatestValueThrottle<UInt16>(interval: .milliseconds(50)) { [weak self] raw in
            do throws(DDCError) {
                try await control.write(.brightness, value: raw)
                self?.channelCache[key]?.confirmed = raw
            } catch {
                self?.writeFailed(key, raw: raw, error: error)
            }
        }
        return Channel(key: key, control: control, throttle: throttle)
    }

    /// Liest die aktuelle Helligkeit (mit Retry) und stellt bei externen Monitoren danach
    /// den gespeicherten Wert her. Externe Monitore bekommen zwei Runden; eine dritte,
    /// spätere nur nach verstümmelter Antwort (siehe `probeDelay`).
    private func probe(_ id: CGDirectDisplayID, generation: Int) async {
        guard let channel = channels[id], let monitor = monitors.first(where: { $0.id == id }) else { return }
        let saved = monitor.isBuiltIn ? nil : store.brightness(for: monitor.storageKey, mode: .ddc)

        var reading: VCPReading?
        var lastError: DDCError?
        var round = 0
        while reading == nil {
            round += 1
            do throws(DDCError) {
                reading = try await channel.control.read(.brightness)
            } catch {
                lastError = error
                log.error("Read Helligkeit Display \(id), Runde \(round): \(error.description, privacy: .public)")
                guard let delay = probeDelay(after: error, round: round, isBuiltIn: monitor.isBuiltIn) else { break }
                try? await Task.sleep(for: delay)
            }
            guard generation == self.generation else { return }
        }
        guard generation == self.generation, let index = index(of: id) else { return }

        if let reading {
            channel.maximum = max(reading.maximum, 1)
            let current = Self.percent(fromRaw: reading.current, maximum: channel.maximum)
            log.notice("Display \(id): Helligkeit \(reading.current)/\(reading.maximum), gespeichert: \(saved ?? -1)")
            channel.confirmed = reading.current
            monitors[index].state = .ready
            monitors[index].usesSoftwareDimming = false
            monitors[index].brightness = current
            syncSoftwareDimming()
            if let saved, saved != current {
                fadeBrightness(to: saved, for: id, reason: .probeRestore, duration: systemFadeDuration)
            }
        } else {
            monitors[index].state = lastError.map(DDCState.init(failure:)) ?? .noResponse
            if !monitor.isBuiltIn {
                switchToSoftwareDimming(index)
            }
        }
        onMonitorReady?(id)
    }

    /// Pause vor der nächsten Probe-Runde; `nil` beendet die Prüfung.
    ///
    /// Eine verstümmelte Antwort (Prüfsumme, Aufbau) heißt: Der Monitor spricht, sein
    /// Scaler ist aber noch nicht hochgefahren; der JapanNext 6K liefert nach dem
    /// Einstecken etwa 5 s lang Zufallsbytes. Dafür die dritte, späte Runde. Nach
    /// Null-Antwort (DDC/CI aus), Timeout oder I/O-Fehler (Dock hängt) nicht: Jeder
    /// weitere Aufruf kann dort im Kernel blockieren.
    private func probeDelay(after error: DDCError, round: Int, isBuiltIn: Bool) -> Duration? {
        guard !isBuiltIn else { return nil }
        return switch (round, error) {
        case (_, .unsupportedCode): nil
        case (1, _): probeRetryDelay
        case (2, .checksumMismatch), (2, .malformedReply): probeLateRetryDelay
        default: nil
        }
    }

    private func writeFailed(_ key: ChannelKey, raw: UInt16, error: DDCError) {
        for (id, channel) in channels where channel.key == key {
            log.error("Write \(raw) an Display \(id) fehlgeschlagen: \(error.description, privacy: .public)")
            guard let index = index(of: id), monitors[index].state != .probing, monitors[index].state != .noChannel else { continue }
            fail(index, error)
        }
    }

    // MARK: - Software-Dimmung

    private func fail(_ index: Int, _ error: DDCError) {
        monitors[index].state = DDCState(failure: error)
        if !monitors[index].isBuiltIn {
            switchToSoftwareDimming(index)
        }
    }

    /// DDC antwortet nicht oder nimmt Writes nicht an: ab jetzt per Software, ohne
    /// weitere I2C-Writes (die können über Docks im Kernel hängen). „Erneut prüfen“
    /// probiert DDC wieder.
    private func switchToSoftwareDimming(_ index: Int) {
        guard !monitors[index].usesSoftwareDimming else { return }
        log.notice("Display \(self.monitors[index].id): Software-Dimmung statt DDC")
        monitors[index].usesSoftwareDimming = true
        // Nur den eigenen Software-Wert übernehmen, nie den DDC-Wert: Die Hintergrund-
        // beleuchtung steht schon darauf, die Software-Dimmung käme oben drauf. Ohne
        // gespeicherten Wert nicht abdunkeln. Von „nicht abgedunkelt“ aus überblenden.
        let target = store.brightness(for: monitors[index].storageKey, mode: .software) ?? 100
        monitors[index].brightness = 100
        syncSoftwareDimming()
        fadeBrightness(to: target, for: monitors[index].id, reason: .softwareFallback, duration: systemFadeDuration)
    }

    /// Verteilt die Software-Dimmung auf Gamma und Overlay. Wo Gamma nicht greift,
    /// übernimmt im selben Durchgang das Overlay.
    private func syncSoftwareDimming() {
        let failed = gamma.apply(softwareLevels(.gamma))
        for id in failed {
            guard let index = index(of: id) else { continue }
            log.notice("Display \(id): Gamma-Tabelle nicht nutzbar, Overlay statt Gamma")
            monitors[index].gammaUnavailable = true
        }
        overlay.apply(softwareLevels(.overlay))
    }

    private func softwareLevels(_ method: DimmingMethod) -> [CGDirectDisplayID: Double] {
        var levels: [CGDirectDisplayID: Double] = [:]
        for monitor in monitors where monitor.usesSoftwareDimming && monitor.dimming == method {
            levels[monitor.id] = monitor.brightness
        }
        return levels
    }

    private func index(of id: CGDirectDisplayID) -> Int? {
        monitors.firstIndex { $0.id == id }
    }

    // MARK: - Diagnose

    public func diagnostics() -> [DisplayDiagnostics] {
        monitors.map { monitor in
            let display = discovered[monitor.id]
            let channel = channels[monitor.id]
            return DisplayDiagnostics(
                id: monitor.id,
                name: monitor.name,
                identity: display?.identity,
                isBuiltIn: monitor.isBuiltIn,
                softwareDimming: monitor.usesSoftwareDimming ? monitor.dimming : nil,
                avServiceID: display?.avServiceID,
                hasChannel: channel != nil,
                link: display?.link,
                state: monitor.state,
                brightness: monitor.brightness,
                maximum: channel?.maximum ?? 100,
                ddc: channel?.control.diagnostics
            )
        }
    }

    /// „Test: Read 0x10“. Ein Ergebnis übernimmt der Zustand des Monitors.
    public func testRead(_ id: CGDirectDisplayID) async -> String {
        guard let channel = channels[id] else { return String(localized: "Kein Kanal") }
        let started = ContinuousClock.now
        do throws(DDCError) {
            let reading = try await channel.control.read(.brightness)
            let elapsed = (ContinuousClock.now - started).milliseconds
            log.notice("Test-Read Display \(id): \(reading.current)/\(reading.maximum), \(elapsed) ms")
            if let index = index(of: id), monitors[index].state != .probing {
                channel.maximum = max(reading.maximum, 1)
                monitors[index].state = .ready
            }
            return String(localized: "Read OK: \(Int(reading.current))/\(Int(reading.maximum)), \(elapsed) ms")
        } catch {
            let elapsed = (ContinuousClock.now - started).milliseconds
            log.error("Test-Read Display \(id): \(error.description, privacy: .public), \(elapsed) ms")
            if let index = index(of: id), monitors[index].state != .probing {
                fail(index, error)
            }
            return String(localized: "Read fehlgeschlagen: \(error.description), \(elapsed) ms")
        }
    }

    /// „Test: Write 0x10 = aktueller Wert“: schreibt genau einmal den Wert, den der
    /// Slider zeigt.
    public func testWrite(_ id: CGDirectDisplayID) async -> String {
        guard let channel = channels[id], let monitor = monitors.first(where: { $0.id == id }) else {
            return String(localized: "Kein Kanal")
        }
        let raw = Self.raw(fromPercent: monitor.brightness, maximum: channel.maximum)
        let started = ContinuousClock.now
        do throws(DDCError) {
            try await channel.control.write(.brightness, value: raw)
            let elapsed = (ContinuousClock.now - started).milliseconds
            log.notice("Test-Write Display \(id): \(raw), \(elapsed) ms")
            return String(localized: "Write \(Int(raw)) OK, \(elapsed) ms")
        } catch {
            let elapsed = (ContinuousClock.now - started).milliseconds
            log.error("Test-Write Display \(id) \(raw): \(error.description, privacy: .public), \(elapsed) ms")
            if let index = index(of: id), monitors[index].state != .probing {
                fail(index, error)
            }
            return String(localized: "Write \(Int(raw)) fehlgeschlagen: \(error.description), \(elapsed) ms")
        }
    }

    // MARK: - Umrechnung

    static func clamp(_ percent: Double) -> Double {
        min(max(percent.rounded(), 0), 100)
    }

    static func percent(fromRaw raw: UInt16, maximum: UInt16) -> Double {
        clamp(Double(raw) / Double(max(maximum, 1)) * 100)
    }

    static func raw(fromPercent percent: Double, maximum: UInt16) -> UInt16 {
        UInt16((clamp(percent) / 100 * Double(maximum)).rounded())
    }
}

/// Brücke vom C-Callback zurück in den MainActor.
@MainActor
private enum ReconfigurationRelay {
    static weak var manager: DisplayManager?
}

private func displayReconfigured(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Task { @MainActor in
        // Hotplug: kurz warten, bis der DDC-Kanal des neuen Monitors bereit ist.
        ReconfigurationRelay.manager?.scheduleRefresh(force: false, reconfigured: [display], after: .milliseconds(1500))
    }
}
