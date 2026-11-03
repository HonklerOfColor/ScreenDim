import AppKit
import Carbon.HIToolbox
import ScreenDimKit
import SwiftUI

@main
struct ScreenDimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Im Demo-Modus ein anderes Symbol, damit er nie unbemerkt läuft.
        MenuBarExtra(
            "ScreenDim",
            systemImage: appDelegate.sensor.isDemoActive ? "sun.max.trianglebadge.exclamationmark" : "sun.max"
        ) {
            MenuContentView(manager: appDelegate.manager, sensor: appDelegate.sensor, loginItem: appDelegate.loginItem)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                sensor: appDelegate.sensor, manager: appDelegate.manager, idle: appDelegate.idle, loginItem: appDelegate.loginItem
            )
        }

        Window("Sensor-Diagnose", id: SensorDebugView.windowID) {
            SensorDebugView(sensor: appDelegate.sensor)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)

        Window("ScreenDim Diagnose", id: DiagnosticsView.windowID) {
            DiagnosticsView(manager: appDelegate.manager)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Externe Monitore per DDC/CI über `IOAVService`; wo das nicht geht, dimmt der
    /// Manager per Software. Das eingebaute Display regelt macOS (Helligkeitstasten).
    let manager = DisplayManager(makeExternalControl: { avServiceID, label, timing in
        IOAVServiceTransport(registryEntryID: avServiceID).map { DDCService(transport: $0, label: label, timing: timing) }
    })
    /// Optionaler Schreibtisch-Sensor; ohne Einstellung passiert nichts.
    lazy var sensor = SensorController(manager: manager)
    /// Abdunkeln nach einer Weile ohne Eingabe; ohne Einstellung passiert nichts.
    lazy var idle = IdleDimmer(manager: manager)
    let loginItem = LoginItem()
    private let hotKeys = HotKeyCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.start()
        sensor.start()
        idle.start()

        let modifiers = controlKey | optionKey
        let up = hotKeys.register(keyCode: kVK_UpArrow, modifiers: modifiers) { [manager] in
            manager.stepAll(by: DisplayManager.hotKeyStep)
        }
        let down = hotKeys.register(keyCode: kVK_DownArrow, modifiers: modifiers) { [manager] in
            manager.stepAll(by: -DisplayManager.hotKeyStep)
        }
        manager.hotKeysAvailable = up && down
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregisterAll()
        sensor.stop()
        idle.stop()
        manager.stop()
    }
}
