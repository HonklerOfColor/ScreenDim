import Foundation

/// Eine vollständige Server-Sent-Events-Nachricht.
public struct SSEMessage: Equatable, Sendable {
    /// Feld `event`; ohne Feld `message`.
    public var event: String
    public var data: String
}

/// Zerlegt einen SSE-Strom (text/event-stream) Byte für Byte in Nachrichten. Eine Leerzeile
/// schließt eine Nachricht ab; Zeilen mit `:` am Anfang sind Kommentare.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var event = ""
    private var data: [String] = []

    public init() {}

    /// - Returns: die Nachricht, die dieses Byte abschließt.
    public mutating func consume(_ byte: UInt8) -> SSEMessage? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        return consume(line: String(decoding: line, as: UTF8.self))
    }

    /// Für ganze Zeilen ohne Zeilenende.
    public mutating func consume(line: String) -> SSEMessage? {
        if line.isEmpty {
            defer {
                event = ""
                data = []
            }
            guard !data.isEmpty else { return nil }
            return SSEMessage(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break // id, retry
        }
        return nil
    }
}

/// Übersetzt Nachrichten des ESPHome-Webservers in Sensorereignisse.
///
/// `state`-Nachrichten tragen JSON wie `{"id":"binary_sensor-presence","value":true,
/// "state":"ON"}`. Die ID kommt je nach ESPHome-Version als `binary_sensor-presence`
/// (Object-ID) oder als `binary_sensor/Presence` (Name, auch im Feld `name_id`); beides passt.
public enum ESPHomeEvents {
    public static func event(
        from message: SSEMessage,
        presencePath: String = SensorProtocol.presencePath,
        luxPath: String = SensorProtocol.luxPath,
        maxDistancePath: String = SensorProtocol.maxDistancePath,
        distancePath: String = SensorProtocol.distancePath
    ) -> SensorEvent? {
        switch message.event {
        case "ping": return .heartbeat
        case "state": break
        default: return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.data.utf8)) as? [String: Any],
              let id = object["id"] as? String
        else { return nil }
        let ids = [id, object["name_id"] as? String].compactMap(\.self)
        let value = object["value"]
        let state = object["state"] as? String

        if ids.contains(where: { matches($0, path: presencePath) }) {
            if let flag = value as? Bool { return .presence(flag) }
            switch state?.uppercased() {
            case "ON": return .presence(true)
            case "OFF": return .presence(false)
            default: return nil
            }
        }
        if ids.contains(where: { matches($0, path: luxPath) }) {
            // JSONSerialization liefert Zahlen als NSNumber; `Bool` vorher ausschließen.
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite {
                return .lux(number.doubleValue)
            }
            if let lux = state.flatMap(leadingNumber), lux.isFinite { return .lux(lux) }
            return nil
        }
        if ids.contains(where: { matches($0, path: maxDistancePath) }) {
            // ESPHome schickt Wert, Bereich und Schritt einer Number als Text („120“); beim
            // Verbinden mit Bereich und Schritt, danach nur den Wert.
            guard let cm = number(value) ?? state.flatMap(leadingNumber), cm.isFinite else { return nil }
            var range: ClosedRange<Double>?
            if let low = number(object["min_value"]), let high = number(object["max_value"]), low <= high {
                range = low...high
            }
            let step = number(object["step"]).flatMap { $0 > 0 ? $0 : nil }
            return .maxDistance(SensorNumber(value: cm, range: range, step: step))
        }
        if ids.contains(where: { matches($0, path: distancePath) }) {
            // Sieht das Radar niemanden, meldet die Firmware NaN: Wert `null`, Zustand „NA“.
            let cm = number(value) ?? state.flatMap(leadingNumber)
            return .distance(cm.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
        return nil
    }

    /// Zahl aus JSON: `NSNumber` (ohne `Bool`) oder Text wie „120“; sonst `nil`.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)) {
            return number.isFinite ? number : nil
        }
        return nil
    }

    private static let presenceObjectID = objectID(forPath: SensorProtocol.presencePath)
    private static let luxObjectID = objectID(forPath: SensorProtocol.luxPath)

    /// `binary_sensor/Presence` passt auf sich selbst und auf `binary_sensor-presence`.
    static func matches(_ id: String, path: String) -> Bool {
        if id == path { return true }
        let objectID = switch path {
        case SensorProtocol.presencePath: presenceObjectID
        case SensorProtocol.luxPath: luxObjectID
        default: objectID(forPath: path)
        }
        return id == objectID
    }

    /// `sensor/Ambient Light` → `sensor-ambient_light` (ESPHome-Object-ID).
    static func objectID(forPath path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return path }
        let domain = path[..<slash]
        let name = path[path.index(after: slash)...].lowercased().map { character -> String in
            if character == " " { return "_" }
            return character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
                ? String(character) : ""
        }.joined()
        return "\(domain)-\(name)"
    }

    /// `"123.4 lx"` → 123.4
    private static func leadingNumber(_ text: String) -> Double? {
        let prefix = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(prefix)
    }
}
