import AppKit
import CoreGraphics

/// Ein Abdunkel-Fenster über genau einem Display; in Tests ersetzbar.
@MainActor
protocol OverlayWindow: AnyObject {
    /// Zeigt das Fenster mit dieser Deckkraft (0 durchsichtig … 1 schwarz).
    func show(alpha: Double)
    /// Passt Größe und Lage an den Bildschirm an, etwa nach einem Auflösungswechsel.
    func updateFrame()
    func close()
}

/// Software-Dimmung über ein schwarzes, halbtransparentes Fenster je Display. Braucht
/// keine Gamma-Tabelle und greift deshalb auch bei Displays, deren Tabelle sich nicht
/// lesen oder setzen lässt. Bildschirmfotos zeigen die Abdunklung mit.
@MainActor
public final class OverlayDimmer: SoftwareDimming {
    typealias MakeWindow = @MainActor (CGDirectDisplayID) -> (any OverlayWindow)?

    private let makeWindow: MakeWindow
    private var windows: [CGDirectDisplayID: any OverlayWindow] = [:]

    public convenience init() {
        self.init(makeWindow: { DimmingPanel(displayID: $0) })
    }

    init(makeWindow: @escaping MakeWindow) {
        self.makeWindow = makeWindow
    }

    /// Gleiche Kurve wie bei Gamma: 100 % durchsichtig, 0 % bleibt unter Vollschwarz.
    static func alpha(forPercent percent: Double) -> Double {
        1 - Double(GammaDimmer.factor(forPercent: percent))
    }

    @discardableResult
    public func apply(_ levels: [CGDirectDisplayID: Double]) -> Set<CGDirectDisplayID> {
        let levels = levels.filter { $0.value < 100 }
        for id in windows.keys where levels[id] == nil {
            windows.removeValue(forKey: id)?.close()
        }
        var failed: Set<CGDirectDisplayID> = []
        for (id, level) in levels {
            guard let window = windows[id] ?? makeWindow(id) else {
                ddcLog.error("Kein Bildschirm für Overlay auf Display \(id)")
                failed.insert(id)
                continue
            }
            windows[id] = window
            window.show(alpha: Self.alpha(forPercent: level))
        }
        return failed
    }

    public func reapply() {
        refresh(Set(windows.keys))
    }

    public func refresh(_ displays: Set<CGDirectDisplayID>) {
        for id in displays {
            windows[id]?.updateFrame()
        }
    }
}

/// Randloses Panel über dem ganzen Bildschirm: über der Menüleiste, auf allen Spaces und
/// über Vollbild-Apps, ohne Mausereignisse und ohne Fokus.
@MainActor
final class DimmingPanel: OverlayWindow {
    private let displayID: CGDirectDisplayID
    private let panel: NSPanel

    init?(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screen(for: displayID) else { return nil }
        self.displayID = displayID
        panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .black
        panel.alphaValue = 0
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
    }

    func show(alpha: Double) {
        panel.alphaValue = alpha
        updateFrame()
        panel.orderFrontRegardless()
    }

    func updateFrame() {
        guard let screen = NSScreen.screen(for: displayID) else { return }
        panel.setFrame(screen.frame, display: true)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
