import Foundation

/// Merkt sich die Helligkeit pro Monitor (Schlüssel: EDID-Identität) in UserDefaults.
struct BrightnessStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func brightness(for storageKey: String) -> Double? {
        defaults.object(forKey: key(storageKey)) as? Double
    }

    func setBrightness(_ value: Double, for storageKey: String) {
        defaults.set(value, forKey: key(storageKey))
    }

    private func key(_ storageKey: String) -> String { "brightness.\(storageKey)" }
}
