import CoreGraphics

/// Verfahren der Software-Dimmung. Die Hintergrundbeleuchtung bleibt bei beiden, wie sie
/// ist; nur das Bild wird dunkler.
public enum DimmingMethod: String, CaseIterable, Sendable {
    /// Gamma-Tabelle des Displays skalieren (Kalibrierung bleibt erhalten).
    case gamma
    /// Halbtransparentes schwarzes Fenster über dem ganzen Bildschirm. Greift auch dort,
    /// wo sich die Gamma-Tabelle nicht lesen oder setzen lässt.
    case overlay
}

/// Dunkelt Displays ab, bei denen DDC nicht durchkommt oder nicht verfügbar ist.
@MainActor
public protocol SoftwareDimming: AnyObject {
    /// Gewünschter Zustand für alle Displays dieses Verfahrens: Stufe 0…100 je Display.
    /// Displays, die fehlen oder 100 haben, bekommen ihren ursprünglichen Zustand zurück.
    /// - Returns: Displays, bei denen das Verfahren nicht greift (z. B. Gamma-Tabelle nicht
    ///   lesbar). Sie gelten danach als nicht gedimmt.
    @discardableResult
    func apply(_ levels: [CGDirectDisplayID: Double]) -> Set<CGDirectDisplayID>
    /// Alles neu aufsetzen: nachdem sich die Display-Menge geändert hat oder nach dem
    /// Aufwachen.
    func reapply()
    /// Nur die genannten Displays neu schreiben, z. B. nach einem Auflösungswechsel.
    func refresh(_ displays: Set<CGDirectDisplayID>)
}
