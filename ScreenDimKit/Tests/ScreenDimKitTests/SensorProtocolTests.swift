import Foundation
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

@Suite("Schlüsselbund", .serialized)
struct SensorKeychainTests {
    /// Eigener Service je Lauf; der Test räumt hinterher auf.
    private let keychain = SensorKeychain(service: "com.andreastrabi.ScreenDim.tests.\(UUID().uuidString)")
    private let host = "screendim-desk-test01.local"

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
