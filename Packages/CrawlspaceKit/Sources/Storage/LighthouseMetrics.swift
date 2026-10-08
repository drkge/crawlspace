import CrawlCore
import Foundation
import GRDB

/// One Lighthouse run's headline numbers for a page. All nil until Lighthouse has run on it.
public struct LighthouseMetrics: Sendable, Hashable, Codable {
    /// Performance score, 0–100.
    public var score: Double?
    public var lcpMs: Double?
    public var cls: Double?
    public var tbtMs: Double?
    public var fcpMs: Double?
    public var speedIndexMs: Double?

    public init(score: Double? = nil, lcpMs: Double? = nil, cls: Double? = nil, tbtMs: Double? = nil,
                fcpMs: Double? = nil, speedIndexMs: Double? = nil) {
        self.score = score
        self.lcpMs = lcpMs
        self.cls = cls
        self.tbtMs = tbtMs
        self.fcpMs = fcpMs
        self.speedIndexMs = speedIndexMs
    }

    /// Reads six consecutive columns, in the order `URLRow.selectColumns` lists them.
    init(row: Row, at index: Int) {
        score = row[index]
        lcpMs = row[index + 1]
        cls = row[index + 2]
        tbtMs = row[index + 3]
        fcpMs = row[index + 4]
        speedIndexMs = row[index + 5]
    }

    public var hasRun: Bool { score != nil }
}

/// Something Lighthouse says would make the page faster, with what it estimates it would save.
public struct LighthouseOpportunity: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    /// Lighthouse's own summary, such as "Est savings of 79 KiB" or "2.8 s".
    public var displayValue: String?
    /// Estimated time saved across LCP and FCP, in milliseconds. 0 when Lighthouse gives none.
    public var savingsMs: Double
    /// Lighthouse's score for this check, 0–1.
    public var score: Double

    public init(id: String, title: String, displayValue: String?, savingsMs: Double, score: Double) {
        self.id = id
        self.title = title
        self.displayValue = displayValue
        self.savingsMs = savingsMs
        self.score = score
    }
}

/// One stored Lighthouse run, as the inspector shows it.
public struct LighthouseRun: Sendable, Hashable, Codable {
    public var device: LighthouseDevice
    public var metrics: LighthouseMetrics
    public var opportunities: [LighthouseOpportunity]
    public var error: String?
    public var ranAt: Date
    public var hasReport: Bool
    /// The Shopify template this page was measured for, when it was.
    public var template: String?
}

/// A page Lighthouse has measured, for the speed-by-template table.
public struct LighthouseMeasuredPage: Sendable, Hashable, Codable {
    public var id: Int64
    public var url: String
    public var template: String?
    public var mobile: LighthouseMetrics
    public var desktop: LighthouseMetrics
}
