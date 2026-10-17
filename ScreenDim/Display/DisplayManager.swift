import AppKit
import CoreGraphics
import Observation
import os

private let log = Logger(subsystem: "com.andreastrabi.ScreenDim", category: "ddc")

/// Hält die Displays (eingebautes und externe), ihren Steuerzustand und ihre Helligkeit.
@MainActor
@Observable
final class DisplayManager {
    enum DDCState: Equatable {
        /// Erster Read läuft noch.
        case probing
        case ready
        /// Kanal vorhanden, aber der Monitor antwortet nicht (DDC/CI aus, busy, Fehler).
        case noResponse
        /// Kein Steuerkanal: extern kein DDC-Kanal in der IORegistry, intern lehnt
        /// DisplayServices ab.
        case noChannel
    }

    struct Monitor: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let storageKey: String
        let isBuiltIn: Bool
        /// 0…100
        var brightness: Double
        var state: DDCState

        var isAdjustable: Bool { state == .ready || state == .noResponse }
    }

    static let hotKeyStep: Double = 10

    private(set) var monitors: [Monitor] = []
    /// `false`, wenn die globalen Tastenkürzel schon von einer anderen App belegt sind.
    var hotKeysAvailable = true

    @ObservationIgnored private var channels: [CGDirectDisplayID: Channel] = [:]
    @ObservationIgnored private var knownIdentities: [CGDirectDisplayID: DisplayIdentity] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingForcedRefresh = false
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let store: BrightnessStore

    init(store: BrightnessStore = BrightnessStore()) {
        self.store = store
    }

    // MARK: - Lebenszyklus

    func start() {
        ReconfigurationRelay.manager = self
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // Nach dem Aufwachen braucht der DCP ein paar Sekunden, bis DDC wieder geht.
                ReconfigurationRelay.manager?.scheduleRefresh(force: true, after: .seconds(3))
            }
        }
        refresh(force: true)
    }

    /// Sucht die Monitore neu. Ohne `force` passiert nur etwas, wenn sich die Menge der
    /// angeschlossenen Monitore geändert hat (Auflösungswechsel lösen ebenfalls Callbacks aus).
    func refresh(force: Bool) {
        let displays = DisplayDiscovery.displays()
        let identities = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.identity) })
        guard force || identities != knownIdentities else { return }

        knownIdentities = identities
        generation += 1
        channels = [:]
        for display in displays {
            if let control = Self.makeControl(for: display) {
                channels[display.id] = makeChannel(for: display.id, control: control)
            }
        }
        monitors = displays.map { display in
            Monitor(
                id: display.id,
                name: display.name,
                storageKey: display.identity.storageKey,
                isBuiltIn: display.isBuiltIn,
                brightness: display.isBuiltIn ? 50 : store.brightness(for: display.identity.storageKey) ?? 50,
                state: channels[display.id] == nil ? .noChannel : .probing
            )
        }
        log.notice("Displays: \(displays.map { "\($0.name) [\($0.id)] Kanal: \(self.channels[$0.id] != nil)" }.joined(separator: ", "), privacy: .public)")

        let generation = generation
        for id in channels.keys {
            Task { await probe(id, generation: generation) }
        }
    }

    private static func makeControl(for display: DiscoveredDisplay) -> (any DDCControlling)? {
        switch display.kind {
        case .builtIn:
            BuiltInDisplayControl(displayID: display.id)
        case .external(let transport):
            transport.map { DDCService(transport: $0, label: "\(display.id)") }
        }
    }

    func retry(_ id: CGDirectDisplayID) {
        guard let index = index(of: id), channels[id] != nil else {
            refresh(force: true)
            return
        }
        monitors[index].state = .probing
        let generation = generation
        Task { await probe(id, generation: generation) }
    }

    fileprivate func scheduleRefresh(force: Bool, after delay: Duration) {
        pendingForcedRefresh = pendingForcedRefresh || force
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let force = self.pendingForcedRefresh
            self.pendingForcedRefresh = false
            self.refresh(force: force)
        }
    }

    // MARK: - Helligkeit

    /// Durchschnitt der regelbaren Monitore, für den Master-Slider.
    var masterBrightness: Double {
        let values = monitors.filter(\.isAdjustable).map(\.brightness)
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0, +) / Double(values.count)).rounded()
    }

    func setBrightness(_ percent: Double, for id: CGDirectDisplayID) {
        guard let index = index(of: id), monitors[index].isAdjustable, let channel = channels[id] else { return }
        let value = Self.clamp(percent)
        guard monitors[index].brightness != value else { return }
        monitors[index].brightness = value
        // Das eingebaute Display merkt sich macOS selbst.
        if !monitors[index].isBuiltIn {
            store.setBrightness(value, for: monitors[index].storageKey)
        }
        channel.throttle.submit(Self.raw(fromPercent: value, maximum: channel.maximum))
    }

    func setAllBrightness(_ percent: Double) {
        for monitor in monitors {
            setBrightness(percent, for: monitor.id)
        }
    }

    func stepAll(by delta: Double) {
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
    func syncBuiltInBrightness() async {
        for monitor in monitors where monitor.isBuiltIn && monitor.state == .ready {
            guard let channel = channels[monitor.id], channel.throttle.isIdle,
                  let reading = try? await channel.control.read(.brightness),
                  channel.throttle.isIdle, let index = index(of: monitor.id)
            else { continue }
            monitors[index].brightness = Self.percent(fromRaw: reading.current, maximum: channel.maximum)
        }
    }

    // MARK: - Steuerkanal

    @MainActor
    private final class Channel {
        /// DDCService (extern) oder BuiltInDisplayControl (eingebaut).
        let control: any DDCControlling
        let throttle: LatestValueThrottle<UInt16>
        var maximum: UInt16 = 100

        init(control: any DDCControlling, throttle: LatestValueThrottle<UInt16>) {
            self.control = control
            self.throttle = throttle
        }
    }

    private func makeChannel(for id: CGDirectDisplayID, control: any DDCControlling) -> Channel {
        let throttle = LatestValueThrottle<UInt16>(interval: .milliseconds(50)) { [weak self] raw in
            do throws(DDCError) {
                try await control.write(.brightness, value: raw)
            } catch {
                log.error("Write \(raw) an Display \(id) fehlgeschlagen: \(String(describing: error), privacy: .public)")
                self?.markNoResponse(id)
            }
        }
        return Channel(control: control, throttle: throttle)
    }

    /// Liest die aktuelle Helligkeit (mit Retry) und stellt bei externen Monitoren danach
    /// den gespeicherten Wert her.
    private func probe(_ id: CGDirectDisplayID, generation: Int) async {
        guard let channel = channels[id], let monitor = monitors.first(where: { $0.id == id }) else { return }
        let saved = monitor.isBuiltIn ? nil : store.brightness(for: monitor.storageKey)

        var reading: VCPReading?
        for round in 1...(monitor.isBuiltIn ? 1 : 2) where reading == nil {
            do throws(DDCError) {
                reading = try await channel.control.read(.brightness)
            } catch {
                log.error("Read Helligkeit Display \(id), Runde \(round): \(String(describing: error), privacy: .public)")
                if case .unsupportedCode = error { break }
                if round == 1 { try? await Task.sleep(for: .seconds(2)) }
            }
            guard generation == self.generation else { return }
        }
        guard generation == self.generation, let index = index(of: id) else { return }

        if let reading {
            channel.maximum = max(reading.maximum, 1)
            let current = Self.percent(fromRaw: reading.current, maximum: channel.maximum)
            log.notice("Display \(id): Helligkeit \(reading.current)/\(reading.maximum), gespeichert: \(saved ?? -1)")
            monitors[index].state = .ready
            monitors[index].brightness = saved ?? current
            if let saved, saved != current {
                channel.throttle.submit(Self.raw(fromPercent: saved, maximum: channel.maximum))
            }
        } else {
            monitors[index].state = .noResponse
            // Manche Monitore beantworten keine Reads, nehmen Writes aber an.
            if let saved {
                monitors[index].brightness = saved
                channel.throttle.submit(Self.raw(fromPercent: saved, maximum: channel.maximum))
            }
        }
    }

    private func markNoResponse(_ id: CGDirectDisplayID) {
        guard let index = index(of: id), monitors[index].state == .ready else { return }
        monitors[index].state = .noResponse
    }

    private func index(of id: CGDirectDisplayID) -> Int? {
        monitors.firstIndex { $0.id == id }
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
        ReconfigurationRelay.manager?.scheduleRefresh(force: false, after: .milliseconds(1500))
    }
}
