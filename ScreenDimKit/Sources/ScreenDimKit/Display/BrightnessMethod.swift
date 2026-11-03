/// Wie ScreenDim die Helligkeit eines Monitors regelt: DDC/CI stellt die
/// Hintergrundbeleuchtung des Monitors ein (Standard, wo ein DDC-Kanal da ist); Gamma
/// und Overlay dimmen per Software und sind sonst der Rückfall.
public enum BrightnessMethod: String, CaseIterable, Sendable {
    case ddc
    case gamma
    case overlay

    public init(_ dimming: DimmingMethod) {
        self = switch dimming {
        case .gamma: .gamma
        case .overlay: .overlay
        }
    }

    /// Das Software-Verfahren; `nil` bei DDC/CI.
    public var dimming: DimmingMethod? {
        switch self {
        case .ddc: nil
        case .gamma: .gamma
        case .overlay: .overlay
        }
    }
}
