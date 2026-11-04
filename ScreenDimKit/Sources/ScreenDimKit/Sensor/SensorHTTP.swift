import Foundation

/// Adresse eines Sensors im LAN, z. B. `screendim-desk-a1b2c3.local`.
public struct SensorEndpoint: Equatable, Hashable, Sendable {
    public let hostname: String

    public init(hostname: String) {
        self.hostname = hostname
    }

    /// `sensor/Ambient Light` → `http://<host>/sensor/Ambient%20Light`
    public func url(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = hostname
        components.path = "/" + path
        return components.url!
    }
}

/// Antwort einer einfachen GET-Anfrage an den Sensor.
public enum SensorResponse: Equatable, Sendable {
    case ok(Data)
    /// 401: Login nötig bzw. Code falsch.
    case unauthorized
    case status(Int)
    case timeout
    /// Host nicht gefunden, keine Verbindung, Netz aus.
    case unreachable
}

/// GET an den Sensor, wahlweise mit Digest-Login. In Tests ersetzbar.
public protocol SensorHTTP: Sendable {
    func get(_ url: URL, password: String?) async -> SensorResponse
}

/// Beantwortet die Digest-Abfrage des Sensors mit dem Kopplungscode. Ohne Code oder nach
/// einem abgelehnten Versuch übernimmt das System, das ohne gespeicherte Zugangsdaten die
/// 401-Antwort durchreicht.
final class DigestDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let password: String?

    init(password: String?) {
        self.password = password
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodHTTPBasic,
              let password, challenge.previousFailureCount == 0
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: SensorProtocol.user, password: password, persistence: .none))
    }
}

extension URLSessionConfiguration {
    /// Nur für den Sensor: keine Cookies, kein Cache, keine gespeicherten Zugangsdaten.
    static func sensor(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }
}

extension URLSession {
    static func sensor(timeout: TimeInterval) -> URLSession {
        URLSession(configuration: .sensor(timeout: timeout))
    }
}

/// `SensorHTTP` über URLSession mit Digest.
public final class URLSessionSensorHTTP: SensorHTTP {
    private let session: URLSession

    public init(timeout: TimeInterval = 5) {
        session = .sensor(timeout: timeout)
    }

    public func get(_ url: URL, password: String?) async -> SensorResponse {
        do {
            let (data, response) = try await session.data(from: url, delegate: DigestDelegate(password: password))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .ok(data)
            case 401: return .unauthorized
            default: return .status(status)
            }
        } catch {
            return Self.response(for: error)
        }
    }

    static func response(for error: any Error) -> SensorResponse {
        switch (error as? URLError)?.code {
        case .timedOut: .timeout
        case .userAuthenticationRequired, .userCancelledAuthentication: .unauthorized
        default: .unreachable
        }
    }
}

/// Wartezeit vor dem nächsten Verbindungsversuch: 1 s, 2 s, 4 s … höchstens 30 s. Bleibt
/// der Sensor weg (ausgeschaltet, anderes WLAN), steigt der Deckel nach `slowAfter`
/// Versuchen auf `slowMaximum`: Jeder Versuch kostet eine mDNS-Auflösung im Netz.
public struct ReconnectBackoff: Sendable {
    public static let initial: Duration = .seconds(1)
    public static let maximum: Duration = .seconds(30)
    public static let slowAfter = 10
    public static let slowMaximum: Duration = .seconds(120)
    private var current = initial
    private var attempts = 0

    public init() {}

    public mutating func next() -> Duration {
        attempts += 1
        let cap = attempts >= Self.slowAfter ? Self.slowMaximum : Self.maximum
        defer { current = min(current * 2, cap) }
        return min(current, cap)
    }

    public mutating func reset() {
        current = Self.initial
        attempts = 0
    }
}

/// Echter Sensor: hält `GET /events` (SSE) offen und verbindet nach Abbrüchen neu. Den
/// Hostnamen löst das System per mDNS auf, auch nach einem Wechsel der IP.
public final class SSESensorSource: SensorSource {
    /// Ohne Daten so lange gilt die Verbindung als tot. ESPHome pingt alle paar Sekunden.
    static let idleTimeout: TimeInterval = 30

    private let endpoint: SensorEndpoint
    private let code: PairingCode
    private let makeSession: @Sendable () -> URLSession
    private let sleep: @Sendable (Duration) async -> Void

    public convenience init(endpoint: SensorEndpoint, code: PairingCode) {
        self.init(endpoint: endpoint, code: code, makeSession: { .sensor(timeout: Self.idleTimeout) })
    }

    init(
        endpoint: SensorEndpoint,
        code: PairingCode,
        makeSession: @escaping @Sendable () -> URLSession,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.endpoint = endpoint
        self.code = code
        self.makeSession = makeSession
        self.sleep = sleep
    }

    public func events() -> AsyncStream<SensorEvent> {
        AsyncStream { continuation in
            let task = Task { [self] in
                // Eine Session je Strom, am Ende invalidiert: Ohne das lebt jede URLSession
                // ewig, und jede neue Quelle (Koppeln, Demo, Ein/Aus) käme dazu.
                let session = makeSession()
                await run(continuation, session: session)
                session.invalidateAndCancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<SensorEvent>.Continuation, session: URLSession) async {
        var backoff = ReconnectBackoff()
        var request = URLRequest(url: endpoint.url(SensorProtocol.eventsPath))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        continuation.yield(.connection(.searching))

        while !Task.isCancelled {
            do {
                let (bytes, response) = try await session.bytes(for: request, delegate: DigestDelegate(password: code.raw))
                switch (response as? HTTPURLResponse)?.statusCode {
                case 200:
                    break
                case 401:
                    sensorLog.notice("Sensor \(self.endpoint.hostname, privacy: .public): Code abgelehnt (401)")
                    continuation.yield(.connection(.pairingRequired))
                    return
                case let status:
                    sensorLog.error("Sensor \(self.endpoint.hostname, privacy: .public): HTTP \(status ?? 0)")
                    throw URLError(.badServerResponse)
                }
                sensorLog.notice("Sensor \(self.endpoint.hostname, privacy: .public): verbunden")
                continuation.yield(.connection(.connected))
                var parser = SSEParser()
                var received = false
                for try await byte in bytes {
                    guard let message = parser.consume(byte) else { continue }
                    // Erst eine Nachricht zählt als Verbindung. Schließt der Sensor den Strom
                    // gleich nach dem Status 200 (Sendestau, Socket-Limit), wächst die Pause
                    // weiter, statt im Sekundentakt neue Sockets zu belegen.
                    if !received {
                        received = true
                        backoff.reset()
                    }
                    if let event = ESPHomeEvents.event(from: message) {
                        continuation.yield(event)
                    }
                }
                sensorLog.notice("Sensor \(self.endpoint.hostname, privacy: .public): Strom beendet")
            } catch {
                guard !Task.isCancelled else { return }
                if URLSessionSensorHTTP.response(for: error) == .unauthorized {
                    continuation.yield(.connection(.pairingRequired))
                    return
                }
                sensorLog.notice("Sensor \(self.endpoint.hostname, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            continuation.yield(.connection(.searching))
            await sleep(backoff.next())
        }
    }
}
