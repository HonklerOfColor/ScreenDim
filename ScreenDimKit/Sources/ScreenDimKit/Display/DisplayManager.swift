import AppKit
import CoreGraphics
import Observation
import os

private let log = ddcLog

/// Hält die Displays (eingebautes und externe), ihren Steuerzustand und ihre Helligkeit.
///
/// Die Steuerkanäle kommen über Fabriken von außen: Die Direct-Variante der App reicht
/// DDC und die Steuerung des eingebauten Displays herein, die App-Store-Variante nichts.
/// Displays ohne Kanal dimmt der Manager per Software (Gamma oder Overlay), in der
/// App-Store-Variante also auch das eingebaute.
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

        /// Verfahren, das tatsächlich dimmt.
        public var dimming: DimmingMethod { gammaUnavailable ? .overlay : preferredDimming }

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
    /// Pause zwischen den beiden Probe-Runden eines externen Monitors.
    @ObservationIgnored private let probeRetryDelay: Duration

    public init(
        store: BrightnessStore = BrightnessStore(),
        timing: DDCTiming = .configured(from: .standard),
        probeRetryDelay: Duration = .seconds(2),
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

        knownIdentities = identities
        discovered = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        generation += 1

        var cache: [ChannelKey: Channel] = [:]
        channels = [:]
        for display in displays {
            guard let key = Self.channelKey(for: display),
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
        let softwareDimmed = Set(monitors.filter(\.usesSoftwareDimming).map(\.storageKey))
        monitors = displays.map { display in
            let key = display.identity.storageKey
            let software = channels[display.id] == nil || (!display.isBuiltIn && softwareDimmed.contains(key))
            let brightness: Double = if software {
                store.brightness(for: key, mode: .software) ?? 100
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
                state: channels[display.id] == nil ? .noChannel : .probing,
                usesSoftwareDimming: software,
                preferredDimming: store.dimmingMethod(for: key) ?? .gamma
            )
        }
        syncSoftwareDimming()
        syncBlanking()
        log.notice("Displays: \(displays.map { "\($0.name) [\($0.id)] AV-Service: \($0.avServiceID.map { String(format: "0x%llX", $0) } ?? "-") Kanal: \(self.channels[$0.id] != nil)" }.joined(separator: ", "), privacy: .public); \(reused) Kanäle wiederverwendet")

        let generation = generation
        for id in channels.keys {
            Task { await probe(id, generation: generation) }
        }
    }

    private static func channelKey(for display: DiscoveredDisplay) -> ChannelKey? {
        switch display.kind {
        case .builtIn: .builtIn(display.id)
        case .external(let avServiceID): avServiceID.map(ChannelKey.avService)
        }
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

    public func setBrightness(_ percent: Double, for id: CGDirectDisplayID) {
        guard let index = index(of: id), monitors[index].isAdjustable else { return }
        let channel = channels[id]
        guard monitors[index].usesSoftwareDimming || channel != nil else { return }
        let value = Self.clamp(percent)
        guard monitors[index].brightness != value else { return }
        monitors[index].brightness = value
        // Die Hintergrundbeleuchtung des eingebauten Displays merkt sich macOS selbst.
        if !monitors[index].isBuiltIn || monitors[index].usesSoftwareDimming {
            let mode: BrightnessStore.Mode = monitors[index].usesSoftwareDimming ? .software : .ddc
            store.setBrightness(value, for: monitors[index].storageKey, mode: mode)
        }
        if monitors[index].usesSoftwareDimming {
            syncSoftwareDimming()
        } else if let channel {
            channel.throttle.submit(Self.raw(fromPercent: value, maximum: channel.maximum))
        }
    }

    /// - Parameter includingBuiltIn: `false` lässt das eingebaute Display aus, etwa wenn
    ///   macOS es per Auto-Helligkeit selbst regelt.
    public func setAllBrightness(_ percent: Double, includingBuiltIn: Bool = true) {
        for monitor in monitors where includingBuiltIn || !monitor.isBuiltIn {
            setBrightness(percent, for: monitor.id)
        }
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
            } catch {
                self?.writeFailed(key, raw: raw, error: error)
            }
        }
        return Channel(key: key, control: control, throttle: throttle)
    }

    /// Liest die aktuelle Helligkeit (mit Retry) und stellt bei externen Monitoren danach
    /// den gespeicherten Wert her.
    private func probe(_ id: CGDirectDisplayID, generation: Int) async {
        guard let channel = channels[id], let monitor = monitors.first(where: { $0.id == id }) else { return }
        let saved = monitor.isBuiltIn ? nil : store.brightness(for: monitor.storageKey, mode: .ddc)

        var reading: VCPReading?
        var lastError: DDCError?
        for round in 1...(monitor.isBuiltIn ? 1 : 2) where reading == nil {
            do throws(DDCError) {
                reading = try await channel.control.read(.brightness)
            } catch {
                lastError = error
                log.error("Read Helligkeit Display \(id), Runde \(round): \(error.description, privacy: .public)")
                if case .unsupportedCode = error { break }
                if round == 1 { try? await Task.sleep(for: probeRetryDelay) }
            }
            guard generation == self.generation else { return }
        }
        guard generation == self.generation, let index = index(of: id) else { return }

        if let reading {
            channel.maximum = max(reading.maximum, 1)
            let current = Self.percent(fromRaw: reading.current, maximum: channel.maximum)
            log.notice("Display \(id): Helligkeit \(reading.current)/\(reading.maximum), gespeichert: \(saved ?? -1)")
            monitors[index].state = .ready
            monitors[index].usesSoftwareDimming = false
            monitors[index].brightness = saved ?? current
            syncSoftwareDimming()
            if let saved, saved != current {
                channel.throttle.submit(Self.raw(fromPercent: saved, maximum: channel.maximum))
            }
        } else {
            monitors[index].state = lastError.map(DDCState.init(failure:)) ?? .noResponse
            if !monitor.isBuiltIn {
                switchToSoftwareDimming(index)
            }
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
        // gespeicherten Wert nicht abdunkeln.
        monitors[index].brightness = store.brightness(for: monitors[index].storageKey, mode: .software) ?? 100
        syncSoftwareDimming()
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
