import AppKit
import Carbon.HIToolbox
import ScreenDimKit
import SwiftUI

@main
struct ScreenDimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ScreenDim", systemImage: "sun.max") {
            MenuContentView(manager: appDelegate.manager, loginItem: appDelegate.loginItem)
        }
        .menuBarExtraStyle(.window)

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
    let loginItem = LoginItem()
    private let hotKeys = HotKeyCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.start()

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
        manager.stop()
    }
}
