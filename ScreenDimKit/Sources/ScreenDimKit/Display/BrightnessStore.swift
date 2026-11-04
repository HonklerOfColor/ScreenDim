import Foundation

/// Schlüssel-Wert-Speicher für Einstellungen. `UserDefaults` erfüllt ihn; Tests nehmen
/// einen Speicher im RAM, weil `cfprefsd` sonst Plists in ~/Library/Preferences anlegt,
/// auch nachdem die Domain entfernt wurde.
protocol PreferenceStorage: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStorage {}

/// Merkt sich die Helligkeit pro Monitor (Schlüssel: EDID-Identität) in UserDefaults.
///
/// DDC- und Software-Wert liegen getrennt: Der DDC-Wert ist die Hintergrundbeleuchtung,
/// die der Monitor selbst behält; der Software-Wert ist der Faktor (Gamma oder Overlay),
/// der darauf wirkt. Würde ein DDC-Wert als Software-Wert übernommen, wäre der Monitor
/// doppelt abgedunkelt.
public struct BrightnessStore {
    public enum Mode: Sendable {
        case ddc
        case software
    }

    private let defaults: any PreferenceStorage

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    init(storage: any PreferenceStorage) {
        self.defaults = storage
    }

    public func brightness(for storageKey: String, mode: Mode) -> Double? {
        defaults.object(forKey: key(storageKey, mode)) as? Double
    }

    /// Schreibt nur, was sich ändert: Jeder Write ist ein Aufruf an cfprefsd, und die
    /// Lichtregelung speichert jedes Überblendungsziel.
    public func setBrightness(_ value: Double, for storageKey: String, mode: Mode) {
        guard brightness(for: storageKey, mode: mode) != value else { return }
        defaults.set(value, forKey: key(storageKey, mode))
    }

    /// Gewähltes Verfahren der Software-Dimmung; `nil`, wenn nie umgeschaltet wurde.
    public func dimmingMethod(for storageKey: String) -> DimmingMethod? {
        defaults.string(forKey: "dimmingMethod.\(storageKey)").flatMap(DimmingMethod.init(rawValue:))
    }

    public func setDimmingMethod(_ method: DimmingMethod, for storageKey: String) {
        guard dimmingMethod(for: storageKey) != method else { return }
        defaults.set(method.rawValue, forKey: "dimmingMethod.\(storageKey)")
    }

    /// DDC/CI für diesen Monitor erlaubt (Standard: ja). Aus heißt: nur Software-Dimmung,
    /// kein I2C-Verkehr zu diesem Monitor; die Hintergrundbeleuchtung bleibt, wie sie steht.
    public func isDDCEnabled(for storageKey: String) -> Bool {
        defaults.object(forKey: "ddcEnabled.\(storageKey)") as? Bool ?? true
    }

    public func setDDCEnabled(_ enabled: Bool, for storageKey: String) {
        guard isDDCEnabled(for: storageKey) != enabled else { return }
        defaults.set(enabled, forKey: "ddcEnabled.\(storageKey)")
    }

    /// Monitor von der Dimmung ausgenommen (Standard: nein). Gewähltes Software-Verfahren
    /// und DDC-Wahl bleiben gespeichert und gelten wieder, sobald er nicht mehr ignoriert wird.
    public func isIgnored(_ storageKey: String) -> Bool {
        defaults.object(forKey: "ignored.\(storageKey)") as? Bool ?? false
    }

    public func setIgnored(_ ignored: Bool, for storageKey: String) {
        guard isIgnored(storageKey) != ignored else { return }
        defaults.set(ignored, forKey: "ignored.\(storageKey)")
    }

    /// Der DDC-Schlüssel ist der aus Version 1, damit gespeicherte Werte erhalten bleiben.
    private func key(_ storageKey: String, _ mode: Mode) -> String {
        switch mode {
        case .ddc: "brightness.\(storageKey)"
        case .software: "softwareBrightness.\(storageKey)"
        }
    }
}
