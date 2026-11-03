import AppKit
import IOKit.pwr_mgt
import Observation
import os

let idleLog = Logger(subsystem: "com.andreastrabi.ScreenDim", category: "idle")

/// Dunkelt alle Monitore ab, wenn eine Weile weder Maus noch Tastatur benutzt wurden, und
/// hebt das bei der nächsten Eingabe wieder auf. Unabhängig davon schaltet macOS die
/// Displays nach seinen eigenen Einstellungen aus. Standard: aus.
///
/// Gewartet wird ohne Takt: ein Schlaf bis zum frühesten Zeitpunkt, an dem die Zeit um sein
/// kann (Zeit seit der letzten Eingabe laut macOS), dann neu prüfen. Abgedunkelt weckt eine
/// Mausbewegung sofort (Event-Monitor). Tasten in anderen Apps sieht ein Event-Monitor nur
/// mit Bedienungshilfen-Freigabe; deshalb prüft er, solange abgedunkelt ist, jede Sekunde
/// die Zeit seit der letzten Eingabe. Schlafen die Bildschirme, ruht beides, und ihr
/// Aufwachen hebt die Dimmung auf.
@MainActor
@Observable
public final class IdleDimmer {
    enum Keys {
        static let enabled = "idleDimEnabled"
        /// Sekunden.
        static let timeout = "idleDimTimeout"
        static let level = "idleDimLevel"
        static let pausesWhileKeptAwake = "idleDimPausesWhileKeptAwake"
    }

    /// Wählbare Wartezeiten in Minuten.
    public static let timeoutChoices = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120]
    public static let defaultTimeout: Duration = .seconds(15 * 60)
    public static let levelRange: ClosedRange<Double> = 0...50
    public static let defaultLevel: Double = 5
    /// Abgedunkelt: so oft die Zeit seit der letzten Eingabe prüfen (für Tasten).
    static let inputCheckInterval: Duration = .seconds(1)
    /// Hält eine App den Bildschirm wach (Video, Präsentation), so oft erneut prüfen.
    static let keptAwakeRecheck: Duration = .seconds(60)
    /// Nach dem Aufwachen der Bildschirme so lange warten, bevor die Helligkeit zurückkommt:
    /// Monitore nehmen DDC erst einen Moment später wieder an, und ihr Bild kommt ohnehin
    /// erst nach dem Einschalten.
    static let screenWakeSettle: Duration = .seconds(2)

    public private(set) var isEnabled: Bool
    public private(set) var timeout: Duration
    /// Höchste Helligkeit in Prozent, solange abgedunkelt ist.
    public private(set) var level: Double
    /// Nicht abdunkeln, solange eine App den Bildschirm wach hält (Videos, Präsentationen),
    /// so wie macOS dann auch das Display nicht ausschaltet. Standard: an.
    public private(set) var pausesWhileKeptAwake: Bool
    public private(set) var isDimmed = false

    /// Wartezeit in ganzen Minuten, für die Auswahl in den Einstellungen.
    public var timeoutMinutes: Int { Int(timeout.components.seconds / 60) }

    @ObservationIgnored private let manager: DisplayManager
    @ObservationIgnored private let preferences: any PreferenceStorage
    @ObservationIgnored private let input: any InputActivityMonitoring
    @ObservationIgnored private let isDisplayKeptAwake: @MainActor () -> Bool
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Warten auf den Ablauf, abgedunkelt das Prüfen auf Tasten oder das Warten nach dem
    /// Aufwachen der Bildschirme. Es läuft immer nur eines.
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var screensAsleep = false

    public convenience init(manager: DisplayManager) {
        self.init(
            manager: manager,
            preferences: UserDefaults.standard,
            input: SystemInputActivity(),
            isDisplayKeptAwake: { IdleDimmer.systemKeepsDisplayAwake() },
            notificationCenter: NSWorkspace.shared.notificationCenter
        )
    }

    init(
        manager: DisplayManager,
        preferences: any PreferenceStorage,
        input: any InputActivityMonitoring,
        isDisplayKeptAwake: @escaping @MainActor () -> Bool,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        notificationCenter: NotificationCenter = NotificationCenter()
    ) {
        self.manager = manager
        self.preferences = preferences
        self.input = input
        self.isDisplayKeptAwake = isDisplayKeptAwake
        self.sleep = sleep
        self.notificationCenter = notificationCenter
        isEnabled = preferences.object(forKey: Keys.enabled) as? Bool ?? false
        timeout = (preferences.object(forKey: Keys.timeout) as? Double).map { .seconds(max($0, 1)) } ?? Self.defaultTimeout
        level = (preferences.object(forKey: Keys.level) as? Double).map(Self.clampLevel) ?? Self.defaultLevel
        pausesWhileKeptAwake = preferences.object(forKey: Keys.pausesWhileKeptAwake) as? Bool ?? true
    }

    public func start() {
        observers = [
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
        arm()
    }

    public func stop() {
        observers.forEach(notificationCenter.removeObserver)
        observers = []
        task?.cancel()
        task = nil
        input.stopObserving()
        isDimmed = false
        manager.endIdleDim()
    }

    // MARK: - Einstellungen

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        preferences.set(enabled, forKey: Keys.enabled)
        if isDimmed { restore() } else { arm() }
    }

    public func setTimeout(_ timeout: Duration) {
        guard timeout != self.timeout, timeout > .zero else { return }
        self.timeout = timeout
        preferences.set(Double(timeout.components.seconds), forKey: Keys.timeout)
        if isDimmed { restore() } else { arm() }
    }

    /// Gilt ab dem nächsten Abdunkeln.
    public func setLevel(_ level: Double) {
        let level = Self.clampLevel(level)
        guard level != self.level else { return }
        self.level = level
        preferences.set(level, forKey: Keys.level)
    }

    public func setPausesWhileKeptAwake(_ pauses: Bool) {
        guard pauses != pausesWhileKeptAwake else { return }
        pausesWhileKeptAwake = pauses
        preferences.set(pauses, forKey: Keys.pausesWhileKeptAwake)
        if !isDimmed { arm() }
    }

    private static func clampLevel(_ level: Double) -> Double {
        min(max(level.rounded(), levelRange.lowerBound), levelRange.upperBound)
    }

    // MARK: - Ablauf

    /// Wartet, bis seit der letzten Eingabe `timeout` vergangen ist, und dunkelt dann ab.
    private func arm() {
        task?.cancel()
        task = nil
        guard isEnabled, !isDimmed, !screensAsleep else { return }
        let sleep = sleep
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.nextCheck() else { return }
                await sleep(wait)
            }
        }
    }

    /// Prüft, ob die Zeit um ist; dann abdunkeln. Sonst die Zeit bis zur nächsten Prüfung.
    private func nextCheck() -> Duration? {
        let idle = input.timeSinceLastInput
        guard idle >= timeout else { return timeout - idle }
        if pausesWhileKeptAwake, isDisplayKeptAwake() {
            return Self.keptAwakeRecheck
        }
        dim()
        return nil
    }

    private func dim() {
        isDimmed = true
        idleLog.notice("Seit \(Int(self.input.timeSinceLastInput.components.seconds)) s keine Eingabe: abdunkeln auf \(Int(self.level)) %")
        manager.beginIdleDim(to: level)
        watchForInput()
    }

    /// Maus sofort per Event-Monitor; Tasten über die Zeit seit der letzten Eingabe, die
    /// ohne Eingabe nie unter `timeout` fällt.
    private func watchForInput() {
        input.startObserving { [weak self] in self?.restore() }
        let sleep = sleep
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(Self.inputCheckInterval)
                guard !Task.isCancelled, let self else { return }
                if self.input.timeSinceLastInput < self.timeout {
                    self.restore()
                    return
                }
            }
        }
    }

    /// Helligkeit zurück, dann wieder auf den Ablauf warten.
    private func restore() {
        task?.cancel()
        task = nil
        input.stopObserving()
        if isDimmed {
            isDimmed = false
            idleLog.notice("Eingabe: Helligkeit zurück")
            manager.endIdleDim()
        }
        arm()
    }

    /// Bildschirme aus (macOS): Bis sie wieder an sind, gibt es nichts zu dimmen und keine
    /// Eingabe abzuwarten. Eine Dimmung bleibt stehen; DDC-Writes an schlafende Monitore
    /// könnten scheitern.
    func screensDidSleep() {
        screensAsleep = true
        task?.cancel()
        task = nil
        input.stopObserving()
    }

    /// Bildschirme wieder an, meist durch eine Eingabe: Helligkeit kurz danach zurück.
    func screensDidWake() {
        screensAsleep = false
        guard isDimmed else {
            arm()
            return
        }
        let sleep = sleep
        task?.cancel()
        task = Task { [weak self] in
            await sleep(Self.screenWakeSettle)
            guard !Task.isCancelled else { return }
            self?.restore()
        }
    }

    // MARK: - System

    /// Hält gerade eine App den Bildschirm wach (Video, Präsentation, `caffeinate -d`)?
    /// Dieselbe Zusicherung, mit der macOS das Ausschalten des Displays aufschiebt.
    public static func systemKeepsDisplayAwake() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let assertions = status?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (assertions[kIOPMAssertionTypePreventUserIdleDisplaySleep] as? Int ?? 0) != 0
    }
}
