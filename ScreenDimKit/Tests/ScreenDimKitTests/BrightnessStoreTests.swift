import Foundation
import Testing
@testable import ScreenDimKit

@Suite("BrightnessStore: DDC und Software getrennt")
struct BrightnessStoreTests {
    private let defaults = MemoryPreferences()

    @Test("DDC- und Gamma-Wert überschreiben sich nicht")
    func separateModes() {
        let store = BrightnessStore(storage: defaults)
        store.setBrightness(30, for: "1-2-3", mode: .ddc)
        #expect(store.brightness(for: "1-2-3", mode: .software) == nil)

        store.setBrightness(70, for: "1-2-3", mode: .software)
        #expect(store.brightness(for: "1-2-3", mode: .ddc) == 30)
        #expect(store.brightness(for: "1-2-3", mode: .software) == 70)
    }

    @Test("Wert aus Version 1 gilt als DDC-Wert, nicht als Gamma")
    func legacyKeyIsDDC() {
        defaults.set(40.0, forKey: "brightness.1-2-3")
        let store = BrightnessStore(storage: defaults)
        #expect(store.brightness(for: "1-2-3", mode: .ddc) == 40)
        #expect(store.brightness(for: "1-2-3", mode: .software) == nil)
    }

    @Test("DDC/CI ist je Monitor standardmäßig an und lässt sich abwählen")
    func ddcEnabled() {
        let store = BrightnessStore(storage: defaults)
        #expect(store.isDDCEnabled(for: "1-2-3"))
        store.setDDCEnabled(false, for: "1-2-3")
        #expect(!store.isDDCEnabled(for: "1-2-3"))
        #expect(store.isDDCEnabled(for: "4-5-6"))
        #expect(!BrightnessStore(storage: defaults).isDDCEnabled(for: "1-2-3"))
        store.setDDCEnabled(true, for: "1-2-3")
        #expect(store.isDDCEnabled(for: "1-2-3"))
    }

    @Test("Verfahren der Software-Dimmung pro Monitor")
    func dimmingMethod() {
        let store = BrightnessStore(storage: defaults)
        #expect(store.dimmingMethod(for: "1-2-3") == nil)
        store.setDimmingMethod(.overlay, for: "1-2-3")
        #expect(store.dimmingMethod(for: "1-2-3") == .overlay)
        #expect(store.dimmingMethod(for: "4-5-6") == nil)
    }
}
