#if SCREENDIM_DIRECT
import CoreGraphics
import ScreenDimKit

/// Steuerkanäle der Direct-Variante: DDC/CI für externe Monitore, DisplayServices für
/// das eingebaute Display. Die App-Store-Variante kompiliert diese Dateien nicht.
enum DirectControls {
    static func external(avServiceID: UInt64, label: String, timing: DDCTiming) -> (any DDCControlling)? {
        IOAVServiceTransport(registryEntryID: avServiceID).map { DDCService(transport: $0, label: label, timing: timing) }
    }

    static func builtIn(displayID: CGDirectDisplayID) -> (any DDCControlling)? {
        BuiltInDisplayControl(displayID: displayID)
    }

    /// Eingebauter Lichtsensor (MacBook, iMac); `nil` auf Macs ohne Sensor.
    static func lightSensor() -> (any SensorSource)? {
        BuiltInLightSensor()
    }

    /// „Helligkeit automatisch anpassen“ in macOS; `nil`, wenn nicht lesbar.
    @MainActor
    static func autoBrightness() -> Bool? {
        AutoBrightness.isEnabled()
    }
}
#endif
