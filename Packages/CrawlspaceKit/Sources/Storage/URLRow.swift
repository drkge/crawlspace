import CrawlCore
import Foundation
import GRDB

/// A URL as displayed in tables and exports (everything except raw headers).
public struct URLRow: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var url: String
    public var isInternal: Bool
    public var depth: Int
    public var state: URLState
    public var resourceType: ResourceType
    public var skipReason: String?
    public var statusCode: Int?
    public var statusText: String?
    public var error: String?
    public var blockedByRobots: Bool
    public var contentType: String?
    public var sizeBytes: Int64?
    public var responseMs: Double?
    public var ttfbMs: Double?
    public var redirectURL: String?
    public var crawledAt: Date?
    public var indexability: Indexability
    public var indexabilityReason: String?
    public var title: String?
    public var titleLength: Int?
    public var titlePixels: Double?
    public var titleCount: Int?
    public var metaDescription: String?
    public var metaDescriptionLength: Int?
    public var metaDescriptionPixels: Double?
    public var metaDescriptionCount: Int?
    public var h1: String?
    public var h1Length: Int?
    public var h1Count: Int?
    public var h1Second: String?
    public var h2: String?
    public var h2Count: Int?
    public var canonical: String?
    public var canonicalCount: Int?
    public var metaRobots: String?
    public var xRobotsTag: String?
    public var lang: String?
    public var wordCount: Int?
    public var outlinks: Int?
    public var externalOutlinks: Int?
    public var hreflangCount: Int?
    public var structuredDataCount: Int?
    public var inlinks: Int
    public var uniqueInlinks: Int
    public var javaScriptRendered: Bool
    public var rawWordCount: Int?
    public var rawLinkCount: Int?
    public var renderedLinkCount: Int?
    public var renderMs: Double?
    public var inSitemap: Bool
    public var lighthouseMobile: LighthouseMetrics
    public var lighthouseDesktop: LighthouseMetrics

    static let selectColumns = """
        id, url, is_internal, depth, state, resource_type, skip_reason, status_code, status_text, error,
        blocked_by_robots, content_type, size_bytes, response_ms, ttfb_ms, redirect_url, crawled_at,
        indexability, indexability_reason, title, title_length, title_pixels, title_count,
        meta_description, meta_description_length, meta_description_pixels, meta_description_count,
        h1, h1_length, h1_count, h1_second, h2, h2_count, canonical, canonical_count, meta_robots,
        x_robots_tag, lang, word_count, outlinks, external_outlinks, hreflang_count,
        structured_data_count, inlinks, unique_inlinks, js_rendered, raw_word_count, raw_link_count,
        rendered_link_count, render_ms, in_sitemap,
        lh_m_score, lh_m_lcp_ms, lh_m_cls, lh_m_tbt_ms, lh_m_fcp_ms, lh_m_si_ms,
        lh_d_score, lh_d_lcp_ms, lh_d_cls, lh_d_tbt_ms, lh_d_fcp_ms, lh_d_si_ms
        """

    init(row: Row) {
        id = row[0]
        url = row[1]
        isInternal = row[2]
        depth = row[3]
        state = URLState(rawValue: row[4]) ?? .queued
        resourceType = ResourceType(rawValue: row[5]) ?? .other
        skipReason = row[6]
        statusCode = row[7]
        statusText = row[8]
        error = row[9]
        blockedByRobots = row[10]
        contentType = row[11]
        sizeBytes = row[12]
        responseMs = row[13]
        ttfbMs = row[14]
        redirectURL = row[15]
        crawledAt = (row[16] as Double?).map { Date(timeIntervalSince1970: $0) }
        indexability = Indexability(rawValue: row[17]) ?? .unknown
        indexabilityReason = row[18]
        title = row[19]
        titleLength = row[20]
        titlePixels = row[21]
        titleCount = row[22]
        metaDescription = row[23]
        metaDescriptionLength = row[24]
        metaDescriptionPixels = row[25]
        metaDescriptionCount = row[26]
        h1 = row[27]
        h1Length = row[28]
        h1Count = row[29]
        h1Second = row[30]
        h2 = row[31]
        h2Count = row[32]
        canonical = row[33]
        canonicalCount = row[34]
        metaRobots = row[35]
        xRobotsTag = row[36]
        lang = row[37]
        wordCount = row[38]
        outlinks = row[39]
        externalOutlinks = row[40]
        hreflangCount = row[41]
        structuredDataCount = row[42]
        inlinks = row[43]
        uniqueInlinks = row[44]
        javaScriptRendered = row[45]
        rawWordCount = row[46]
        rawLinkCount = row[47]
        renderedLinkCount = row[48]
        renderMs = row[49]
        inSitemap = row[50]
        lighthouseMobile = LighthouseMetrics(row: row, at: 51)
        lighthouseDesktop = LighthouseMetrics(row: row, at: 57)
    }

    public func lighthouse(_ device: LighthouseDevice) -> LighthouseMetrics {
        device == .mobile ? lighthouseMobile : lighthouseDesktop
    }

    /// Human-readable status: HTTP status text, or why there isn't one.
    public var statusDescription: String {
        if state == .skipped { return skipReason ?? "Not crawled" }
        if state == .queued { return "Queued" }
        if blockedByRobots { return "Blocked by robots.txt" }
        if let error { return error }
        return statusText ?? ""
    }
}

/// A column shown in URL tables and exports. The raw value is a stable identifier used for
/// saved column layouts.
public enum URLColumn: String, CaseIterable, Sendable, Codable, Identifiable {
    case address, contentType, statusCode, status, indexability, indexabilityReason
    case title, titleLength, titlePixels, titleCount
    case metaDescription, metaDescriptionLength, metaDescriptionPixels, metaDescriptionCount
    case h1, h1Length, h1Count, h1Second, h2, h2Count
    case canonical, canonicalCount, metaRobots, xRobotsTag, lang
    case wordCount, sizeBytes, responseMs, ttfbMs, depth
    case inlinks, uniqueInlinks, outlinks, externalOutlinks
    case redirectURL, hreflangCount, structuredDataCount, resourceType, crawledAt
    case javaScriptRendered, rawWordCount, rawLinkCount, renderedLinkCount, renderMs, inSitemap
    case lhMobileScore, lhMobileLCP, lhMobileCLS, lhMobileTBT
    case lhDesktopScore, lhDesktopLCP, lhDesktopCLS, lhDesktopTBT

    public var id: String { rawValue }

    public enum Kind: Sendable { case text, integer, decimal }

    public var title: String {
        switch self {
        case .address: "Address"
        case .contentType: "Content Type"
        case .statusCode: "Status Code"
        case .status: "Status"
        case .indexability: "Indexability"
        case .indexabilityReason: "Indexability Status"
        case .title: "Title"
        case .titleLength: "Title Length"
        case .titlePixels: "Title Pixel Width"
        case .titleCount: "Title Count"
        case .metaDescription: "Meta Description"
        case .metaDescriptionLength: "Meta Description Length"
        case .metaDescriptionPixels: "Meta Description Pixel Width"
        case .metaDescriptionCount: "Meta Description Count"
        case .h1: "H1"
        case .h1Length: "H1 Length"
        case .h1Count: "H1 Count"
        case .h1Second: "H1 (2nd)"
        case .h2: "H2"
        case .h2Count: "H2 Count"
        case .canonical: "Canonical"
        case .canonicalCount: "Canonical Count"
        case .metaRobots: "Meta Robots"
        case .xRobotsTag: "X-Robots-Tag"
        case .lang: "Language"
        case .wordCount: "Word Count"
        case .sizeBytes: "Size (bytes)"
        case .responseMs: "Response Time (ms)"
        case .ttfbMs: "TTFB (ms)"
        case .depth: "Crawl Depth"
        case .inlinks: "Inlinks"
        case .uniqueInlinks: "Unique Inlinks"
        case .outlinks: "Outlinks"
        case .externalOutlinks: "External Outlinks"
        case .redirectURL: "Redirect URL"
        case .hreflangCount: "Hreflang Count"
        case .structuredDataCount: "JSON-LD Blocks"
        case .resourceType: "Type"
        case .crawledAt: "Crawled"
        case .javaScriptRendered: "Rendered"
        case .rawWordCount: "Raw Word Count"
        case .rawLinkCount: "Raw Link Count"
        case .renderedLinkCount: "Rendered Link Count"
        case .renderMs: "Render Time (ms)"
        case .inSitemap: "In Sitemap"
        case .lhMobileScore: "Mobile Score"
        case .lhMobileLCP: "Mobile LCP (ms)"
        case .lhMobileCLS: "Mobile CLS"
        case .lhMobileTBT: "Mobile TBT (ms)"
        case .lhDesktopScore: "Desktop Score"
        case .lhDesktopLCP: "Desktop LCP (ms)"
        case .lhDesktopCLS: "Desktop CLS"
        case .lhDesktopTBT: "Desktop TBT (ms)"
        }
    }

    /// SQL used for ORDER BY. Only ever built from this enum, never from user input.
    public var sortExpression: String {
        switch self {
        case .address: "url"
        case .contentType: "content_type"
        case .statusCode: "status_code"
        case .status: "COALESCE(status_text, error, skip_reason)"
        case .indexability: "indexability"
        case .indexabilityReason: "indexability_reason"
        case .title: "title"
        case .titleLength: "title_length"
        case .titlePixels: "title_pixels"
        case .titleCount: "title_count"
        case .metaDescription: "meta_description"
        case .metaDescriptionLength: "meta_description_length"
        case .metaDescriptionPixels: "meta_description_pixels"
        case .metaDescriptionCount: "meta_description_count"
        case .h1: "h1"
        case .h1Length: "h1_length"
        case .h1Count: "h1_count"
        case .h1Second: "h1_second"
        case .h2: "h2"
        case .h2Count: "h2_count"
        case .canonical: "canonical"
        case .canonicalCount: "canonical_count"
        case .metaRobots: "meta_robots"
        case .xRobotsTag: "x_robots_tag"
        case .lang: "lang"
        case .wordCount: "word_count"
        case .sizeBytes: "size_bytes"
        case .responseMs: "response_ms"
        case .ttfbMs: "ttfb_ms"
        case .depth: "depth"
        case .inlinks: "inlinks"
        case .uniqueInlinks: "unique_inlinks"
        case .outlinks: "outlinks"
        case .externalOutlinks: "external_outlinks"
        case .redirectURL: "redirect_url"
        case .hreflangCount: "hreflang_count"
        case .structuredDataCount: "structured_data_count"
        case .resourceType: "resource_type"
        case .crawledAt: "crawled_at"
        case .javaScriptRendered: "js_rendered"
        case .rawWordCount: "raw_word_count"
        case .rawLinkCount: "raw_link_count"
        case .renderedLinkCount: "rendered_link_count"
        case .renderMs: "render_ms"
        case .inSitemap: "in_sitemap"
        case .lhMobileScore: "lh_m_score"
        case .lhMobileLCP: "lh_m_lcp_ms"
        case .lhMobileCLS: "lh_m_cls"
        case .lhMobileTBT: "lh_m_tbt_ms"
        case .lhDesktopScore: "lh_d_score"
        case .lhDesktopLCP: "lh_d_lcp_ms"
        case .lhDesktopCLS: "lh_d_cls"
        case .lhDesktopTBT: "lh_d_tbt_ms"
        }
    }

    public var kind: Kind {
        switch self {
        case .statusCode, .titleLength, .titleCount, .metaDescriptionLength, .metaDescriptionCount,
             .h1Length, .h1Count, .h2Count, .canonicalCount, .wordCount, .sizeBytes, .depth,
             .inlinks, .uniqueInlinks, .outlinks, .externalOutlinks, .hreflangCount, .structuredDataCount,
             .rawWordCount, .rawLinkCount, .renderedLinkCount:
            .integer
        case .titlePixels, .metaDescriptionPixels, .responseMs, .ttfbMs, .renderMs,
             .lhMobileScore, .lhMobileLCP, .lhMobileCLS, .lhMobileTBT,
             .lhDesktopScore, .lhDesktopLCP, .lhDesktopCLS, .lhDesktopTBT:
            .decimal
        default:
            .text
        }
    }

    public var defaultWidth: Double {
        switch self {
        case .address, .title, .metaDescription, .canonical, .redirectURL: 320
        case .h1, .h1Second, .h2, .status, .indexabilityReason: 180
        case .contentType, .metaRobots, .xRobotsTag, .crawledAt: 140
        default: kind == .text ? 110 : 90
        }
    }

    public enum Value: Sendable, Hashable {
        case empty
        case text(String)
        case integer(Int64)
        case decimal(Double)

        public var displayString: String {
            switch self {
            case .empty: ""
            case .text(let text): text
            case .integer(let value): String(value)
            case .decimal(let value): String(format: "%.0f", value)
            }
        }
    }

    public func value(for row: URLRow) -> Value {
        func text(_ s: String?) -> Value { s.map(Value.text) ?? .empty }
        func int(_ i: Int?) -> Value { i.map { .integer(Int64($0)) } ?? .empty }
        func dec(_ d: Double?) -> Value { d.map(Value.decimal) ?? .empty }
        func cls(_ d: Double?) -> Value { d.map { .text(String(format: "%.3f", $0)) } ?? .empty }
        let crawled = row.state == .crawled

        switch self {
        case .address: return .text(row.url)
        case .contentType: return text(row.contentType)
        case .statusCode: return int(row.statusCode)
        case .status: return .text(row.statusDescription)
        case .indexability: return crawled ? .text(row.indexability.label) : .empty
        case .indexabilityReason: return text(row.indexabilityReason)
        case .title: return text(row.title)
        case .titleLength: return int(row.titleLength)
        case .titlePixels: return dec(row.titlePixels)
        case .titleCount: return int(row.titleCount)
        case .metaDescription: return text(row.metaDescription)
        case .metaDescriptionLength: return int(row.metaDescriptionLength)
        case .metaDescriptionPixels: return dec(row.metaDescriptionPixels)
        case .metaDescriptionCount: return int(row.metaDescriptionCount)
        case .h1: return text(row.h1)
        case .h1Length: return int(row.h1Length)
        case .h1Count: return int(row.h1Count)
        case .h1Second: return text(row.h1Second)
        case .h2: return text(row.h2)
        case .h2Count: return int(row.h2Count)
        case .canonical: return text(row.canonical)
        case .canonicalCount: return int(row.canonicalCount)
        case .metaRobots: return text(row.metaRobots)
        case .xRobotsTag: return text(row.xRobotsTag)
        case .lang: return text(row.lang)
        case .wordCount: return int(row.wordCount)
        case .sizeBytes: return row.sizeBytes.map(Value.integer) ?? .empty
        case .responseMs: return dec(row.responseMs)
        case .ttfbMs: return dec(row.ttfbMs)
        case .depth: return .integer(Int64(row.depth))
        case .inlinks: return .integer(Int64(row.inlinks))
        case .uniqueInlinks: return .integer(Int64(row.uniqueInlinks))
        case .outlinks: return int(row.outlinks)
        case .externalOutlinks: return int(row.externalOutlinks)
        case .redirectURL: return text(row.redirectURL)
        case .hreflangCount: return int(row.hreflangCount)
        case .structuredDataCount: return int(row.structuredDataCount)
        case .resourceType: return crawled ? .text(row.resourceType.label) : .empty
        case .crawledAt:
            return row.crawledAt.map { .text($0.formatted(date: .numeric, time: .standard)) } ?? .empty
        case .javaScriptRendered: return row.state == .crawled ? .text(row.javaScriptRendered ? "Yes" : "No") : .empty
        case .rawWordCount: return int(row.rawWordCount)
        case .rawLinkCount: return int(row.rawLinkCount)
        case .renderedLinkCount: return int(row.renderedLinkCount)
        case .renderMs: return dec(row.renderMs)
        case .inSitemap: return row.state == .crawled ? .text(row.inSitemap ? "Yes" : "No") : .empty
        case .lhMobileScore: return dec(row.lighthouseMobile.score)
        case .lhMobileLCP: return dec(row.lighthouseMobile.lcpMs)
        case .lhMobileCLS: return cls(row.lighthouseMobile.cls)
        case .lhMobileTBT: return dec(row.lighthouseMobile.tbtMs)
        case .lhDesktopScore: return dec(row.lighthouseDesktop.score)
        case .lhDesktopLCP: return dec(row.lighthouseDesktop.lcpMs)
        case .lhDesktopCLS: return cls(row.lighthouseDesktop.cls)
        case .lhDesktopTBT: return dec(row.lighthouseDesktop.tbtMs)
        }
    }
}
