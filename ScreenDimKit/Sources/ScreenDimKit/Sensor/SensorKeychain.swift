import Foundation
import Security

/// Ablage des Kopplungscodes. In Tests ersetzbar.
public protocol SensorCredentialStore: Sendable {
    /// `nil`: kein Code gespeichert. Lässt sich der Speicher nicht lesen (Schlüsselbund
    /// gesperrt, Zugriff verweigert), wirft er; das heißt nicht „nicht gekoppelt“.
    func code(for hostname: String) throws(SensorKeychain.Failure) -> PairingCode?
    func save(_ code: PairingCode, for hostname: String) throws(SensorKeychain.Failure)
    func delete(_ hostname: String)
}

/// Kopplungscode im Schlüsselbund: generisches Passwort, Service `<Bundle-ID>.sensor`,
/// Account = Hostname des Sensors. Der Code liegt nur hier, nie in UserDefaults.
public struct SensorKeychain: SensorCredentialStore {
    public struct Failure: Error, Equatable {
        public let status: OSStatus
    }

    public let service: String

    public init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.andreastrabi.ScreenDim").sensor") {
        self.service = service
    }

    public func code(for hostname: String) throws(Failure) -> PairingCode? {
        var query = baseQuery(hostname)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return PairingCode(normalizing: String(decoding: data, as: UTF8.self))
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    public func save(_ code: PairingCode, for hostname: String) throws(Failure) {
        let data = Data(code.raw.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery(hostname) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(hostname)
            item.merge(update) { $1 }
            item[kSecAttrLabel as String] = "ScreenDim Sensor \(hostname)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(_ hostname: String) {
        SecItemDelete(baseQuery(hostname) as CFDictionary)
    }

    private func baseQuery(_ hostname: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostname,
        ]
    }
}
