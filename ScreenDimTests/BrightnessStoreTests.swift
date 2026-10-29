import Foundation
import Testing

@Suite("BrightnessStore: DDC und Software getrennt")
struct BrightnessStoreTests {
    private let defaults = UserDefaults(suiteName: "ScreenDimTests.store.\(UUID().uuidString)")!

    @Test("DDC- und Gamma-Wert überschreiben sich nicht")
    func separateModes() {
        let store = BrightnessStore(defaults: defaults)
        store.setBrightness(30, for: "1-2-3", mode: .ddc)
        #expect(store.brightness(for: "1-2-3", mode: .software) == nil)

        store.setBrightness(70, for: "1-2-3", mode: .software)
        #expect(store.brightness(for: "1-2-3", mode: .ddc) == 30)
        #expect(store.brightness(for: "1-2-3", mode: .software) == 70)
    }

    @Test("Wert aus Version 1 gilt als DDC-Wert, nicht als Gamma")
    func legacyKeyIsDDC() {
        defaults.set(40.0, forKey: "brightness.1-2-3")
        let store = BrightnessStore(defaults: defaults)
        #expect(store.brightness(for: "1-2-3", mode: .ddc) == 40)
        #expect(store.brightness(for: "1-2-3", mode: .software) == nil)
    }
}
