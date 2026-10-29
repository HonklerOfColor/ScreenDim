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
            SettingsView(sensor: appDelegate.sensor)
        }

        #if SCREENDIM_DIRECT
        Window("ScreenDim Diagnose", id: DiagnosticsView.windowID) {
            DiagnosticsView(manager: appDelegate.manager)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if SCREENDIM_DIRECT
    let manager = DisplayManager(
        makeExternalControl: DirectControls.external,
        makeBuiltInControl: DirectControls.builtIn
    )
    #else
    /// App Store: keine private API, also weder DDC noch Steuerung des eingebauten
    /// Displays. Externe Monitore dimmt der Manager per Software.
    let manager = DisplayManager(discover: { DisplayDiscovery.displays(scanRegistry: false) })
    #endif
    /// Optionaler Schreibtisch-Sensor; ohne Einstellung passiert nichts.
    #if SCREENDIM_DIRECT
    lazy var sensor = SensorController(manager: manager, makeBuiltInLightSensor: DirectControls.lightSensor)
    #else
    lazy var sensor = SensorController(manager: manager)
    #endif
    let loginItem = LoginItem()
    private let hotKeys = HotKeyCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.start()
        sensor.start()

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
        manager.stop()
    }
}
