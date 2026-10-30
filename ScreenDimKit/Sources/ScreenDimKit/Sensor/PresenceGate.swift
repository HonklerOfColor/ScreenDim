import AppKit
import CoreGraphics

/// Wann die Anwesenheit des Sensors die Bildschirme ausschalten darf. Im Zweifel bleiben
/// sie an: Ein veralteter oder getrennter Sensor schaltet nichts aus.
public enum PresenceGate {
    /// Älter darf das letzte Ereignis beim Ausschalten nicht sein.
    public static let maxEventAge: Duration = .seconds(10)
    /// Sind die Bildschirme schon aus, gilt der Sensor erst nach dieser Stille als
    /// veraltet. Ohne Zustandsänderung schickt ESPHome nur Pings (etwa alle 10 s); mit
    /// 10 s würden die Bildschirme flackern.
    public static let staleAfter: Duration = .seconds(30)
    /// Eingaben innerhalb dieser Zeit verhindern das Ausschalten.
    public static let inputGrace: Duration = .seconds(2)

    /// Bildschirme aus? Nur bei gemeldeter Abwesenheit eines verbundenen Sensors mit
    /// frischem Ereignis und ohne gerade erfolgte Eingabe.
    public static func shouldBlank(
        presence: Bool?,
        connected: Bool,
        lastEventAge: Duration?,
        sinceLastInput: Duration
    ) -> Bool {
        guard presence == false, connected, let lastEventAge else { return false }
        return lastEventAge < maxEventAge && sinceLastInput >= inputGrace
    }

    /// Bildschirme wieder an, weil der Sensor nichts mehr meldet?
    public static func isStale(connected: Bool, lastEventAge: Duration?) -> Bool {
        guard connected, let lastEventAge else { return true }
        return lastEventAge >= staleAfter
    }
}

/// Eingaben an Maus und Tastatur. In Tests ersetzbar.
@MainActor
public protocol InputActivityMonitoring: AnyObject {
    var timeSinceLastInput: Duration { get }
    /// Ruft `onInput` bei jeder Eingabe, bis `stopObserving()`.
    func startObserving(_ onInput: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// Eingaben systemweit. Die Event-Monitore laufen nur, solange die Bildschirme aus sind.
/// Mausbewegungen kommen ohne Bedienungshilfen-Freigabe an, Tasten außerhalb der App nur
/// mit ihr.
@MainActor
public final class SystemInputActivity: InputActivityMonitoring {
    private var monitors: [Any] = []

    public init() {}

    public var timeSinceLastInput: Duration {
        let anyInput = CGEventType(rawValue: ~0)!
        return .seconds(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput))
    }

    public func startObserving(_ onInput: @escaping @MainActor () -> Void) {
        stopObserving()
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .flagsChanged,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { onInput() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { onInput() }
            return event
        }) {
            monitors.append(local)
        }
    }

    public func stopObserving() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
