import CrawlCore

/// Everything extracted from one HTML document. URLs are raw attribute values; the crawler
/// resolves them against `baseHref` (or the page URL).
public struct ParsedPage: Sendable {
    public var titles: [String] = []
    public var metaDescriptions: [String] = []
    /// Directive values from `<meta name="robots">` and crawler-specific robots meta tags.
    public var metaRobots: [String] = []
    public var h1: [String] = []
    public var h2: [String] = []
    public var canonicals: [Canonical] = []
    public var baseHref: String?
    public var lang: String?
    public var hreflang: [Hreflang] = []
    public var links: [Link] = []
    public var jsonLD: [JSONLDBlock] = []
    public var metaRefresh: String?
    public var wordCount: Int = 0
    /// FNV-1a hash of the lowercased, whitespace-collapsed body text (exact-duplicate detection).
    public var contentHash: UInt64 = 0
    /// Fingerprint used to find near-duplicates.
    public var simhash: UInt64 = 0
    /// Custom extractor results, keyed by extractor name.
    public var extractions: [String: String] = [:]
    /// Custom search results, keyed by search name.
    public var searchHits: [String: Bool] = [:]

    public struct Canonical: Sendable, Hashable {
        public var href: String
        public var inHead: Bool
    }

    public struct Hreflang: Sendable, Hashable {
        public var lang: String
        public var href: String
    }

    public struct Link: Sendable, Hashable {
        public var href: String
        public var type: LinkType
        /// Anchor text for hyperlinks, alt text for images.
        public var text: String
        public var flags: LinkFlags
    }

    public struct JSONLDBlock: Sendable, Hashable {
        public var types: [String]
        public var error: String?
        /// Product and ProductGroup data found in the block.
        public var products: [ProductData] = []
    }

    /// The page's product, when its structured data describes one.
    public var product: ProductData? { ProductData.merged(jsonLD.flatMap(\.products)) }

    public init() {}
}
