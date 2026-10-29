import Foundation

/// Merkt sich die Helligkeit pro Monitor (Schlüssel: EDID-Identität) in UserDefaults.
///
/// DDC- und Software-Wert liegen getrennt: Der DDC-Wert ist die Hintergrundbeleuchtung,
/// die der Monitor selbst behält; der Software-Wert ist der Gamma-Faktor, der darauf
/// wirkt. Würde ein DDC-Wert als Gamma übernommen, wäre der Monitor doppelt abgedunkelt.
struct BrightnessStore {
    enum Mode: Sendable {
        case ddc
        case software
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func brightness(for storageKey: String, mode: Mode) -> Double? {
        defaults.object(forKey: key(storageKey, mode)) as? Double
    }

    func setBrightness(_ value: Double, for storageKey: String, mode: Mode) {
        defaults.set(value, forKey: key(storageKey, mode))
    }

    /// Der DDC-Schlüssel ist der aus Version 1, damit gespeicherte Werte erhalten bleiben.
    private func key(_ storageKey: String, _ mode: Mode) -> String {
        switch mode {
        case .ddc: "brightness.\(storageKey)"
        case .software: "softwareBrightness.\(storageKey)"
        }
    }
}
