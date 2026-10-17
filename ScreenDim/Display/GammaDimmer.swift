import CoreGraphics
import os

/// Dunkelt Monitore ab, bei denen DDC nicht durchkommt (Dock, MST-Hub, Adapter).
/// Die Hintergrundbeleuchtung bleibt dabei, wie sie ist; nur das Bild wird dunkler.
@MainActor
protocol SoftwareDimming: AnyObject {
    /// Gewünschter Zustand für alle Displays: Stufe 0…100 je Display. Displays, die
    /// fehlen oder 100 haben, bekommen ihre ursprüngliche Kurve zurück.
    func apply(_ levels: [CGDirectDisplayID: Double])
    /// Schreibt die Kurven neu, nachdem macOS sie zurückgesetzt haben kann
    /// (Umkonfiguration, Aufwachen, ColorSync).
    func reapply()
}

/// Software-Dimmung über die Gamma-Tabelle. Die Tabelle, die macOS aus dem
/// ColorSync-Profil setzt, wird gemerkt und skaliert, damit die Kalibrierung erhalten bleibt.
@MainActor
final class GammaDimmer: SoftwareDimming {
    /// Untergrenze, damit 0 % kein schwarzes Bild ergibt.
    static let minimumFactor: Float = 0.1

    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private var levels: [CGDirectDisplayID: Double] = [:]
    /// Unveränderte Kurve je Display, gemerkt vor dem ersten Abdunkeln.
    private var originals: [CGDirectDisplayID: Table] = [:]

    nonisolated init() {}

    func apply(_ levels: [CGDirectDisplayID: Double]) {
        let levels = levels.filter { $0.value < 100 }
        for id in self.levels.keys where levels[id] == nil {
            restore(id)
        }
        for (id, level) in levels where self.levels[id] != level {
            write(level, to: id)
        }
        self.levels = levels
    }

    func reapply() {
        guard !levels.isEmpty else { return }
        // Erst die Profil-Kurven herstellen und neu merken, dann wieder abdunkeln.
        CGDisplayRestoreColorSyncSettings()
        originals = [:]
        for (id, level) in levels {
            write(level, to: id)
        }
    }

    static func factor(forPercent percent: Double) -> Float {
        let fraction = Float(min(max(percent, 0), 100) / 100)
        return minimumFactor + (1 - minimumFactor) * fraction
    }

    private func write(_ level: Double, to id: CGDirectDisplayID) {
        guard let original = originals[id] ?? Self.readTable(id) else {
            ddcLog.error("Gamma-Tabelle von Display \(id) nicht lesbar")
            return
        }
        originals[id] = original
        let factor = Self.factor(forPercent: level)
        Self.writeTable(Table(
            red: original.red.map { $0 * factor },
            green: original.green.map { $0 * factor },
            blue: original.blue.map { $0 * factor }
        ), to: id)
    }

    private func restore(_ id: CGDirectDisplayID) {
        guard let original = originals.removeValue(forKey: id) else { return }
        Self.writeTable(original, to: id)
    }

    private static func readTable(_ id: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var table = Table(
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

    private static func writeTable(_ table: Table, to id: CGDirectDisplayID) {
        let result = CGSetDisplayTransferByTable(id, UInt32(table.red.count), table.red, table.green, table.blue)
        if result != .success {
            ddcLog.error("Gamma-Tabelle für Display \(id) nicht gesetzt: \(result.rawValue)")
        }
    }
}
