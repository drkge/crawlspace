import Audit
import CrawlCore
import Crawler
import Export
import Foundation
import Lighthouse
import Parsing
import Storage

// The JSON the browser sees. Engine types that are already plain data (CrawlConfig, OverviewStats,
// LinkRow, CrawlComparison…) go out as they are; these cover the rest.

struct ProgressDTO: Codable, Sendable {
    var phase: String
    var crawled: Int
    var discovered: Int
    var queued: Int
    var inFlight: Int
    var concurrency: Int
    var urlsPerSecond: Double
    var elapsedSeconds: Double
    var wasStopped: Bool
    var errorMessage: String?

    init(_ progress: CrawlProgress) {
        phase = progress.phase.rawValue
        crawled = progress.crawled
        discovered = progress.discovered
        queued = progress.queued
        inFlight = progress.inFlight
        concurrency = progress.concurrency
        urlsPerSecond = progress.urlsPerSecond
        elapsedSeconds = Double(progress.elapsed.components.seconds)
            + Double(progress.elapsed.components.attoseconds) / 1e18
        wasStopped = progress.wasStopped
        errorMessage = progress.errorMessage
    }
}

struct LighthouseStateDTO: Codable, Sendable {
    var running: Bool
    var progress: LighthouseBatch.Progress?
    var message: String?
}

struct CheckStateDTO: Codable, Sendable {
    var running: Bool
    /// The issue being checked, by its title.
    var issue: String?
    var progress: PageCheck.Progress?
}

/// What checking an issue found: on how many of the pages checked it's gone, and still there; and
/// when it's gone from any, the other pages that still have it.
struct CheckResultDTO: Codable, Sendable {
    var code: String
    var title: String
    var checked: Int
    var resolved: Int
    var remaining: Int
    /// Pages the site wouldn't answer — it asked to slow down — left as they were.
    var unanswered: Int
    var elsewhere: [Int64]

    init(_ result: PageCheck.Result) {
        code = result.issue
        title = CheckResultDTO.title(of: result.issue)
        checked = result.checked
        resolved = result.resolved
        remaining = result.remaining
        unanswered = result.unanswered
        elsewhere = result.elsewhere
    }

    /// "Canonicals: Canonicalised", as the sidebar lists it.
    static func title(of code: String) -> String {
        IssueCatalogue.definition(for: code).map { "\($0.category.rawValue): \($0.title)" } ?? code
    }
}

struct CrawlStateDTO: Codable, Sendable {
    var id: String
    var name: String
    var site: String
    var status: CrawlStatus
    var progress: ProgressDTO
    var isRunning: Bool
    var isPaused: Bool
    var canStart: Bool
    /// Nothing crawled yet, so every setting can still change; otherwise only speed.
    var isConfigurable: Bool
    var config: CrawlConfig
    var lighthouse: LighthouseStateDTO
    var check: CheckStateDTO
    var exporting: String?
    var ecommerceNote: String?
    /// What a speed check measures: "one page of each Shopify template" or "the 25 most-linked pages".
    var speedPlan: String
}

struct CrawlListItemDTO: Codable, Sendable {
    var id: String
    var name: String
    var site: String
    var startURL: String
    var status: CrawlStatus
    var crawled: Int
    var modified: Date
    var isRunning: Bool
    var readable: Bool
}

struct IssueDTO: Codable, Sendable {
    var code: String
    var category: String
    var severity: String
    /// "error", "warning" or "notice" by severity, or "lighthouse" or "sitemap", kept apart.
    var group: String
    var title: String
    var description: String
    var howToFix: String
    /// Where the check comes from, each with its kind (google, bing, webStandard, lighthouse,
    /// ruleOfThumb), the document's title — or a rule of thumb's reason — and its address.
    var sources: [IssueSource]

    init(_ definition: IssueDefinition) {
        code = definition.code
        category = definition.category.rawValue
        severity = definition.severity.name
        group = definition.group.rawValue
        title = definition.title
        description = definition.description
        howToFix = definition.howToFix
        sources = definition.sources
    }
}

struct IssueCountDTO: Codable, Sendable {
    var issue: IssueDTO
    var count: Int
}

struct NamedCountDTO: Codable, Sendable {
    var name: String
    var count: Int
}

struct CountsDTO: Codable, Sendable {
    var issues: [IssueCountDTO]
    var filters: [String: Int]
    var extractions: [NamedCountDTO]
    var searches: [NamedCountDTO]
    var hasLighthouse: Bool
    var overview: OverviewStats
    /// Issues set aside on pages that can't be indexed, and how many pages: not in `issues`.
    var setAside: SetAsideDTO
    /// Issues the site's rules ignore, each with how many pages it's on: not in `issues`.
    var ignored: [IgnoredDTO]
}

struct SetAsideDTO: Codable, Sendable {
    var issues: Int
    var pages: Int
}

struct ColumnDTO: Codable, Sendable {
    var id: String
    var title: String
    var kind: String
    var width: Double
    var sortable: Bool

    init(_ column: URLTableColumn) {
        id = column.id
        title = column.title
        switch column.kind {
        case .text: kind = "text"
        case .integer: kind = "integer"
        case .decimal: kind = "decimal"
        }
        width = column.defaultWidth
        sortable = column.sortableColumn != nil
    }
}

struct RowListDTO: Codable, Sendable {
    var title: String
    var ids: [Int64]
    var columns: [ColumnDTO]
    var issue: IssueDTO?
    /// For the pages whose issue is ignored: which issue, and whether it's ignored everywhere.
    var ignored: IgnoredDTO?
}

/// An issue the site's rules ignore: on every page, or on some, and how many pages it's on.
struct IgnoredDTO: Codable, Sendable {
    var issue: IssueDTO
    var everywhere: Bool
    var count: Int
}

struct RowDTO: Codable, Sendable {
    var id: Int64
    var url: String
    var statusCode: Int?
    var indexable: Bool
    var crawled: Bool
    var cells: [String]
}

struct KeyValueDTO: Codable, Sendable {
    var name: String
    var value: String
}

struct SERPDTO: Codable, Sendable {
    var host: String
    var title: String?
    var titleLength: Int?
    var titlePixels: Double?
    var titleTooWide: Bool
    var description: String?
    var descriptionLength: Int?
    var descriptionPixels: Double?
    var descriptionTooWide: Bool
}

struct InspectorIssueDTO: Codable, Sendable {
    var issue: IssueDTO
    var evidence: IssueEvidence?
}

struct NearDuplicateDTO: Codable, Sendable {
    var url: String
    var similarity: Double
}

struct InspectorDTO: Codable, Sendable {
    var id: Int64
    var url: String
    var statusCode: Int?
    var status: String
    var indexability: String
    var indexable: Bool
    /// Why it can't be indexed: "Canonicalised", "Noindex", "Redirected"…
    var indexabilityReason: String?
    /// Issues set aside because it can't be indexed: not in `issues`.
    var setAside: Int
    /// Issues ignored on it, each saying whether it's ignored everywhere or on this page.
    var ignored: [IgnoredDTO]
    var isPage: Bool
    var serp: SERPDTO?
    var details: [KeyValueDTO]
    var issues: [InspectorIssueDTO]
    var inlinks: [LinkRow]
    var outlinks: [LinkRow]
    var headers: [KeyValueDTO]
    var hreflang: [HreflangRow]
    var structuredData: [StructuredDataRow]
    var extractions: [KeyValueDTO]
    var nearDuplicates: [NearDuplicateDTO]
    var hasRawHTML: Bool
    var hasRenderedHTML: Bool
    var hasScreenshot: Bool
    var lighthouse: [LighthouseRun]

    init?(store: CrawlStore, id: Int64) {
        guard let row = try? store.row(id: id) else { return nil }
        self.id = id
        url = row.url
        statusCode = row.statusCode
        status = row.statusDescription
        indexability = row.state == .crawled ? row.indexability.label : ""
        indexable = row.indexability == .indexable
        indexabilityReason = row.state == .crawled ? row.indexabilityReason : nil
        setAside = (try? store.setAsideCount(for: id)) ?? 0
        let everywhere = Set(((try? store.ignoreRules()) ?? []).filter { $0.url == nil }.map(\.code))
        ignored = ((try? store.ignoredCodes(for: id)) ?? []).compactMap { code in
            IssueCatalogue.definition(for: code).map { IgnoredDTO(issue: IssueDTO($0), everywhere: everywhere.contains(code), count: 1) }
        }
        isPage = row.resourceType == .page

        if row.resourceType == .page, row.title != nil || row.metaDescription != nil {
            serp = SERPDTO(
                host: URL(string: row.url)?.host() ?? "",
                title: row.title, titleLength: row.titleLength, titlePixels: row.titlePixels,
                titleTooWide: (row.titlePixels ?? 0) > PixelWidth.titleLimit,
                description: row.metaDescription, descriptionLength: row.metaDescriptionLength,
                descriptionPixels: row.metaDescriptionPixels,
                descriptionTooWide: (row.metaDescriptionPixels ?? 0) > PixelWidth.descriptionLimit
            )
        }
        details = Self.detailPairs(row)

        let definitions = ((try? store.issueCodes(for: id)) ?? [])
            .compactMap(IssueCatalogue.definition(for:))
            .sorted { ($0.severity.rawValue, $0.category.rawValue, $0.title) < ($1.severity.rawValue, $1.category.rawValue, $1.title) }
        issues = definitions.map { definition in
            InspectorIssueDTO(issue: IssueDTO(definition),
                              evidence: try? IssueEvidenceBuilder.evidence(for: definition.code, urlID: id, store: store))
        }
        inlinks = (try? store.inlinks(to: id, limit: 1_000)) ?? []
        outlinks = (try? store.outlinks(from: id, limit: 1_000)) ?? []
        headers = ((try? store.headers(id: id)) ?? []).map { KeyValueDTO(name: $0.name, value: $0.value) }
        hreflang = (try? store.hreflang(for: id)) ?? []
        structuredData = (try? store.structuredData(for: id)) ?? []
        extractions = ((try? store.extractionValues(ids: [id])[id]) ?? [:])
            .map { KeyValueDTO(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        nearDuplicates = ((try? store.nearDuplicates(for: id)) ?? []).map { NearDuplicateDTO(url: $0.url, similarity: $0.similarity) }
        hasRawHTML = ((try? store.storedHTML(id: id)) ?? nil) != nil
        hasRenderedHTML = ((try? store.renderedHTML(id: id)) ?? nil) != nil
        hasScreenshot = ((try? store.screenshot(id: id)) ?? nil) != nil
        lighthouse = (try? store.lighthouseRuns(urlID: id)) ?? []
    }

    /// The same facts, in the same order, as 1.x's inspector.
    private static func detailPairs(_ row: URLRow) -> [KeyValueDTO] {
        var pairs: [KeyValueDTO] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { pairs.append(KeyValueDTO(name: name, value: value)) }
        }
        add("Indexability", row.state == .crawled ? row.indexabilityReason : row.skipReason)
        add("Content Type", row.contentType)
        add("Size", row.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        add("Response Time", row.responseMs.map { String(format: "%.0f ms", $0) })
        add("TTFB", row.ttfbMs.map { String(format: "%.0f ms", $0) })
        add("Crawl Depth", String(row.depth))
        add("Inlinks", "\(row.inlinks) (\(row.uniqueInlinks) unique)")
        add("Outlinks", row.outlinks.map { "\($0) internal, \(row.externalOutlinks ?? 0) external" })
        add("Word Count", row.wordCount.map(String.init))
        add("H1", row.h1)
        add("H2", row.h2)
        add("Canonical", row.canonical)
        add("Meta Robots", row.metaRobots)
        add("X-Robots-Tag", row.xRobotsTag)
        add("Language", row.lang)
        add("Redirects To", row.redirectURL)
        if row.javaScriptRendered {
            add("Rendered", "Yes (\(row.renderMs.map { String(format: "%.0f ms", $0) } ?? "—"))")
            add("Words", "\(row.wordCount ?? 0) rendered, \(row.rawWordCount ?? 0) in raw HTML")
            add("Links", "\(row.renderedLinkCount ?? 0) rendered, \(row.rawLinkCount ?? 0) in raw HTML")
        }
        add("In Sitemap", row.inSitemap ? "Yes" : nil)
        add("Crawled", row.crawledAt?.formatted(date: .abbreviated, time: .standard))
        return pairs
    }
}

struct MessageDTO: Codable, Sendable {
    var message: String
}
