/// Wie ScreenDim die Helligkeit eines Monitors regelt: DDC/CI stellt die
/// Hintergrundbeleuchtung des Monitors ein (Standard, wo ein DDC-Kanal da ist); Gamma
/// und Overlay dimmen per Software und sind sonst der Rückfall. „Ignorieren“ nimmt den
/// Monitor ganz aus der Dimmung, etwa einen Beamer.
public enum BrightnessMethod: String, CaseIterable, Sendable {
    case ddc
    case gamma
    case overlay
    case ignored

    public init(_ dimming: DimmingMethod) {
        self = switch dimming {
        case .gamma: .gamma
        case .overlay: .overlay
        }
    }

    /// Das Software-Verfahren; `nil` bei DDC/CI und „Ignorieren“.
    public var dimming: DimmingMethod? {
        switch self {
        case .ddc, .ignored: nil
        case .gamma: .gamma
        case .overlay: .overlay
        }
    }
}
