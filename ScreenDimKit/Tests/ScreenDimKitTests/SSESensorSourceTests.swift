import Foundation
import Synchronization
import Testing
@testable import ScreenDimKit

/// Beantwortet jede Anfrage der Session mit Status und Body und beendet den Strom sofort.
final class StubSSEProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        var status = 200
        var body = ""
        var requests = 0
    }

    static let script = Mutex(Script())

    static func respond(status: Int, body: String) {
        script.withLock { $0 = Script(status: status, body: body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.script.withLock { script in
            script.requests += 1
            return (script.status, script.body)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Sammelt die Pausen, die die Quelle vor jedem neuen Versuch verlangt.
private final class SleepLog: Sendable {
    private let durations = Mutex<[Duration]>([])
    func record(_ duration: Duration) { durations.withLock { $0.append(duration) } }
    var all: [Duration] { durations.withLock { $0 } }
}

@Suite("Backoff")
struct ReconnectBackoffTests {
    @Test("1, 2, 4 … 30 s; nach zehn Versuchen bis 120 s; Reset fängt vorn an")
    func sequence() {
        var backoff = ReconnectBackoff()
        let seconds = (0..<13).map { _ in backoff.next().components.seconds }
        #expect(seconds == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 60, 120, 120])
        backoff.reset()
        #expect(backoff.next() == .seconds(1))
    }
}

@Suite("SSE-Quelle: Verbindung und Backoff", .serialized)
struct SSESensorSourceTests {
    private static let ping = "event: ping\ndata: \n\n"

    /// Quelle mit Stub-Session; `sleeps` sammelt die Pausen vor jedem neuen Versuch.
    private func makeSource(sleeps: SleepLog) throws -> SSESensorSource {
        SSESensorSource(
            endpoint: SensorEndpoint(hostname: "stub.local"),
            code: try #require(PairingCode(normalizing: "ABCD-EFGH")),
            makeSession: {
                let configuration = URLSessionConfiguration.sensor(timeout: 5)
                configuration.protocolClasses = [StubSSEProtocol.self]
                return URLSession(configuration: configuration)
            },
            sleep: { sleeps.record($0) }
        )
    }

    private func connections(until count: Int, sleeps: SleepLog) async throws -> [SensorEvent] {
        var received: [SensorEvent] = []
        var connected = 0
        for await event in try makeSource(sleeps: sleeps).events() {
            received.append(event)
            if event == .connection(.connected) { connected += 1 }
            if connected == count { break }
        }
        return received
    }

    @Test("200 ohne eine einzige Nachricht zählt nicht als Verbindung: die Pause wächst")
    func emptyStreamGrowsBackoff() async throws {
        StubSSEProtocol.respond(status: 200, body: "")
        let sleeps = SleepLog()

        _ = try await connections(until: 4, sleeps: sleeps)

        #expect(Array(sleeps.all.prefix(3)) == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test("Nach einer Nachricht (auch nur ein Ping) beginnt die Pause wieder bei 1 s")
    func messageResetsBackoff() async throws {
        StubSSEProtocol.respond(status: 200, body: Self.ping)
        let sleeps = SleepLog()

        _ = try await connections(until: 4, sleeps: sleeps)

        #expect(Array(sleeps.all.prefix(3)) == [.seconds(1), .seconds(1), .seconds(1)])
    }

    @Test("401: genau ein „Kopplung nötig“, dann endet der Strom ohne neuen Versuch")
    func unauthorizedEndsStream() async throws {
        StubSSEProtocol.respond(status: 401, body: "")
        let sleeps = SleepLog()
        let requestsBefore = StubSSEProtocol.script.withLock { $0.requests }

        var received: [SensorEvent] = []
        for await event in try makeSource(sleeps: sleeps).events() {
            received.append(event)
        }

        #expect(received == [.connection(.searching), .connection(.pairingRequired)])
        #expect(StubSSEProtocol.script.withLock { $0.requests } == requestsBefore + 1)
        #expect(sleeps.all.isEmpty)
    }
}
