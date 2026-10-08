import Foundation
import Storage

/// What Crawlspace keeps from one Lighthouse JSON report: the headline metrics and the checks
/// Lighthouse says would help most.
public struct LighthouseReport: Sendable {
    public var metrics: LighthouseMetrics
    public var opportunities: [LighthouseOpportunity]
    public var finalURL: String?
    /// Set when Lighthouse ran but couldn't measure the page (a timeout, an error page, no paint).
    public var runtimeError: String?
    public var lighthouseVersion: String?

    /// How many suggestions to keep per run. The full list is in the stored HTML report.
    static let opportunityLimit = 8

    public init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LighthouseError.unreadableReport
        }
        let audits = root["audits"] as? [String: [String: Any]] ?? [:]
        let performance = (root["categories"] as? [String: Any])?["performance"] as? [String: Any]

        func numeric(_ id: String) -> Double? { audits[id]?["numericValue"] as? Double }

        let score = (performance?["score"] as? Double).map { ($0 * 100).rounded() }
        metrics = LighthouseMetrics(
            score: score,
            lcpMs: numeric("largest-contentful-paint"),
            cls: numeric("cumulative-layout-shift"),
            tbtMs: numeric("total-blocking-time"),
            fcpMs: numeric("first-contentful-paint"),
            speedIndexMs: numeric("speed-index")
        )
        finalURL = root["finalDisplayedUrl"] as? String ?? root["finalUrl"] as? String
        lighthouseVersion = root["lighthouseVersion"] as? String
        if let error = root["runtimeError"] as? [String: Any], let message = error["message"] as? String {
            runtimeError = message
        } else if score == nil {
            runtimeError = "Lighthouse couldn't score this page."
        }

        // Lighthouse 13 calls them insights; earlier versions, opportunities and diagnostics. Either
        // way: a scored check below green, from the performance category, that isn't a metric.
        let refs = performance?["auditRefs"] as? [[String: Any]] ?? []
        opportunities = refs.compactMap { ref -> LighthouseOpportunity? in
            guard let id = ref["id"] as? String, ref["group"] as? String != "metrics",
                  ref["group"] as? String != "hidden",
                  let audit = audits[id], let score = audit["score"] as? Double, score < 0.9,
                  let title = audit["title"] as? String else { return nil }
            let mode = audit["scoreDisplayMode"] as? String
            guard mode != "informative", mode != "notApplicable", mode != "manual" else { return nil }
            return LighthouseOpportunity(id: id, title: title, displayValue: audit["displayValue"] as? String,
                                         savingsMs: Self.savings(audit), score: score)
        }
        .sorted { ($0.savingsMs, -$0.score) > ($1.savingsMs, -$1.score) }
        .prefix(Self.opportunityLimit)
        .map { $0 }
    }

    /// Estimated time saved: the larger of the paint metrics a check affects, or its own estimate.
    private static func savings(_ audit: [String: Any]) -> Double {
        let metricSavings = audit["metricSavings"] as? [String: Any] ?? [:]
        let paint = ["LCP", "FCP"].compactMap { metricSavings[$0] as? Double }.max() ?? 0
        let overall = (audit["details"] as? [String: Any])?["overallSavingsMs"] as? Double ?? 0
        return max(paint, overall)
    }
}

public enum LighthouseError: LocalizedError, Equatable {
    case unreadableReport
    case notInstalled(String)
    case failed(String)
    case timedOut(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadableReport: "Lighthouse finished but its report couldn't be read."
        case .notInstalled(let what): "Lighthouse isn't ready: \(what)"
        case .failed(let message): message
        case .timedOut(let seconds): "Lighthouse gave up after \(seconds) seconds."
        case .cancelled: "Cancelled."
        }
    }
}
