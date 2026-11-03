import CoreGraphics
import os

struct GammaTable: Equatable, Sendable {
    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]

    func scaled(by factor: Float) -> GammaTable {
        GammaTable(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
    }
}

/// Zugriff auf die Gamma-Tabellen; in Tests ersetzbar.
protocol GammaTableAccess: Sendable {
    func read(_ id: CGDirectDisplayID) -> GammaTable?
    @discardableResult
    func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool
    /// Setzt die Tabellen aller Displays auf ihr ColorSync-Profil zurück.
    func restoreColorSync()
}

/// Software-Dimmung über die Gamma-Tabelle. Die Tabelle, die macOS aus dem
/// ColorSync-Profil setzt, wird gemerkt und skaliert, damit die Kalibrierung erhalten bleibt.
@MainActor
public final class GammaDimmer: SoftwareDimming {
    /// Untergrenze, damit 0 % kein schwarzes Bild ergibt.
    static let minimumFactor: Float = 0.1

    private let tables: any GammaTableAccess
    private var levels: [CGDirectDisplayID: Double] = [:]
    /// Unveränderte Kurve je Display, gemerkt vor dem ersten Abdunkeln.
    private var originals: [CGDirectDisplayID: GammaTable] = [:]

    public convenience init() {
        self.init(tables: SystemGammaTables())
    }

    init(tables: any GammaTableAccess) {
        self.tables = tables
    }

    @discardableResult
    public func apply(_ levels: [CGDirectDisplayID: Double]) -> Set<CGDirectDisplayID> {
        let levels = levels.filter { $0.value < 100 }
        // Jedes Display mit gemerkter Kurve bekommt sie zurück, auch eines, dessen letzter
        // Write scheiterte und das deshalb nicht mehr in `self.levels` steht.
        for id in Array(originals.keys) where levels[id] == nil {
            restore(id)
        }
        var failed: Set<CGDirectDisplayID> = []
        for (id, level) in levels where self.levels[id] != level {
            guard !write(level, to: id) else { continue }
            failed.insert(id)
            // War das Display schon gedimmt, steht seine Kurve noch skaliert; bliebe sie so,
            // dimmte das Overlay obendrauf. War es nie gedimmt, ist nur die gemerkte Kurve
            // zu verwerfen.
            if self.levels[id] != nil { restore(id) } else { originals[id] = nil }
        }
        self.levels = levels.filter { !failed.contains($0.key) }
        return failed
    }

    /// Stellt die Profil-Kurven her, merkt sie neu und dunkelt wieder ab. Der
    /// ColorSync-Reset trifft alle Displays; deshalb nur, wenn sich die Display-Menge
    /// geändert hat oder nach dem Aufwachen.
    public func reapply() {
        guard !levels.isEmpty else { return }
        tables.restoreColorSync()
        originals = [:]
        for (id, level) in levels where !write(level, to: id) {
            levels[id] = nil
            originals[id] = nil
        }
    }

    /// Schreibt die gemerkte Kurve der genannten Displays neu, ohne ColorSync-Reset.
    public func refresh(_ displays: Set<CGDirectDisplayID>) {
        for id in displays {
            guard let level = levels[id] else { continue }
            write(level, to: id)
        }
    }

    static func factor(forPercent percent: Double) -> Float {
        let fraction = Float(min(max(percent, 0), 100) / 100)
        return minimumFactor + (1 - minimumFactor) * fraction
    }

    @discardableResult
    private func write(_ level: Double, to id: CGDirectDisplayID) -> Bool {
        guard let original = originals[id] ?? tables.read(id) else {
            ddcLog.error("Gamma-Tabelle von Display \(id) nicht lesbar")
            return false
        }
        originals[id] = original
        guard tables.write(original.scaled(by: Self.factor(forPercent: level)), to: id) else {
            ddcLog.error("Gamma-Tabelle für Display \(id) nicht gesetzt")
            return false
        }
        return true
    }

    /// Schreibt die gemerkte Kurve zurück. Gelingt das nicht, bleibt sie gemerkt, und der
    /// nächste `apply` versucht es wieder.
    private func restore(_ id: CGDirectDisplayID) {
        guard let original = originals[id] else { return }
        if tables.write(original, to: id) {
            originals[id] = nil
        }
    }
}

/// Die echten Gamma-Tabellen über CoreGraphics.
struct SystemGammaTables: GammaTableAccess {
    func read(_ id: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var table = GammaTable(
            red: [CGGammaValue](repeating: 0, count: Int(capacity)),
            green: [CGGammaValue](repeating: 0, count: Int(capacity)),
            blue: [CGGammaValue](repeating: 0, count: Int(capacity))
        )
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &table.red, &table.green, &table.blue, &count) == .success,
              count > 0
        else { return nil }
        table.red.removeSubrange(Int(count)...)
        table.green.removeSubrange(Int(count)...)
        table.blue.removeSubrange(Int(count)...)
        return table
    }

    @discardableResult
    func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool {
        CGSetDisplayTransferByTable(id, UInt32(table.red.count), table.red, table.green, table.blue) == .success
    }

    func restoreColorSync() {
        CGDisplayRestoreColorSyncSettings()
    }
}
