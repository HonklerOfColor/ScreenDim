import Foundation

/// Entprellt Schreibzugriffe: Der erste Wert geht sofort raus, danach höchstens einer pro
/// `interval`, und zwar immer der zuletzt übergebene. Zwischenwerte werden verworfen.
/// Eine neue Aktion startet erst, wenn die vorige fertig ist; es gibt also nie zwei
/// gleichzeitige Writes auf denselben Monitor.
@MainActor
final class LatestValueThrottle<Value: Sendable> {
    typealias Sleep = @Sendable (Duration) async -> Void

    private let interval: Duration
    private let sleep: Sleep
    private let action: @MainActor (Value) async -> Void
    private var pending: Value?
    private var worker: Task<Void, Never>?

    init(
        interval: Duration = .milliseconds(50),
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
        action: @escaping @MainActor (Value) async -> Void
    ) {
        self.interval = interval
        self.sleep = sleep
        self.action = action
    }

    /// `true`, wenn weder ein Wert wartet noch eine Aktion läuft.
    var isIdle: Bool { worker == nil && pending == nil }

    func submit(_ value: Value) {
        pending = value
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while let value = pending {
            pending = nil
            await action(value)
            await sleep(interval)
        }
        worker = nil
    }
}
