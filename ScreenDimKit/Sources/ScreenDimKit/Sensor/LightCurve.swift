import Foundation

/// Umgebungslicht → Helligkeit eines Monitors: Stützpunkte „bei so viel Lux so viel
/// Prozent“. Zwischen zwei Punkten gleitet die Helligkeit logarithmisch (so empfindet das
/// Auge), unter dem ersten und über dem letzten Punkt bleibt sie stehen.
public struct LightCurve: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        /// 0…`LightCurve.maxLux`
        public var lux: Double
        /// 0…100
        public var percent: Double

        public init(lux: Double, percent: Double) {
            // NaN käme durch min/max unverändert durch; `percent(forLux:)` fände dann keinen
            // Abschnitt. Das Lux-Feld der Einstellungen nimmt „NaN“ als Zahl an.
            self.lux = lux.isNaN ? 0 : min(max(lux.rounded(), 0), LightCurve.maxLux)
            self.percent = percent.isNaN ? 100 : min(max(percent.rounded(), 0), 100)
        }
    }

    public static let maxLux: Double = 100_000
    public static let maxPoints = 8

    /// 10 lx → 20 %, 1000 lx → 100 %.
    public static let standard = LightCurve(points: [Point(lux: 10, percent: 20), Point(lux: 1000, percent: 100)])

    /// Nach Lux sortiert, mindestens ein Punkt.
    public private(set) var points: [Point]

    /// Leere Liste ergibt die Standardkurve.
    public init(points: [Point]) {
        let sorted = points.prefix(Self.maxPoints).sorted { $0.lux < $1.lux }
        self.points = sorted.isEmpty ? Self.standard.points : sorted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([Point].self, forKey: .points))
    }

    public func percent(forLux lux: Double) -> Double {
        guard let first = points.first, let last = points.last, !lux.isNaN else { return 100 }
        if lux <= first.lux { return first.percent }
        if lux >= last.lux { return last.percent }
        let upper = points.firstIndex { $0.lux > lux } ?? points.count - 1
        let low = points[upper - 1], high = points[upper]
        // Logarithmisch ab 1 lx; darunter gibt es keinen sinnvollen Logarithmus.
        let span = log10(max(high.lux, 1)) - log10(max(low.lux, 1))
        guard span > 0 else { return high.percent }
        let fraction = (log10(max(lux, 1)) - log10(max(low.lux, 1))) / span
        return (low.percent + (high.percent - low.percent) * min(max(fraction, 0), 1)).rounded()
    }

    // MARK: - Bearbeiten

    public mutating func setPoint(_ point: Point, at index: Int) {
        guard points.indices.contains(index) else { return }
        var points = points
        points[index] = point
        self = LightCurve(points: points)
    }

    public mutating func removePoint(at index: Int) {
        guard points.count > 1, points.indices.contains(index) else { return }
        var points = points
        points.remove(at: index)
        self = LightCurve(points: points)
    }

    /// Fügt einen Punkt ein. Liegt schon einer bei diesen Lux, wird er ersetzt.
    public mutating func insert(_ point: Point) {
        var points = points.filter { $0.lux != point.lux }
        guard points.count < Self.maxPoints else { return }
        points.append(point)
        self = LightCurve(points: points)
    }

    /// Vorschlag für einen neuen Punkt: in der Mitte der größten Lücke (logarithmisch),
    /// mit dem Wert, den die Kurve dort ohnehin hat. `nil`, wenn kein Platz mehr ist.
    public func suggestedPoint() -> Point? {
        guard points.count < Self.maxPoints else { return nil }
        let logs = ([0.0] + points.map { log10(max($0.lux, 1)) } + [log10(Self.maxLux)])
        var best: (gap: Double, mid: Double) = (0, 0)
        for (low, high) in zip(logs, logs.dropFirst()) where high - low > best.gap {
            best = (high - low, (low + high) / 2)
        }
        let lux = pow(10, best.mid).rounded()
        guard best.gap > 0, !points.contains(where: { $0.lux == lux }) else { return nil }
        return Point(lux: lux, percent: percent(forLux: lux))
    }
}

/// Wie ein Monitor dem Umgebungslicht folgt.
public struct LightProfile: Codable, Equatable, Sendable {
    /// `false`: Der Monitor bleibt, wie er ist; das Licht regelt nur die anderen.
    public var followsLight: Bool
    public var curve: LightCurve

    public static let standard = LightProfile(followsLight: true, curve: .standard)

    public init(followsLight: Bool, curve: LightCurve) {
        self.followsLight = followsLight
        self.curve = curve
    }
}

/// Lichtprofile je Monitor (Schlüssel: EDID-Identität wie bei der Helligkeit). Profile
/// nicht angeschlossener Monitore bleiben erhalten.
struct LightProfileStore {
    private let defaults: any PreferenceStorage

    init(storage: any PreferenceStorage) {
        self.defaults = storage
    }

    func profile(for storageKey: String) -> LightProfile? {
        guard let data = defaults.object(forKey: key(storageKey)) as? Data else { return nil }
        return try? JSONDecoder().decode(LightProfile.self, from: data)
    }

    /// `nil` löscht das Profil; dann gilt der Standard.
    func setProfile(_ profile: LightProfile?, for storageKey: String) {
        defaults.set(profile.flatMap { try? JSONEncoder().encode($0) }, forKey: key(storageKey))
    }

    private func key(_ storageKey: String) -> String {
        "lightProfile.\(storageKey)"
    }
}
