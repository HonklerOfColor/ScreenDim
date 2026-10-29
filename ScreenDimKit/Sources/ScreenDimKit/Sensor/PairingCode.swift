import Foundation

/// Kopplungscode des Sensors: acht Zeichen aus `0-9A-HJKMNP-TV-Z` (Crockford-Base32),
/// angezeigt als `ABCD-EFGH`. Er ist das Digest-Passwort für den Nutzer `screendim`.
public struct PairingCode: Equatable, Hashable, Sendable {
    public static let length = 8
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Acht Zeichen ohne Bindestrich; so geht der Code als Passwort an den Sensor.
    public let raw: String

    /// Normalisiert eine Eingabe: Großbuchstaben, ohne Bindestriche und Leerzeichen,
    /// O → 0, I und L → 1. `nil`, wenn danach nicht genau acht gültige Zeichen bleiben.
    public init?(normalizing input: String) {
        let mapped = input.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", "–", " ", "\t", "\n": nil
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
        }
        guard mapped.count == Self.length, mapped.allSatisfy(Self.alphabet.contains) else { return nil }
        raw = String(mapped)
    }

    /// `ABCD-EFGH`
    public var formatted: String {
        "\(raw.prefix(4))-\(raw.suffix(4))"
    }

    /// Antwort von `GET /text_sensor/Pairing Code` im Kopplungsfenster, z. B.
    /// `{"id":"text_sensor-pairing_code","value":"ABCD-EFGH","state":"ABCD-EFGH"}`.
    /// Nimmt `value`, sonst `state`.
    public static func fromPairingResponse(_ data: Data) -> PairingCode? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["value", "state"] {
            if let text = object[key] as? String, let code = PairingCode(normalizing: text) {
                return code
            }
        }
        return nil
    }
}
