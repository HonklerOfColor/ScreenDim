#if SCREENDIM_DIRECT
import CoreGraphics
import Foundation
import ScreenDimKit

// Nur in „ScreenDim Direct“: private API, im App Store nicht zulässig.

/// Helligkeit des eingebauten Displays über das private Framework DisplayServices
/// (per `dlsym`, wie IOAVService). Das eingebaute Panel kennt kein DDC; diese Klasse
/// bietet dieselbe Schnittstelle (nur VCP 0x10, Wertebereich 0…100), damit der
/// DisplayManager beide Arten von Monitor gleich behandeln kann.
final class BuiltInDisplayControl: DDCControlling {
    static let maximum: UInt16 = 100

    private let displayID: CGDirectDisplayID
    private let api: DisplayServicesAPI

    init?(displayID: CGDirectDisplayID) {
        guard let api = DisplayServicesAPI.shared, api.canChangeBrightness(displayID) else { return nil }
        self.displayID = displayID
        self.api = api
    }

    func read(_ code: VCPCode) async throws(DDCError) -> VCPReading {
        guard code == .brightness else { throw .unsupportedCode(code.rawValue) }
        var value: Float = 0
        let status = api.getBrightness(displayID, &value)
        guard status == 0 else { throw .readFailed(status) }
        let current = UInt16((min(max(value, 0), 1) * Float(Self.maximum)).rounded())
        return VCPReading(current: current, maximum: Self.maximum)
    }

    func write(_ code: VCPCode, value: UInt16) async throws(DDCError) {
        guard code == .brightness else { throw .unsupportedCode(code.rawValue) }
        let status = api.setBrightness(displayID, Float(min(value, Self.maximum)) / Float(Self.maximum))
        guard status == 0 else { throw .writeFailed(status) }
    }
}

/// Ob macOS das eingebaute Display selbst regelt („Helligkeit automatisch anpassen“).
/// Privates Framework CoreBrightness: `BrightnessSystemClient` mit `copyPropertyForKey:`
/// (Schlüssel `CBAutoBrightnessEnabled`, sonst `DisplayBrightnessAuto`). Gelesen wird nur
/// bei Bedarf, ohne Abfragen im Takt. `nil`, wenn Framework oder Schlüssel fehlen.
@MainActor
enum AutoBrightness {
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type
        else { return nil }
        return type.init()
    }()

    static func isEnabled() -> Bool? {
        let selector = NSSelectorFromString("copyPropertyForKey:")
        guard let client, client.responds(to: selector) else { return nil }
        for key in ["CBAutoBrightnessEnabled", "DisplayBrightnessAuto"] {
            if let value = client.perform(selector, with: key)?.takeRetainedValue() as? NSNumber {
                return value.boolValue
            }
        }
        return nil
    }
}

private struct DisplayServicesAPI: @unchecked Sendable {
    // @unchecked: reine C-Funktionszeiger, unveränderlich nach dem Laden.
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    let getBrightness: GetBrightness
    let setBrightness: SetBrightness
    let canChangeBrightness: CanChangeBrightness

    static let shared: DisplayServicesAPI? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness"),
              let can = dlsym(handle, "DisplayServicesCanChangeBrightness")
        else { return nil }
        return DisplayServicesAPI(
            getBrightness: unsafeBitCast(get, to: GetBrightness.self),
            setBrightness: unsafeBitCast(set, to: SetBrightness.self),
            canChangeBrightness: unsafeBitCast(can, to: CanChangeBrightness.self)
        )
    }()
}
#endif
