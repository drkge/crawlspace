import CrawlCore
import Foundation

/// Identity and discovery details of a URL.
public struct DiscoveredURL: Sendable, Hashable {
    public var id: Int64
    public var url: String
    public var host: String
    public var isInternal: Bool
    public var depth: Int
    public var state: URLState
    public var foundVia: FoundVia
    public var resourceType: ResourceType
    public var skipReason: String?

    public init(id: Int64, url: String, host: String, isInternal: Bool, depth: Int, state: URLState,
                foundVia: FoundVia, resourceType: ResourceType, skipReason: String? = nil) {
        self.id = id
        self.url = url
        self.host = host
        self.isInternal = isInternal
        self.depth = depth
        self.state = state
        self.foundVia = foundVia
        self.resourceType = resourceType
        self.skipReason = skipReason
    }
}

public struct PageRecord: Sendable, Hashable {
    public var title: String?
    public var titleLength: Int
    public var titlePixels: Double
    public var titleCount: Int
    public var metaDescription: String?
    public var metaDescriptionLength: Int
    public var metaDescriptionPixels: Double
    public var metaDescriptionCount: Int
    public var h1: String?
    public var h1Length: Int
    public var h1Count: Int
    public var h1Second: String?
    public var h2: String?
    public var h2Count: Int
    public var canonical: String?
    public var canonicalID: Int64?
    public var canonicalCount: Int
    public var metaRobots: String?
    public var lang: String?
    public var wordCount: Int
    public var contentHash: UInt64
    public var outlinks: Int
    public var externalOutlinks: Int
    public var hreflangCount: Int
    public var structuredDataCount: Int
    /// Set when the page's fields came from the rendered DOM rather than the raw HTML.
    public var javaScriptRendered = false
    public var rawWordCount: Int?
    public var rawLinkCount: Int?
    public var renderedLinkCount: Int?
    public var renderMs: Double?
    public var simhash: UInt64 = 0
    /// Custom extractor results, keyed by extractor name.
    public var extractions: [String: String] = [:]
    /// Names of the custom searches this page matched.
    public var searchHits: [String] = []

    public init() {
        titleLength = 0; titlePixels = 0; titleCount = 0
        metaDescriptionLength = 0; metaDescriptionPixels = 0; metaDescriptionCount = 0
        h1Length = 0; h1Count = 0; h2Count = 0; canonicalCount = 0
        wordCount = 0; contentHash = 0; outlinks = 0; externalOutlinks = 0
        hreflangCount = 0; structuredDataCount = 0
    }
}

public struct CrawledURL: Sendable {
    public var discovery: DiscoveredURL
    public var statusCode: Int?
    public var statusText: String?
    public var error: String?
    public var blockedByRobots: Bool = false
    public var contentType: String?
    public var sizeBytes: Int64?
    public var responseMs: Double?
    public var ttfbMs: Double?
    public var redirectURL: String?
    public var redirectToID: Int64?
    public var headers: [String: String] = [:]
    public var xRobotsTag: String?
    public var crawledAt = Date()
    public var indexability: Indexability = .unknown
    public var indexabilityReason: String?
    public var page: PageRecord?
    /// Product structured data, kept only when the crawl is in e-commerce mode.
    public var product: ProductData?

    public init(discovery: DiscoveredURL) {
        self.discovery = discovery
    }
}

public struct LinkRecord: Sendable, Hashable {
    public var sourceID: Int64
    public var targetID: Int64
    public var type: LinkType
    public var flags: LinkFlags
    public var text: String

    public init(sourceID: Int64, targetID: Int64, type: LinkType, flags: LinkFlags, text: String) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.type = type
        self.flags = flags
        self.text = text
    }
}

public struct HreflangRecord: Sendable, Hashable {
    public var lang: String
    public var targetID: Int64

    public init(lang: String, targetID: Int64) {
        self.lang = lang
        self.targetID = targetID
    }
}

public struct StructuredDataRecord: Sendable, Hashable {
    public var types: [String]
    public var error: String?

    public init(types: [String], error: String?) {
        self.types = types
        self.error = error
    }
}

public struct SitemapRecord: Sendable, Hashable {
    public var url: String
    public var kind: String?
    public var entryCount: Int
    public var statusCode: Int?
    public var error: String?

    public init(url: String, kind: String?, entryCount: Int, statusCode: Int?, error: String?) {
        self.url = url
        self.kind = kind
        self.entryCount = entryCount
        self.statusCode = statusCode
        self.error = error
    }
}

public struct SitemapURLRecord: Sendable, Hashable {
    public var url: String
    public var sitemap: String
    public var lastModified: String?

    public init(url: String, sitemap: String, lastModified: String?) {
        self.url = url
        self.sitemap = sitemap
        self.lastModified = lastModified
    }
}

public enum WriteOperation: Sendable {
    /// Insert a newly discovered URL (no-op if a crawl result already created the row).
    case discover(DiscoveredURL)
    /// A skipped URL becomes crawlable (e.g. first seen via nofollow, later via a followed link).
    case requeue(id: Int64, depth: Int)
    /// Upsert a URL's crawl result along with everything extracted from it.
    case crawled(CrawledURL, issues: [String], links: [LinkRecord], hreflang: [HreflangRecord],
                 structuredData: [StructuredDataRecord], html: Data?,
                 renderedHTML: Data? = nil, screenshot: Data? = nil)
    /// A sitemap that was read (or failed to be read).
    case sitemap(SitemapRecord, urls: [SitemapURLRecord])
}
