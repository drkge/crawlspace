import Foundation

/// Crawl defaults suited to the platform a site runs on.
public enum PlatformProfile: String, Codable, Sendable, CaseIterable {
    /// Look at the start URL and apply the matching profile, if any.
    case automatic
    case shopify
    /// No platform defaults: crawl exactly as configured.
    case none

    public var label: String {
        switch self {
        case .automatic: "Detect automatically"
        case .shopify: "Shopify"
        case .none: "None"
        }
    }
}

/// Whether a crawl looks at the site as a shop: product data, and the checks that go with it.
public enum EcommerceMode: String, Codable, Sendable, CaseIterable {
    /// On for a Shopify store, off otherwise.
    case automatic
    case on
    case off

    public var label: String {
        switch self {
        case .automatic: "Automatic (on for Shopify)"
        case .on: "On"
        case .off: "Off"
        }
    }
}

/// What a Shopify store needs left out of a crawl.
///
/// On a typical store most internal URLs are storefront filter combinations, product variants and
/// share buttons — every one a copy of a page already crawled, or somewhere a crawler can't go. None of it is anything the
/// store owner can or should fix, and it roughly doubled the crawl.
public enum ShopifyProfile {
    public struct Exclusion: Sendable, Hashable {
        public var pattern: String
        public var reason: String
    }

    /// Matched against the full URL, so each is anchored to the part of it it means: a blog post
    /// called "search-tips" isn't the site search.
    public static let exclusions: [Exclusion] = [
        .init(pattern: #"[?&]filter\."#, reason: "Storefront filters — every combination is its own URL"),
        .init(pattern: #"[?&]sort_by="#, reason: "Collection sorting"),
        .init(pattern: #"^https?://[^/]+(/[a-z]{2}(-[a-z]{2})?)?/search([/?#]|$)"#, reason: "Site search results"),
        // The tag sits after the collection's handle — /collections/candles/beeswax+unscented — which is
        // what Shopify's own robots.txt rule matches too.
        .init(pattern: #"/collections/[^?#]*(\+|%2[bB])"#, reason: "Collection tag combinations"),
        .init(pattern: #"[?&](oseid|preview_theme_id|preview_script_id)="#, reason: "Theme previews and tracking"),
        .init(pattern: #"^https?://(www\.)?(facebook\.com/sharer|(twitter|x)\.com/intent|pinterest\.[a-z.]+/pin/create|linkedin\.com/(share|shareArticle)|wa\.me/|api\.whatsapp\.com/send)"#,
              reason: "Share buttons"),
        .init(pattern: #"^https?://(www\.)?shopify\.com/\d+/account"#, reason: "Shopify customer accounts"),
    ]

    /// Parameters removed from every URL rather than the URLs being skipped. A product card's link
    /// is /products/x?variant=123, and that is a link to the product: dropping it would leave
    /// every product looking as though no collection lists it, which is what happened when these
    /// were exclusions.
    public static let strippedParameters: [Exclusion] = [
        .init(pattern: "variant", reason: "Product variants — a link to ?variant=1 is a link to the product page"),
        .init(pattern: "_pos", reason: "Search and recommendation tracking"),
        .init(pattern: "_psq", reason: "Search and recommendation tracking"),
        .init(pattern: "_ss", reason: "Search and recommendation tracking"),
        .init(pattern: "_v", reason: "Search and recommendation tracking"),
        .init(pattern: "_sid", reason: "Search and recommendation tracking"),
        .init(pattern: "_fid", reason: "Search and recommendation tracking"),
        .init(pattern: "pr_prod_strat", reason: "Product recommendation tracking"),
        .init(pattern: "pr_rec_id", reason: "Product recommendation tracking"),
        .init(pattern: "pr_rec_pid", reason: "Product recommendation tracking"),
        .init(pattern: "pr_ref_pid", reason: "Product recommendation tracking"),
        .init(pattern: "pr_seq", reason: "Product recommendation tracking"),
    ]

    /// Folds the profile into a crawl's settings, adding only what isn't there already, so what
    /// was applied stays visible — and removable — in the crawl's configuration.
    public static func apply(to config: inout CrawlConfig) {
        config.skipRobotsBlocked = true
        for exclusion in exclusions where !config.excludePatterns.contains(exclusion.pattern) {
            config.excludePatterns.append(exclusion.pattern)
        }
        for parameter in strippedParameters where !config.stripQueryParameters.contains(parameter.pattern) {
            config.stripQueryParameters.append(parameter.pattern)
        }
        config.appliedProfile = "Shopify"
    }

    /// Headers a Shopify storefront sends with every page.
    static let headerNames = ["x-shopid", "x-shopify-stage", "x-shardid"]

    /// Whether a response came from a Shopify storefront.
    public static func recognises(headers: [String: String], body: String?) -> Bool {
        let names = Set(headers.keys.map { $0.lowercased() })
        if headerNames.contains(where: names.contains) { return true }
        if headers.contains(where: { $0.key.lowercased() == "powered-by" && $0.value.localizedCaseInsensitiveContains("shopify") }) {
            return true
        }
        guard let body else { return false }
        return body.contains("cdn.shopify.com") || body.contains("Shopify.theme")
    }
}
