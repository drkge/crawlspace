import Foundation

/// Everything that controls a crawl. Codable so it can be saved as a preset, stored in the
/// crawl package, and passed to the CLI. Decoding tolerates missing keys so old presets keep
/// working as options are added.
public struct CrawlConfig: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case spider
        case list
        /// Crawl the URLs listed in one or more XML sitemaps.
        case sitemap

        public var label: String {
            switch self {
            case .spider: "Spider"
            case .list: "List"
            case .sitemap: "Sitemap"
            }
        }
    }

    public enum SubdomainPolicy: String, Codable, Sendable, CaseIterable {
        /// Only the start URL's exact host is internal (www and non-www differ).
        case exactHost
        /// The start host and all of its subdomains are internal.
        case allSubdomains
    }

    public var mode: Mode = .spider
    public var startURL: String = ""
    public var listURLs: [String] = []
    /// Sitemaps to read in sitemap mode, and to audit against a spider crawl.
    public var sitemapURLs: [String] = []
    /// Find sitemaps through the site's robots.txt as well.
    public var discoverSitemapsFromRobots: Bool = true

    // JavaScript rendering
    public var renderJavaScript: Bool = false
    public var renderConcurrency: Int = 4
    /// Extra wait after load for late, script-driven DOM changes.
    public var renderSettleSeconds: Double = 2
    public var storeScreenshots: Bool = false
    /// Skip images, media and fonts while rendering (much faster; screenshots lose images).
    public var renderBlockHeavyResources: Bool = false

    // Custom extraction
    public var extractors: [Extractor] = []
    public var customSearches: [CustomSearch] = []

    // Authentication
    /// Sent on internal requests. The password is kept with the app's secrets, never in the config file.
    public var basicAuthUsername: String = ""
    public var customHeaders: [String: String] = [:]
    /// `name=value; other=value` applied to internal requests, e.g. captured from a login.
    public var cookieHeader: String = ""

    // Scope
    public var subdomainPolicy: SubdomainPolicy = .exactHost
    public var crawlOutsideStartFolder: Bool = false
    public var includePatterns: [String] = []
    public var excludePatterns: [String] = []
    public var checkExternalLinks: Bool = true

    // What to follow
    public var followInternalNofollow: Bool = false
    public var followExternalNofollow: Bool = false
    public var crawlImages: Bool = true
    public var crawlCSS: Bool = true
    public var crawlJavaScript: Bool = true
    public var crawlCanonicals: Bool = true
    public var crawlHreflang: Bool = true

    // Limits
    public var maxURLs: Int = 1_000_000
    /// 0 means unlimited.
    public var maxDepth: Int = 0
    public var maxURLLength: Int = 2_000
    /// Caps distinct query strings per path (0 means unlimited). Without this, calendar and
    /// faceted-navigation traps generate URLs forever, which matters most for unattended crawls.
    public var maxQueryVariantsPerPath: Int = 1_000
    /// A URL whose path repeats any one segment more than this many times is skipped.
    public var maxPathSegmentRepeats: Int = 3
    public var maxRedirectsToFollow: Int = 10

    // Speed
    public var concurrency: Int = 5
    /// Treat `concurrency` as a ceiling and find a kinder number under it when a server strains.
    public var automaticConcurrency = true
    /// 0 means no rate cap (concurrency still applies).
    public var maxURLsPerSecond: Double = 0
    public var timeoutSeconds: Double = 20

    // Robots & identity
    public var respectRobotsTxt: Bool = true
    /// Leave URLs robots.txt blocks out of the reports: they're listed under Not Crawled with the
    /// reason, rather than as crawled URLs each carrying a "blocked" warning. Worth it where the
    /// platform writes the robots.txt — on a Shopify store half a crawl can be filter pages it
    /// blocks by design.
    public var skipRobotsBlocked: Bool = false
    /// Which platform's defaults to apply when the crawl starts. `.automatic` looks at the start URL.
    public var platformProfile: PlatformProfile = .automatic
    /// The profile actually applied at the start, e.g. "Shopify", for saying so in the app.
    public var appliedProfile: String?
    /// Read products and run the e-commerce checks. `.automatic` turns on for a Shopify store.
    public var ecommerceMode: EcommerceMode = .automatic
    /// What `ecommerceMode` came to when the crawl started; this is what the crawl acts on.
    public var ecommerceActive: Bool = false
    /// Just the name. It used to carry a link to the repository, which is private and has since
    /// moved, so anyone following it from their server logs hit a 404.
    public var userAgent: String = "Crawlspace/1.0"
    /// Product token matched against robots.txt `User-agent` lines.
    public var robotsUserAgentToken: String = "Crawlspace"

    // Content
    /// Query parameters removed during normalisation. `*` suffix matches a prefix (e.g. `utm_*`).
    public var stripQueryParameters: [String] = []
    public var storeHTML: Bool = false
    public var maxHTMLBytes: Int = 50 * 1024 * 1024

    // Speed
    /// Run Lighthouse, mobile and desktop, on this many of the most-linked indexable pages once the
    /// crawl finishes. 0 turns it off.
    public var lighthouseTopPages: Int = 25
    /// On a Shopify store, measure one page of each theme template (home, collection, products,
    /// cart, search, blog, page) instead of the most-linked pages.
    public var lighthouseShopifyTemplates: Bool = true

    public init() {}

    public init(startURL: String) {
        self.startURL = startURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CrawlConfig()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        mode = try v(.mode, d.mode)
        startURL = try v(.startURL, d.startURL)
        listURLs = try v(.listURLs, d.listURLs)
        sitemapURLs = try v(.sitemapURLs, d.sitemapURLs)
        discoverSitemapsFromRobots = try v(.discoverSitemapsFromRobots, d.discoverSitemapsFromRobots)
        renderJavaScript = try v(.renderJavaScript, d.renderJavaScript)
        renderConcurrency = try v(.renderConcurrency, d.renderConcurrency)
        renderSettleSeconds = try v(.renderSettleSeconds, d.renderSettleSeconds)
        storeScreenshots = try v(.storeScreenshots, d.storeScreenshots)
        renderBlockHeavyResources = try v(.renderBlockHeavyResources, d.renderBlockHeavyResources)
        extractors = try v(.extractors, d.extractors)
        customSearches = try v(.customSearches, d.customSearches)
        basicAuthUsername = try v(.basicAuthUsername, d.basicAuthUsername)
        customHeaders = try v(.customHeaders, d.customHeaders)
        cookieHeader = try v(.cookieHeader, d.cookieHeader)
        subdomainPolicy = try v(.subdomainPolicy, d.subdomainPolicy)
        crawlOutsideStartFolder = try v(.crawlOutsideStartFolder, d.crawlOutsideStartFolder)
        includePatterns = try v(.includePatterns, d.includePatterns)
        excludePatterns = try v(.excludePatterns, d.excludePatterns)
        checkExternalLinks = try v(.checkExternalLinks, d.checkExternalLinks)
        followInternalNofollow = try v(.followInternalNofollow, d.followInternalNofollow)
        followExternalNofollow = try v(.followExternalNofollow, d.followExternalNofollow)
        crawlImages = try v(.crawlImages, d.crawlImages)
        crawlCSS = try v(.crawlCSS, d.crawlCSS)
        crawlJavaScript = try v(.crawlJavaScript, d.crawlJavaScript)
        crawlCanonicals = try v(.crawlCanonicals, d.crawlCanonicals)
        crawlHreflang = try v(.crawlHreflang, d.crawlHreflang)
        maxURLs = try v(.maxURLs, d.maxURLs)
        maxDepth = try v(.maxDepth, d.maxDepth)
        maxURLLength = try v(.maxURLLength, d.maxURLLength)
        maxQueryVariantsPerPath = try v(.maxQueryVariantsPerPath, d.maxQueryVariantsPerPath)
        maxPathSegmentRepeats = try v(.maxPathSegmentRepeats, d.maxPathSegmentRepeats)
        maxRedirectsToFollow = try v(.maxRedirectsToFollow, d.maxRedirectsToFollow)
        concurrency = try v(.concurrency, d.concurrency)
        automaticConcurrency = try v(.automaticConcurrency, d.automaticConcurrency)
        maxURLsPerSecond = try v(.maxURLsPerSecond, d.maxURLsPerSecond)
        timeoutSeconds = try v(.timeoutSeconds, d.timeoutSeconds)
        respectRobotsTxt = try v(.respectRobotsTxt, d.respectRobotsTxt)
        skipRobotsBlocked = try v(.skipRobotsBlocked, d.skipRobotsBlocked)
        platformProfile = try v(.platformProfile, d.platformProfile)
        appliedProfile = try c.decodeIfPresent(String.self, forKey: .appliedProfile)
        ecommerceMode = try v(.ecommerceMode, d.ecommerceMode)
        ecommerceActive = try v(.ecommerceActive, d.ecommerceActive)
        userAgent = try v(.userAgent, d.userAgent)
        robotsUserAgentToken = try v(.robotsUserAgentToken, d.robotsUserAgentToken)
        stripQueryParameters = try v(.stripQueryParameters, d.stripQueryParameters)
        storeHTML = try v(.storeHTML, d.storeHTML)
        maxHTMLBytes = try v(.maxHTMLBytes, d.maxHTMLBytes)
        lighthouseTopPages = try v(.lighthouseTopPages, d.lighthouseTopPages)
        lighthouseShopifyTemplates = try v(.lighthouseShopifyTemplates, d.lighthouseShopifyTemplates)
    }

    /// Problems that should stop a crawl from starting.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        switch mode {
        case .spider:
            if URLNormalizer.normalize(startURL) == nil {
                errors.append("Enter a valid http:// or https:// start URL.")
            }
        case .list:
            if listURLs.compactMap({ URLNormalizer.normalize($0) }).isEmpty {
                errors.append("The URL list doesn't contain any valid http:// or https:// URLs.")
            }
        case .sitemap:
            if sitemapURLs.compactMap({ URLNormalizer.normalize($0) }).isEmpty {
                errors.append("Enter at least one valid XML sitemap URL.")
            }
        }
        if renderJavaScript, renderConcurrency < 1 || renderConcurrency > 8 {
            errors.append("Rendering concurrency must be between 1 and 8.")
        }
        if concurrency < 1 || concurrency > 100 { errors.append("Concurrency must be between 1 and 100.") }
        if maxURLs < 1 { errors.append("Max URLs must be at least 1.") }
        if timeoutSeconds < 1 { errors.append("Timeout must be at least 1 second.") }
        for pattern in includePatterns + excludePatterns where (try? NSRegularExpression(pattern: pattern)) == nil {
            errors.append("Invalid regular expression: \(pattern)")
        }
        for extractor in extractors where !extractor.isValid {
            errors.append("Check the custom extractor “\(extractor.name.isEmpty ? extractor.expression : extractor.name)”.")
        }
        for search in customSearches where !search.isValid {
            errors.append("Check the custom search “\(search.name.isEmpty ? search.term : search.name)”.")
        }
        return errors
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
