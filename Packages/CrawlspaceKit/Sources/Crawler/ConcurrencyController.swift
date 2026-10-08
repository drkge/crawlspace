import Foundation

/// Decides how many connections a crawl should be running, from what the server is saying back.
///
/// Additive increase, multiplicative decrease, the same shape as network congestion control: back
/// off sharply the moment a server pushes back — 429, 503, timeouts — or answers much more slowly
/// than its best, and creep back up one connection at a time while it stays healthy.
///
/// The configured number of connections is a ceiling, never a target: this only ever runs at or
/// below what was asked for, so turning it on cannot make a crawl heavier than the setting allows.
struct ConcurrencyController: Sendable {
    let minimum: Int
    let maximum: Int
    private(set) var current: Int
    /// How long to watch before deciding. Short enough to react, long enough to mean something.
    let window: Duration

    /// The best mean latency seen so far, which is what "healthy" is measured against.
    private var best = Double.infinity
    private var samples = 0
    private var latencyTotal = 0.0
    private var pushbacks = 0
    private var failures = 0
    private var windowStart: ContinuousClock.Instant

    /// Enough requests to tell a real change from one slow page.
    private let minimumSamples = 4
    /// A window this much slower than the best is taken as the server starting to strain.
    private let slowdownFactor = 1.5
    /// The baseline drifts up slowly, so a site that is genuinely slower today isn't held to a
    /// number it hit once.
    private let baselineRelaxation = 1.05

    init(maximum: Int, minimum: Int = 1, start: Int? = nil, window: Duration = .seconds(5),
         now: ContinuousClock.Instant = .now) {
        self.maximum = max(1, maximum)
        self.minimum = max(1, min(minimum, max(1, maximum)))
        self.window = window
        current = min(max(start ?? maximum, self.minimum), self.maximum)
        windowStart = now
    }

    mutating func record(latencyMs: Double?, pushedBack: Bool, failed: Bool) {
        if pushedBack { pushbacks += 1 }
        if failed { failures += 1 }
        guard let latencyMs, latencyMs > 0 else { return }
        latencyTotal += latencyMs
        samples += 1
    }

    /// Returns the new number of connections when the decision changes it, and nil otherwise.
    mutating func evaluate(now: ContinuousClock.Instant = .now) -> Int? {
        guard windowStart.duration(to: now) >= window else { return nil }
        let completed = samples + failures
        // A window with nothing in it says nothing; one with a 429 in it says plenty.
        guard completed >= minimumSamples || pushbacks > 0 else {
            windowStart = now
            return nil
        }

        let mean = samples > 0 ? latencyTotal / Double(samples) : 0
        let failureRate = completed > 0 ? Double(failures) / Double(completed) : 0
        let previous = current

        if pushbacks > 0 || failureRate > 0.2 {
            current = max(minimum, current / 2)
        } else if best.isFinite, mean > best * slowdownFactor, current > minimum {
            current -= 1
        } else if current < maximum {
            current += 1
        }

        if mean > 0 {
            best = min(best.isFinite ? best * baselineRelaxation : mean, mean)
        }
        reset(at: now)
        return current == previous ? nil : current
    }

    private mutating func reset(at now: ContinuousClock.Instant) {
        windowStart = now
        samples = 0
        latencyTotal = 0
        pushbacks = 0
        failures = 0
    }
}
