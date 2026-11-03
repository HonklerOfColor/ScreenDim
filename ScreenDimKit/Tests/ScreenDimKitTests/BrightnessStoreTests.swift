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

    @Test("DDC/CI ist standardmäßig an und lässt sich ausschalten")
    func ddcEnabled() {
        let store = BrightnessStore(storage: defaults)
        #expect(store.isDDCEnabled)
        store.setDDCEnabled(false)
        #expect(!store.isDDCEnabled)
        #expect(!BrightnessStore(storage: defaults).isDDCEnabled)
        store.setDDCEnabled(true)
        #expect(store.isDDCEnabled)
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
