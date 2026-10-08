import CrawlCore
import Foundation
import Parsing

/// Facts about one fetched URL, prepared by the crawler, that per-page rules evaluate.
public struct PageFacts: Sendable {
    public var url: URL
    public var isInternal: Bool
    public var siteIsHTTPS: Bool
    public var depth: Int
    public var resourceType: ResourceType
    public var statusCode: Int?
    public var failed: Bool
    public var blockedByRobots: Bool
    public var headers: [String: String]
    public var sizeBytes: Int64?
    public var responseMs: Double?

    /// Present only for internal HTML pages that returned 2xx and were parsed.
    public var page: ParsedPage?
    /// The crawl is in e-commerce mode, so products are read and checked.
    public var ecommerce = false
    public var product: ProductData?
    public var directives = RobotsDirectives()
    /// Canonical hrefs resolved and normalised.
    public var resolvedCanonicals: [String] = []
    public var internalOutlinks = 0
    public var nofollowInternalOutlinks = 0
    public var nonDescriptiveInternalAnchors = 0
    public var mixedContentResources = 0
    /// Hreflang entries with resolved, normalised URLs.
    public var resolvedHreflang: [(lang: String, url: String)] = []
    /// The raw HTML parse, kept alongside `page` (the rendered DOM) when rendering is on.
    public var rawPage: ParsedPage?
    /// Why rendering failed, when it did.
    public var renderFailure: String?

    public init(url: URL, isInternal: Bool, siteIsHTTPS: Bool, depth: Int, resourceType: ResourceType) {
        self.url = url
        self.isInternal = isInternal
        self.siteIsHTTPS = siteIsHTTPS
        self.depth = depth
        self.resourceType = resourceType
        statusCode = nil
        failed = false
        blockedByRobots = false
        headers = [:]
    }

    var isParsedPage: Bool { page != nil }
}

public struct RobotsDirectives: Sendable, Hashable {
    public var noindex = false
    public var nofollow = false

    public init() {}

    /// Combines meta robots values and X-Robots-Tag headers. Header directives can be scoped to a
    /// crawler (`googlebot: noindex`); only unscoped, Googlebot and our own token apply.
    public init(metaRobots: [String], xRobotsTag: String?, productToken: String) {
        let applicableBots: Set<String> = ["googlebot", productToken.lowercased()]
        for value in metaRobots {
            apply(value.lowercased())
        }
        guard let header = xRobotsTag?.lowercased() else { return }
        var scopeApplies = true
        for rawPart in header.split(separator: ",") {
            var part = rawPart.trimmingCharacters(in: .whitespaces)
            if let colon = part.firstIndex(of: ":") {
                let prefix = part[..<colon].trimmingCharacters(in: .whitespaces)
                if !Self.knownDirectives.contains(prefix) {
                    scopeApplies = applicableBots.contains(prefix)
                    part = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            if scopeApplies { apply(part) }
        }
    }

    private static let knownDirectives: Set<String> = ["unavailable_after", "max-snippet", "max-image-preview", "max-video-preview"]

    private mutating func apply(_ value: String) {
        for token in value.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            switch token {
            case "noindex", "none":
                noindex = true
                if token == "none" { nofollow = true }
            case "nofollow": nofollow = true
            default: break
            }
        }
    }
}

public enum PageAuditor {
    public static let genericAnchors: Set<String> = [
        "click here", "click", "here", "read more", "more", "learn more", "this page", "link", "go", "this", "more info", "find out more",
    ]

    /// Indexability status and reason, as shown in the Indexability columns.
    public static func indexability(_ facts: PageFacts) -> (Indexability, String) {
        if facts.blockedByRobots { return (.nonIndexable, "Blocked by robots.txt") }
        if facts.failed { return (.nonIndexable, "No response") }
        guard let status = facts.statusCode else { return (.nonIndexable, "No response") }
        switch status {
        case 300...399: return (.nonIndexable, "Redirected")
        case 400...499: return (.nonIndexable, "Client error")
        case 500...: return (.nonIndexable, "Server error")
        case 200...299: break
        default: return (.nonIndexable, "Non-200 status")
        }
        if facts.directives.noindex { return (.nonIndexable, "Noindex") }
        let distinct = Set(facts.resolvedCanonicals)
        if let canonical = distinct.first, distinct.count == 1, canonical != facts.url.absoluteString {
            return (.nonIndexable, "Canonicalised")
        }
        return (.indexable, "Indexable")
    }

    /// Issue codes for a single URL. Cross-page issues come from `PostCrawlAnalyzer`.
    public static func audit(_ facts: PageFacts) -> [String] {
        var issues: [String] = []
        func flag(_ code: String) { issues.append(code) }

        let status = facts.statusCode ?? 0
        let isOK = (200...299).contains(status) && !facts.failed && !facts.blockedByRobots

        if facts.isInternal {
            if facts.blockedByRobots {
                flag("response_internal_blocked_robots")
            } else if facts.failed {
                flag("response_internal_no_response")
            } else {
                switch status {
                case 300...399: flag("response_internal_3xx")
                case 400...499: flag("response_internal_4xx")
                case 500...599: flag("response_internal_5xx")
                default: break
                }
            }
            auditURL(facts, flag: flag)
        } else if !facts.failed, LinkCheck.refusedAutomatedCheck(status: facts.statusCode, headers: facts.headers) {
            flag("response_external_unverified")
        } else if facts.failed || status >= 400 {
            flag("response_external_broken")
        }

        if facts.isInternal, isOK, facts.resourceType == .image, (facts.sizeBytes ?? 0) > 100 * 1024 {
            flag("images_over_100kb")
        }

        guard facts.isInternal, isOK, let page = facts.page else { return issues }
        let (indexability, _) = indexability(facts)
        let indexable = indexability == .indexable

        if (facts.responseMs ?? 0) > 1_000 { flag("response_slow") }
        if facts.renderFailure != nil { flag("javascript_render_failed") }
        if page.metaRefresh != nil { flag("response_meta_refresh") }

        // Titles
        let title = page.titles.first ?? ""
        if title.isEmpty {
            flag("title_missing")
        } else {
            if page.titles.count > 1 { flag("title_multiple") }
            if title.count > 60 { flag("title_over_60_characters") }
            if PixelWidth.title(title) > PixelWidth.titleLimit { flag("title_over_561_pixels") }
            if title.count < 30 { flag("title_below_30_characters") }
            if let h1 = page.h1.first, h1.caseInsensitiveCompare(title) == .orderedSame { flag("title_same_as_h1") }
        }

        // Meta description
        let description = page.metaDescriptions.first ?? ""
        if description.isEmpty {
            flag("meta_description_missing")
        } else {
            if page.metaDescriptions.count > 1 { flag("meta_description_multiple") }
            if description.count > 155 { flag("meta_description_over_155_characters") }
            if PixelWidth.description(description) > PixelWidth.descriptionLimit { flag("meta_description_over_985_pixels") }
            if description.count < 70 { flag("meta_description_below_70_characters") }
        }

        // Headings
        let h1 = page.h1.first ?? ""
        if h1.isEmpty {
            flag("h1_missing")
        } else {
            if page.h1.count > 1 { flag("h1_multiple") }
            if h1.count > 70 { flag("h1_over_70_characters") }
        }
        if page.h2.allSatisfy(\.isEmpty) { flag("h2_missing") }

        // Content
        if indexable && page.wordCount < 200 { flag("content_low_word_count") }

        // Links
        if facts.nofollowInternalOutlinks > 0 { flag("links_internal_nofollow") }
        if indexable && facts.internalOutlinks == 0 { flag("links_no_internal_outlinks") }
        if facts.nonDescriptiveInternalAnchors > 0 { flag("links_non_descriptive_anchor") }
        if facts.depth >= 4 { flag("links_high_crawl_depth") }

        // Images
        let images = page.links.filter { $0.type == .image }
        if images.contains(where: { $0.flags.contains(.altAttributeMissing) }) { flag("images_missing_alt_attribute") }
        if images.contains(where: { !$0.flags.contains(.altAttributeMissing) && $0.text.isEmpty }) { flag("images_missing_alt_text") }
        if images.contains(where: { $0.text.count > 100 }) { flag("images_alt_over_100_characters") }
        if images.contains(where: { $0.flags.contains(.dimensionsMissing) }) { flag("images_missing_dimensions") }

        // Security
        if facts.url.scheme == "https" {
            if facts.mixedContentResources > 0 { flag("security_mixed_content") }
            if facts.headers["strict-transport-security"] == nil { flag("security_missing_hsts") }
        }
        if facts.headers["x-content-type-options"]?.lowercased().contains("nosniff") != true { flag("security_missing_nosniff") }
        if facts.headers["content-security-policy"] == nil { flag("security_missing_csp") }

        // Canonicals
        if page.canonicals.isEmpty {
            if indexable { flag("canonical_missing") }
        } else {
            if Set(facts.resolvedCanonicals).count > 1 { flag("canonical_multiple_conflicting") }
            if indexability == .nonIndexable, facts.resolvedCanonicals.contains(where: { $0 != facts.url.absoluteString }),
               !facts.directives.noindex {
                flag("canonical_canonicalised")
            }
            if page.canonicals.contains(where: { !$0.href.lowercased().hasPrefix("http://") && !$0.href.lowercased().hasPrefix("https://") }) {
                flag("canonical_relative")
            }
            if page.canonicals.contains(where: { !$0.inHead }) { flag("canonical_outside_head") }
        }

        // Directives
        if facts.directives.noindex { flag("directives_noindex") }
        if facts.directives.nofollow { flag("directives_nofollow") }

        // Hreflang
        if !page.hreflang.isEmpty {
            if page.hreflang.contains(where: { !HreflangValidator.isValid($0.lang) }) { flag("hreflang_invalid_code") }
            if !facts.resolvedHreflang.contains(where: { $0.url == facts.url.absoluteString }) { flag("hreflang_missing_self_reference") }
            if !page.hreflang.contains(where: { $0.lang.lowercased() == "x-default" }) { flag("hreflang_missing_x_default") }
        }

        // Structured data
        if page.jsonLD.contains(where: { $0.error != nil }) { flag("structured_data_parse_error") }

        // E-commerce. Only indexable pages: a product page canonicalised elsewhere is judged
        // by the page it points to.
        if facts.ecommerce, indexable {
            if let product = facts.product {
                if product.withPrice < product.variants { flag("ecom_product_no_price") }
                if product.withAvailability < product.variants { flag("ecom_product_no_availability") }
                if product.images == 0 { flag("ecom_product_no_image") }
                if product.withIdentifier == 0 { flag("ecom_product_no_identifier") }
            } else if EcommercePaths.product(in: facts.url) != nil {
                flag("ecom_product_schema_missing")
            }
        }

        // Raw HTML versus rendered DOM
        if let raw = facts.rawPage {
            // 50 words or a 25% jump counts as content that only exists after rendering.
            if page.wordCount > raw.wordCount + 50 || (raw.wordCount > 0 && page.wordCount > raw.wordCount * 5 / 4) {
                flag("javascript_content_only_rendered")
            }
            let rawLinks = raw.links.filter { $0.type == .anchor }.count
            let renderedLinks = page.links.filter { $0.type == .anchor }.count
            if renderedLinks > rawLinks { flag("javascript_links_only_rendered") }
            if raw.titles.first != page.titles.first { flag("javascript_title_changed") }
            if raw.metaDescriptions.first != page.metaDescriptions.first { flag("javascript_meta_description_changed") }
            if raw.canonicals.first?.href != page.canonicals.first?.href { flag("javascript_canonical_changed") }
        }

        return issues
    }

    private static func auditURL(_ facts: PageFacts, flag: (String) -> Void) {
        guard facts.resourceType == .page else { return }
        let path = facts.url.path(percentEncoded: true)
        if path.contains(where: \.isUppercase) { flag("url_uppercase") }
        if path.contains("_") { flag("url_underscores") }
        if facts.url.absoluteString.count > 115 { flag("url_over_115_characters") }
        if facts.siteIsHTTPS && facts.url.scheme == "http" { flag("url_http_on_https_site") }
    }
}

/// Validates hreflang values as Google documents them: `x-default`, or an ISO 639-1 language,
/// optionally followed by a script subtag and/or an ISO 3166-1 alpha-2 region.
public enum HreflangValidator {
    private static let languages = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
    private static let regions = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) })

    public static func isValid(_ value: String) -> Bool {
        let code = value.trimmingCharacters(in: .whitespaces)
        if code.lowercased() == "x-default" { return true }
        let parts = code.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let language = parts.first, languages.contains(language.lowercased()) else { return false }
        switch parts.count {
        case 1:
            return true
        case 2:
            return isRegion(parts[1]) || isScript(parts[1])
        case 3:
            return isScript(parts[1]) && isRegion(parts[2])
        default:
            return false
        }
    }

    private static func isRegion(_ part: String) -> Bool { regions.contains(part.uppercased()) }
    private static func isScript(_ part: String) -> Bool { part.count == 4 && part.allSatisfy(\.isLetter) }
}
