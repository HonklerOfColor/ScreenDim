import Foundation

/// Glättet die Lux einer Quelle, bevor sie in die Kurven gehen: Median über die letzten
/// Werte gegen Ausreißer, danach ein gleitender Mittelwert (EMA) im Log-Raum, der Zeit
/// zwischen den Werten folgt. Ein großer, anhaltender Sprung zieht den Mittelwert sofort
/// nach, damit Licht an/aus nicht träge wirkt. Rein; die Zeit kommt von außen.
public struct LuxFilter: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Anzahl Werte im Median; 1 schaltet ihn ab.
        public var medianWindow: Int
        /// Zeitkonstante des EMA; `nil` schaltet ihn ab.
        public var timeConstant: Duration?
        /// Ab diesem Faktor zwischen Median und EMA gilt ein Wert als Sprung.
        public var jumpFactor: Double
        /// So viele Sprungwerte in Folge ziehen den EMA nach.
        public var jumpCount: Int

        /// Schreibtisch-Sensor und Demo: Die Firmware glättet schon und meldet nur bei
        /// Änderung (oder im 30-s-Takt). Jeder Median oder EMA würde eine einzelne
        /// Änderung bis zur nächsten Meldung zurückhalten; deshalb durchreichen.
        public static let deskSensor = Configuration(medianWindow: 1, timeConstant: nil, jumpFactor: 3, jumpCount: 3)
    }

    public let configuration: Configuration
    private var recent: [Double] = []
    /// EMA im Log-Raum, `log10(lux + 1)`.
    private var average: Double?
    /// Wert ohne Umweg über den Log-Raum, wenn der Median direkt gilt (erster Wert, Sprung,
    /// ohne EMA); sonst `nil`.
    private var exact: Double?
    private var lastAt: ContinuousClock.Instant?
    private var jumps = 0

    public init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Letzter geglätteter Wert; `nil` vor dem ersten.
    public var value: Double? {
        exact ?? average.map { max(pow(10, $0) - 1, 0) }
    }

    public mutating func reset() {
        recent = []
        average = nil
        exact = nil
        lastAt = nil
        jumps = 0
    }

    /// Nimmt einen Rohwert auf und gibt den geglätteten Wert zurück.
    @discardableResult
    public mutating func add(_ lux: Double, at instant: ContinuousClock.Instant) -> Double {
        recent.append(max(lux, 0))
        if recent.count > configuration.medianWindow {
            recent.removeFirst(recent.count - configuration.medianWindow)
        }
        let medianLux = Self.median(recent)
        let median = Self.log(medianLux)
        defer { lastAt = instant }
        guard let previous = average, let timeConstant = configuration.timeConstant, let lastAt else {
            average = median
            exact = medianLux
            return medianLux
        }
        // Anhaltender Sprung: Rohwert weit weg vom Mittel, mehrmals in Folge.
        if abs(Self.log(max(lux, 0)) - previous) > log10(configuration.jumpFactor) {
            jumps += 1
        } else {
            jumps = 0
        }
        if jumps >= configuration.jumpCount {
            jumps = 0
            average = median
            exact = medianLux
            return medianLux
        }
        let elapsed = max((instant - lastAt) / timeConstant, 0)
        let weight = 1 - exp(-elapsed)
        let next = previous + (median - previous) * weight
        if next != previous { exact = nil }
        average = next
        return value!
    }

    private static func log(_ lux: Double) -> Double {
        log10(lux + 1)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
