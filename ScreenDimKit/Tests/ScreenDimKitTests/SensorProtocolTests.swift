import Foundation
import Security
import Testing
@testable import ScreenDimKit

@Suite("Kopplungscode")
struct PairingCodeTests {
    @Test("Normalisierung: Groß, ohne Trenner, O→0, I/L→1", arguments: [
        ("ABCD-EFGH", "ABCDEFGH"),
        ("abcd efgh", "ABCDEFGH"),
        (" ab-cd-ef-gh ", "ABCDEFGH"),
        ("OOIL-1234", "00111234"),
        ("z9y8x7w6", "Z9Y8X7W6"),
    ])
    func normalizes(input: String, expected: String) throws {
        let code = try #require(PairingCode(normalizing: input))
        #expect(code.raw == expected)
    }

    @Test("Ungültig: falsche Länge oder Zeichen außerhalb des Alphabets", arguments: [
        "", "ABCD-EFG", "ABCD-EFGHJ", "ABCD-EFGU", "ABCD#EFG", "ÄBCD-EFGH",
    ])
    func rejects(input: String) {
        #expect(PairingCode(normalizing: input) == nil)
    }

    @Test("Anzeige mit Bindestrich")
    func formatted() {
        #expect(PairingCode(normalizing: "abcdefgh")?.formatted == "ABCD-EFGH")
    }

    @Test("JSON der Kopplungsantwort: value, sonst state")
    func parsesResponse() {
        let full = #"{"id":"text_sensor-pairing_code","name":"Pairing Code","value":"ABCD-EFGH","state":"ABCD-EFGH"}"#
        #expect(PairingCode.fromPairingResponse(Data(full.utf8))?.raw == "ABCDEFGH")

        let stateOnly = #"{"id":"text_sensor-pairing_code","state":"wxyz-1234"}"#
        #expect(PairingCode.fromPairingResponse(Data(stateOnly.utf8))?.raw == "WXYZ1234")

        let badValue = #"{"id":"text_sensor-pairing_code","value":"","state":"K7M2-P9QR"}"#
        #expect(PairingCode.fromPairingResponse(Data(badValue.utf8))?.raw == "K7M2P9QR")
    }

    @Test("JSON ohne gültigen Code")
    func rejectsResponse() {
        #expect(PairingCode.fromPairingResponse(Data(#"{"id":"x","value":"nope"}"#.utf8)) == nil)
        #expect(PairingCode.fromPairingResponse(Data("kein json".utf8)) == nil)
        #expect(PairingCode.fromPairingResponse(Data(#"["ABCD-EFGH"]"#.utf8)) == nil)
    }
}

@Suite("SSE-Parser und ESPHome-Ereignisse")
struct ServerSentEventsTests {
    private func messages(_ text: String) -> [SSEMessage] {
        var parser = SSEParser()
        return Array(text.utf8).compactMap { parser.consume($0) }
    }

    @Test("Nachrichten enden an der Leerzeile; CRLF, Kommentare und mehrzeilige Daten")
    func parsesStream() {
        let stream = ": hallo\r\nretry: 30000\r\nevent: ping\r\ndata: {}\r\n\r\n"
            + "event: state\ndata: zeile1\ndata:zeile2\nid: 7\n\n"
            + "data: ohne Typ\n\n"
            + "event: leer\n\n"
        #expect(messages(stream) == [
            SSEMessage(event: "ping", data: "{}"),
            SSEMessage(event: "state", data: "zeile1\nzeile2"),
            SSEMessage(event: "message", data: "ohne Typ"),
        ])
    }

    @Test("Unvollständige Nachricht wird nicht ausgeliefert")
    func incomplete() {
        #expect(messages("event: state\ndata: {}\n").isEmpty)
    }

    private func event(_ json: String, type: String = "state") -> SensorEvent? {
        ESPHomeEvents.event(from: SSEMessage(event: type, data: json))
    }

    @Test("Anwesenheit über binary_sensor/Presence (Name) und binary_sensor-presence (Object-ID)")
    func presence() {
        #expect(event(#"{"id":"binary_sensor-presence","value":true,"state":"ON"}"#) == .presence(true))
        #expect(event(#"{"id":"binary_sensor/Presence","value":false,"state":"OFF"}"#) == .presence(false))
        #expect(event(#"{"id":"binary_sensor-presence","name_id":"binary_sensor/Presence","state":"ON"}"#) == .presence(true))
        #expect(event(#"{"id":"binary_sensor-presence","state":"OFF"}"#) == .presence(false))
    }

    @Test("Licht über sensor/Ambient Light, Zahl oder Text mit Einheit")
    func lux() {
        #expect(event(#"{"id":"sensor-ambient_light","value":123.4,"state":"123.4 lx"}"#) == .lux(123.4))
        #expect(event(#"{"id":"sensor/Ambient Light","value":0,"state":"0.0 lx"}"#) == .lux(0))
        #expect(event(#"{"id":"sensor/Ambient Light","state":"88.5 lx"}"#) == .lux(88.5))
        #expect(event(#"{"id":"sensor-ambient_light","value":null,"state":"NA"}"#) == nil)
    }

    @Test("Ping ist ein Lebenszeichen; fremde IDs und Log-Nachrichten zählen nicht")
    func others() {
        #expect(event(#"{"title":"screendim-desk"}"#, type: "ping") == .heartbeat)
        #expect(event(#"{"id":"sensor-wifi_signal","value":-60}"#) == nil)
        #expect(event(#"{"id":"binary_sensor-presence","value":true}"#, type: "log") == nil)
        #expect(event("kein json") == nil)
    }

    @Test("Max Distance: beim Verbinden mit Bereich und Schritt (als Text), danach nur der Wert")
    func maxDistance() {
        #expect(event(#"{"id":"number/Max Distance","name":"Max Distance","value":"120","state":"120 cm","min_value":"30","max_value":"800","step":"10","mode":2,"uom":"cm"}"#)
            == .maxDistance(SensorNumber(value: 120, range: 30...800, step: 10)))
        #expect(event(#"{"id":"number/Max Distance","value":"150","state":"150 cm"}"#)
            == .maxDistance(SensorNumber(value: 150)))
        #expect(event(#"{"id":"number-max_distance","value":90,"state":"90 cm"}"#) == .maxDistance(SensorNumber(value: 90)))
        #expect(event(#"{"id":"number/Max Distance","state":"200 cm"}"#) == .maxDistance(SensorNumber(value: 200)))
        // NaN (Wert noch nicht gesetzt) und unsinnige Grenzen.
        #expect(event(#"{"id":"number/Max Distance","value":"NaN","state":"NA"}"#) == nil)
        #expect(event(#"{"id":"number/Max Distance","value":"120","min_value":"800","max_value":"30"}"#)
            == .maxDistance(SensorNumber(value: 120)))
    }

    @Test("Entfernung: Zahl in cm; niemand erkannt (null, NA) heißt nil")
    func distance() {
        #expect(event(#"{"id":"sensor/Distance","value":85,"state":"85 cm"}"#) == .distance(85))
        #expect(event(#"{"id":"sensor-distance","value":42.0,"state":"42 cm"}"#) == .distance(42))
        #expect(event(#"{"id":"sensor/Distance","value":null,"state":"NA"}"#) == .distance(nil))
        #expect(event(#"{"id":"sensor/Distance","state":"NA"}"#) == .distance(nil))
    }

    @Test("Object-ID aus dem Pfad")
    func objectID() {
        #expect(ESPHomeEvents.objectID(forPath: "sensor/Ambient Light") == "sensor-ambient_light")
        #expect(ESPHomeEvents.objectID(forPath: "text_sensor/Pairing Code") == "text_sensor-pairing_code")
    }

    @Test("URL mit Leerzeichen im Pfad")
    func endpoint() {
        let endpoint = SensorEndpoint(hostname: "screendim-desk-a1b2c3.local")
        #expect(endpoint.url(SensorProtocol.luxPath).absoluteString == "http://screendim-desk-a1b2c3.local/sensor/Ambient%20Light")
        #expect(endpoint.url(SensorProtocol.eventsPath).absoluteString == "http://screendim-desk-a1b2c3.local/events")
        #expect(endpoint.url(
            SensorProtocol.setPath(SensorProtocol.maxDistancePath),
            query: [URLQueryItem(name: "value", value: "150")]
        ).absoluteString == "http://screendim-desk-a1b2c3.local/number/Max%20Distance/set?value=150")
    }

    @Test("Bonjour-Dienst → Sensor")
    func discovered() {
        let sensor = DiscoveredSensor(serviceName: "screendim-desk-A1B2C3", txt: ["proto": "esphome-sse", "fw": "1.2.0"])
        #expect(sensor?.hostname == "screendim-desk-a1b2c3.local")
        #expect(sensor?.firmware == "1.2.0")
        #expect(DiscoveredSensor(serviceName: "anderes", txt: ["proto": "mqtt"]) == nil)
        #expect(DiscoveredSensor(serviceName: "mit Leerzeichen", txt: [:]) == nil)
    }
}

@Suite("Login am Sensor: nur Digest")
struct DigestDelegateTests {
    /// Was der Delegate geantwortet hat; die Antwort kommt synchron.
    private final class Answer: @unchecked Sendable {
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
    }

    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    /// Eine Abfrage des Sensors mit diesem Verfahren; der Task startet nie, kein Netz.
    private func answer(_ method: String, password: String?, failures: Int = 0) -> Answer {
        let space = URLProtectionSpace(
            host: "screendim-desk-a1b2c3.local", port: 80, protocol: NSURLProtectionSpaceHTTP,
            realm: "screendim", authenticationMethod: method
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: failures,
            failureResponse: nil, error: nil, sender: Sender()
        )
        let task = URLSession.shared.dataTask(with: SensorEndpoint(hostname: "screendim-desk-a1b2c3.local").url(SensorProtocol.eventsPath))
        let answer = Answer()
        DigestDelegate(password: password).urlSession(.shared, task: task, didReceive: challenge) { disposition, credential in
            answer.disposition = disposition
            answer.credential = credential
        }
        return answer
    }

    @Test("Basic wird abgebrochen, mit und ohne Code; der Code geht nie hinaus", arguments: ["ABCDEFGH", nil] as [String?])
    func rejectsBasic(password: String?) {
        let answer = answer(NSURLAuthenticationMethodHTTPBasic, password: password)
        #expect(answer.disposition == .cancelAuthenticationChallenge)
        #expect(answer.credential == nil)
    }

    @Test("Digest bekommt Nutzer und Code, nur beim ersten Versuch und nicht gespeichert")
    func answersDigest() {
        let first = answer(NSURLAuthenticationMethodHTTPDigest, password: "ABCDEFGH")
        #expect(first.disposition == .useCredential)
        #expect(first.credential?.user == SensorProtocol.user)
        #expect(first.credential?.password == "ABCDEFGH")
        #expect(first.credential?.persistence == URLCredential.Persistence.none)
        // Abgelehnt oder ohne Code: Das System reicht die 401-Antwort durch.
        #expect(answer(NSURLAuthenticationMethodHTTPDigest, password: "ABCDEFGH", failures: 1).disposition == .performDefaultHandling)
        #expect(answer(NSURLAuthenticationMethodHTTPDigest, password: nil).disposition == .performDefaultHandling)
    }

    @Test("Andere Verfahren bekommen den Code nicht")
    func othersGetNoCode() {
        let ntlm = answer(NSURLAuthenticationMethodNTLM, password: "ABCDEFGH")
        #expect(ntlm.disposition == .performDefaultHandling)
        #expect(ntlm.credential == nil)
    }
}

@Suite("Schlüsselbund", .serialized)
struct SensorKeychainTests {
    /// Eigener Service je Lauf; der Test räumt hinterher auf.
    private let keychain = SensorKeychain(service: "com.andreastrabi.ScreenDim.tests.\(UUID().uuidString)")
    private let host = "screendim-desk-test01.local"

    @Test("Speichern schreibt Code und Zugänglichkeit „nur dieses Gerät, nach erster Entsperrung“, auch beim Überschreiben")
    func attributes() throws {
        let code = try #require(PairingCode(normalizing: "ABCD-EFGH"))
        let attributes = SensorKeychain.attributes(for: code)
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecValueData as String] as? Data == Data("ABCDEFGH".utf8))
        #expect(attributes.count == 2)
    }

    @Test("Speichern, lesen, überschreiben, löschen")
    func roundTrip() throws {
        defer { keychain.delete(host) }
        #expect(try keychain.code(for: host) == nil)

        let first = try #require(PairingCode(normalizing: "ABCD-EFGH"))
        try keychain.save(first, for: host)
        #expect(try keychain.code(for: host) == first)

        let second = try #require(PairingCode(normalizing: "K7M2-P9QR"))
        try keychain.save(second, for: host)
        #expect(try keychain.code(for: host) == second)
        #expect(try keychain.code(for: "anderer-host.local") == nil)

        keychain.delete(host)
        #expect(try keychain.code(for: host) == nil)
    }
}

@Suite("Schlüsselbund: ältere Einträge umstellen")
struct SensorKeychainMigrationTests {
    private static let service = "com.andreastrabi.ScreenDim.sensor"
    private static let host = "screendim-desk-a1b2c3.local"
    private static let thisDeviceOnly = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private static let oldAccessibility = kSecAttrAccessibleAfterFirstUnlock as String

    private let items = MemoryKeychainItems()
    private let keychain: SensorKeychain

    init() {
        keychain = SensorKeychain(service: Self.service, items: items)
    }

    private func store(_ code: String, accessible: String?, host: String = Self.host) {
        items.put(.init(data: Data(code.utf8), accessible: accessible), service: Self.service, account: host)
    }

    @Test("Älterer Eintrag: Code gelesen, einmal nur die Zugänglichkeit auf „nur dieses Gerät“ gesetzt")
    func migratesOnce() throws {
        store("ABCDEFGH", accessible: Self.oldAccessibility)
        let expected = try #require(PairingCode(normalizing: "ABCD-EFGH"))

        #expect(try keychain.code(for: Self.host) == expected)
        #expect(items.updates == [.init(
            service: Self.service, account: Self.host,
            keys: [kSecAttrAccessible as String], accessible: Self.thisDeviceOnly
        )])
        #expect(items.item(service: Self.service, account: Self.host) == .init(data: Data("ABCDEFGH".utf8), accessible: Self.thisDeviceOnly))

        #expect(try keychain.code(for: Self.host) == expected)
        #expect(items.updates.count == 1)
    }

    @Test("Schon „nur dieses Gerät“: kein Update")
    func currentEntryUntouched() throws {
        store("ABCDEFGH", accessible: Self.thisDeviceOnly)
        #expect(try keychain.code(for: Self.host) != nil)
        #expect(items.updates.isEmpty)
    }

    @Test("Schlüsselbund meldet die Zugänglichkeit nicht: ein Versuch je Lauf, nicht bei jedem Lesen")
    func unreportedAccessibilityTriedOnce() throws {
        items.setReportsAccessibility(false)
        store("ABCDEFGH", accessible: Self.thisDeviceOnly)
        #expect(try keychain.code(for: Self.host) != nil)
        #expect(try keychain.code(for: Self.host) != nil)
        #expect(items.updates.count == 1)

        // Kopien teilen sich das Gedächtnis.
        let copy = keychain
        #expect(try copy.code(for: Self.host) != nil)
        #expect(items.updates.count == 1)
    }

    @Test("Update scheitert: Code trotzdem gelesen, kein Fehler, kein zweiter Versuch")
    func failedUpdateKeepsCode() throws {
        store("ABCDEFGH", accessible: Self.oldAccessibility)
        items.failUpdates(with: errSecInteractionNotAllowed)
        #expect(try keychain.code(for: Self.host) == PairingCode(normalizing: "ABCD-EFGH"))
        #expect(try keychain.code(for: Self.host) != nil)
        #expect(items.updates.count == 1)
        #expect(items.item(service: Self.service, account: Self.host)?.accessible == Self.oldAccessibility)
    }

    @Test("Kein Eintrag: nichts gelesen, nichts umgestellt; jeder Host für sich")
    func perHost() throws {
        #expect(try keychain.code(for: Self.host) == nil)
        #expect(items.updates.isEmpty)

        let other = "screendim-desk-d4e5f6.local"
        store("ABCDEFGH", accessible: Self.oldAccessibility)
        store("K7M2P9QR", accessible: Self.oldAccessibility, host: other)
        #expect(try keychain.code(for: Self.host) != nil)
        #expect(try keychain.code(for: other) == PairingCode(normalizing: "K7M2-P9QR"))
        #expect(items.updates.map(\.account) == [Self.host, other])
    }

    @Test("Speichern legt mit „nur dieses Gerät“ an und überschreibt Code und Zugänglichkeit")
    func saveWritesAccessibility() throws {
        let code = try #require(PairingCode(normalizing: "ABCD-EFGH"))
        try keychain.save(code, for: Self.host)
        #expect(items.item(service: Self.service, account: Self.host) == .init(data: Data("ABCDEFGH".utf8), accessible: Self.thisDeviceOnly))

        store("ABCDEFGH", accessible: Self.oldAccessibility)
        let second = try #require(PairingCode(normalizing: "K7M2-P9QR"))
        try keychain.save(second, for: Self.host)
        #expect(items.item(service: Self.service, account: Self.host) == .init(data: Data("K7M2P9QR".utf8), accessible: Self.thisDeviceOnly))
    }
}
