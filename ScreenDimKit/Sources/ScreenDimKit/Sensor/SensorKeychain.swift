import Foundation
import Security
import Synchronization

/// Ablage des Kopplungscodes. In Tests ersetzbar.
public protocol SensorCredentialStore: Sendable {
    /// `nil`: kein Code gespeichert. Lässt sich der Speicher nicht lesen (Schlüsselbund
    /// gesperrt, Zugriff verweigert), wirft er; das heißt nicht „nicht gekoppelt“.
    func code(for hostname: String) throws(SensorKeychain.Failure) -> PairingCode?
    func save(_ code: PairingCode, for hostname: String) throws(SensorKeychain.Failure)
    func delete(_ hostname: String)
}

/// Die `SecItem…`-Aufrufe des Schlüsselbunds. In Tests ersetzbar.
protocol KeychainItems: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus
    @discardableResult
    func delete(_ query: [String: Any]) -> OSStatus
}

/// Der echte Schlüsselbund.
struct SystemKeychainItems: KeychainItems {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], with attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Kopplungscode im Schlüsselbund: generisches Passwort, Service `<Bundle-ID>.sensor`,
/// Account = Hostname des Sensors. Der Code liegt nur hier, nie in UserDefaults.
public struct SensorKeychain: SensorCredentialStore {
    public struct Failure: Error, Equatable {
        public let status: OSStatus
    }

    public let service: String
    private let items: any KeychainItems
    /// Hostnamen, deren Eintrag in diesem Lauf schon umgestellt wurde oder es versucht hat.
    /// Geteilt von allen Kopien dieses Werts.
    private let migrated = MigrationLedger()

    public init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.andreastrabi.ScreenDim").sensor") {
        self.init(service: service, items: SystemKeychainItems())
    }

    init(service: String, items: any KeychainItems) {
        self.service = service
        self.items = items
    }

    /// Ein gefundener Eintrag mit anderer Zugänglichkeit (ältere Versionen:
    /// `…AfterFirstUnlock`, also auch im Backup und auf anderen Geräten) wird dabei
    /// umgestellt, einmal je Lauf und Host (`migrateAccessibility`).
    public func code(for hostname: String) throws(Failure) -> PairingCode? {
        var query = baseQuery(hostname)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = items.copyMatching(query)
        switch status {
        case errSecSuccess:
            let item = result as? [String: Any]
            migrateAccessibility(of: hostname, current: item?[kSecAttrAccessible as String] as? String)
            guard let data = item?[kSecValueData as String] as? Data else { return nil }
            return PairingCode(normalizing: String(decoding: data, as: UTF8.self))
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    /// Lesbar nach der ersten Entsperrung (die App startet beim Login) und nur auf diesem
    /// Mac: Der Code wandert in kein Backup und auf kein anderes Gerät.
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    /// Was beim Speichern geschrieben wird, Code und Zugänglichkeit. Weil auch ein
    /// bestehender Eintrag beides bekommt, wandern ältere Einträge beim Speichern mit um.
    static func attributes(for code: PairingCode) -> [String: Any] {
        [
            kSecValueData as String: Data(code.raw.utf8),
            kSecAttrAccessible as String: accessibility,
        ]
    }

    /// Stellt die Zugänglichkeit eines gefundenen Eintrags um, ohne auf das nächste
    /// Speichern zu warten. Höchstens ein Versuch je Lauf und Host: Der dateibasierte
    /// Schlüsselbund von macOS meldet die Zugänglichkeit womöglich gar nicht zurück. Ein
    /// Fehler ändert nichts am Lesen; geloggt wird nur der Status, nie der Code.
    private func migrateAccessibility(of hostname: String, current: String?) {
        guard current != Self.accessibility as String, migrated.claim(hostname) else { return }
        let status = items.update(baseQuery(hostname), with: [kSecAttrAccessible as String: Self.accessibility])
        if status == errSecSuccess {
            sensorLog.notice("Schlüsselbund: Eintrag auf „nur dieses Gerät“ umgestellt")
        } else {
            sensorLog.error("Schlüsselbund: Eintrag nicht umgestellt (Status \(status))")
        }
    }

    public func save(_ code: PairingCode, for hostname: String) throws(Failure) {
        let update = Self.attributes(for: code)
        var status = items.update(baseQuery(hostname), with: update)
        if status == errSecItemNotFound {
            var item = baseQuery(hostname)
            item.merge(update) { $1 }
            item[kSecAttrLabel as String] = "ScreenDim Sensor \(hostname)"
            status = items.add(item)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(_ hostname: String) {
        items.delete(baseQuery(hostname))
    }

    private func baseQuery(_ hostname: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostname,
        ]
    }
}

/// Merkt sich, für welche Hostnamen die Umstellung schon lief.
private final class MigrationLedger: Sendable {
    private let hostnames = Mutex<Set<String>>([])

    /// `true` beim ersten Aufruf je Hostname, danach `false`.
    func claim(_ hostname: String) -> Bool {
        hostnames.withLock { $0.insert(hostname).inserted }
    }
}
