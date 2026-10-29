import Foundation
import Network
import Observation

/// Ein per Bonjour gefundener Sensor.
public struct DiscoveredSensor: Identifiable, Hashable, Sendable {
    /// Bonjour-Instanzname, bei ESPHome der Gerätename (`screendim-desk-a1b2c3`).
    public let name: String
    /// `screendim-desk-a1b2c3.local`
    public let hostname: String
    /// TXT `fw`
    public let firmware: String?

    public var id: String { hostname }

    public init(name: String, hostname: String, firmware: String?) {
        self.name = name
        self.hostname = hostname
        self.firmware = firmware
    }

    /// ESPHome meldet Instanz- und Hostnamen gleich; der Hostname ergibt sich also aus dem
    /// Instanznamen. Dienste mit fremdem Protokoll (TXT `proto`) zählen nicht.
    public init?(serviceName: String, txt: [String: String]) {
        if let proto = txt["proto"], proto != "esphome-sse" { return nil }
        let host = serviceName.lowercased()
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return nil
        }
        self.init(name: serviceName, hostname: "\(host).local", firmware: txt["fw"])
    }

    public var endpoint: SensorEndpoint { SensorEndpoint(hostname: hostname) }
}

/// Sucht Sensoren (`_screendim._tcp`) im LAN, solange das Einstellungsfenster offen ist.
@MainActor
@Observable
public final class SensorBrowser {
    public private(set) var sensors: [DiscoveredSensor] = []
    public private(set) var isSearching = false
    /// macOS verweigert den Zugriff aufs lokale Netzwerk.
    public private(set) var isLocalNetworkDenied = false

    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SensorProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.sensor(from:)).sorted { $0.name < $1.name }
            MainActor.assumeIsolated { self?.sensors = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let (searching, denied): (Bool, Bool) = switch state {
            case .ready: (true, false)
            case .waiting(let error), .failed(let error): (false, Self.isPolicyDenied(error))
            default: (false, false)
            }
            MainActor.assumeIsolated {
                self?.isSearching = searching
                self?.isLocalNetworkDenied = denied
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    nonisolated private static func sensor(from result: NWBrowser.Result) -> DiscoveredSensor? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            for key in ["proto", "fw"] {
                txt[key] = record[key]
            }
        }
        return DiscoveredSensor(serviceName: name, txt: txt)
    }

    nonisolated private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 } // kDNSServiceErr_PolicyDenied
        return false
    }
}
