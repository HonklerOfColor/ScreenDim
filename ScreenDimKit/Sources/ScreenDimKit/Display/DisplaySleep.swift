import Foundation
import IOKit.pwr_mgt

/// Display-Ruhezustand von macOS, für alle Displays zugleich: Die Grafik schickt kein Signal
/// mehr, und jeder Monitor geht in seinen eigenen Standby, wie nach der Zeit aus den
/// Systemeinstellungen. Geht bei jedem Monitor, ohne DDC/CI. In Tests ersetzbar.
@MainActor
public protocol DisplaySleeping: AnyObject {
    /// Schickt alle Displays in den Ruhezustand. Verlangt macOS danach das Passwort, ist
    /// der Mac gesperrt. Ob es geklappt hat, meldet `NSWorkspace.screensDidSleepNotification`.
    func sleepDisplays()
    /// Weckt die Displays wie eine Eingabe.
    func wakeDisplays()
}

/// Schlafen per `pmset displaysleepnow` (braucht kein Root; `IODisplayWrangler` gibt es auf
/// Apple Silicon nicht), Aufwecken per `IOPMAssertionDeclareUserActivity`. Beides ist
/// öffentlich.
@MainActor
public final class SystemDisplaySleep: DisplaySleeping {
    /// Wiederverwendet, wie es die Doku für wiederholte Meldungen vorsieht.
    private var assertion = IOPMAssertionID(0)

    public init() {}

    public func sleepDisplays() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            sensorLog.error("pmset displaysleepnow endete mit \(process.terminationStatus)")
        }
        do {
            try process.run()
            sensorLog.notice("Displays schlafen (Abwesenheit)")
        } catch {
            sensorLog.error("pmset nicht startbar: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func wakeDisplays() {
        let result = IOPMAssertionDeclareUserActivity("ScreenDim: Anwesenheit" as CFString, kIOPMUserActiveLocal, &assertion)
        if result == kIOReturnSuccess {
            sensorLog.notice("Displays wecken (Anwesenheit)")
        } else {
            sensorLog.error("Aufwecken fehlgeschlagen: \(IOReturnDescription.name(result), privacy: .public)")
        }
    }
}
