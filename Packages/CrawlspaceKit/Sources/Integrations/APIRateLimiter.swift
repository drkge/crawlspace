import Foundation

/// Simple token-bucket pacing so bursts of requests stay inside a per-minute quota.
actor APIRateLimiter {
    private var interval: Duration
    private var nextSlot = ContinuousClock.now

    init(requestsPerSecond: Double) {
        interval = requestsPerSecond > 0 ? .seconds(1 / requestsPerSecond) : .zero
    }

    /// Raises or lowers the pace once the server has said what it actually allows.
    func setRate(requestsPerSecond: Double) {
        interval = requestsPerSecond > 0 ? .seconds(1 / requestsPerSecond) : .zero
    }

    func wait() async {
        guard interval > .zero else { return }
        let now = ContinuousClock.now
        let slot = max(nextSlot, now)
        nextSlot = slot + interval
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}
