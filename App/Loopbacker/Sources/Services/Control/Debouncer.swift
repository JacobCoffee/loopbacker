import Foundation

/// Debounces rapid repeated calls (e.g. several app-launch notifications arriving back to back)
/// so the wrapped action only runs once, `delay` after the last call that didn't get superseded.
/// The scheduler is injectable so tests can drive it synchronously instead of with real timers.
@MainActor
final class Debouncer {
    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var generation = 0

    init(delay: TimeInterval, schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            work()
        }
    }) {
        self.delay = delay
        self.schedule = schedule
    }

    /// Schedules `action`, canceling any call still pending from a previous `call(_:)`.
    func call(_ action: @escaping @MainActor () -> Void) {
        generation += 1
        let myGeneration = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == myGeneration else { return }
            action()
        }
    }
}
