import Storage

public enum IssueSeverity: Int, Sendable, CaseIterable, Comparable, Codable {
    case error = 0
    case warning = 1
    case notice = 2

    public var label: String {
        switch self {
        case .error: "Errors"
        case .warning: "Warnings"
        case .notice: "Notices"
        }
    }

    /// Lowercase, as the CLI spells it.
    public var name: String {
        switch self {
        case .error: "error"
        case .warning: "warning"
        case .notice: "notice"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum IssueCategory: String, Sendable, CaseIterable, Codable {
    case responseCodes = "Response Codes"
    case links = "Links"
    case url = "URL"
    case security = "Security"
    case titles = "Page Titles"
    case metaDescription = "Meta Description"
    case h1 = "H1"
    case h2 = "H2"
    case content = "Content"
    case images = "Images"
    case canonicals = "Canonicals"
    case directives = "Directives"
    case hreflang = "Hreflang"
    case structuredData = "Structured Data"
    case javaScript = "JavaScript"
    case sitemaps = "Sitemaps"
    case ecommerce = "E-commerce"
    case speed = "Speed"
}

public struct IssueDefinition: Sendable, Identifiable, Hashable {
    public let code: String
    public let category: IssueCategory
    public let severity: IssueSeverity
    public let title: String
    public let description: String
    public let howToFix: String
    /// Extra columns worth showing when viewing URLs with this issue.
    public let columns: [URLColumn]
    /// Computed by `PostCrawlAnalyzer` after the crawl rather than while fetching.
    public let postCrawl: Bool

    public var id: String { code }

    /// Columns for a table of URLs with this issue.
    public var tableColumns: [URLColumn] {
        var result: [URLColumn] = [.address]
        for column in columns + [.statusCode, .status, .indexability, .inlinks] where !result.contains(column) {
            result.append(column)
        }
        return result
    }
}

public enum IssueCatalogue {
    public static func definition(for code: String) -> IssueDefinition? { byCode[code] }

    private static let byCode: [String: IssueDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    public static var postCrawlCodes: [String] { all.filter(\.postCrawl).map(\.code) }

    private static func issue(
        _ code: String, _ category: IssueCategory, _ severity: IssueSeverity, _ title: String,
        _ description: String, fix: String, columns: [URLColumn] = [], post: Bool = false
    ) -> IssueDefinition {
        IssueDefinition(code: code, category: category, severity: severity, title: title,
                        description: description, howToFix: fix, columns: columns, postCrawl: post)
    }

    public static let all: [IssueDefinition] = [
        // Response codes
        issue("response_internal_blocked_robots", .responseCodes, .warning, "Internal Blocked by Robots.txt",
              "Internal URLs that robots.txt stops search engines from crawling. They can still be indexed (without content) if linked.",
              fix: "Check that blocking is intentional. Use noindex instead of robots.txt to keep a crawlable page out of search results."),
        issue("response_internal_no_response", .responseCodes, .error, "Internal No Response",
              "Internal URLs that didn't respond: a timeout, DNS failure, refused connection or TLS error.",
              fix: "Check the server and firewall for these URLs, and whether the crawler is being rate limited or blocked."),
        issue("response_internal_3xx", .responseCodes, .warning, "Internal Redirection (3xx)",
              "Internal URLs that redirect. Linking to redirects wastes crawl budget and adds latency for users.",
              fix: "Update internal links to point at the final destination URL.", columns: [.redirectURL]),
        issue("response_internal_4xx", .responseCodes, .error, "Internal Client Error (4xx)",
              "Internal URLs returning a client error such as 404 Not Found or 410 Gone.",
              fix: "Fix or remove links to these URLs, or redirect them to the most relevant live page."),
        issue("response_internal_5xx", .responseCodes, .error, "Internal Server Error (5xx)",
              "Internal URLs where the server failed to respond correctly. Persistent 5xx errors can lead to de-indexing.",
              fix: "Check server logs for these URLs and fix the underlying errors."),
        issue("response_external_broken", .responseCodes, .warning, "External Broken (4xx/5xx/No Response)",
              "External URLs linked from the site that return an error or don't respond.",
              fix: "Update or remove links to broken external resources."),
        issue("response_external_unverified", .responseCodes, .notice, "External Refused an Automated Check",
              "External URLs that answered the crawler with 401, 402, 403, 406, 429 or a bot challenge. Sites behind Cloudflare and similar services, paywalls and research publishers do this to crawlers while serving people normally, so these usually work.",
              fix: "Open each one in a browser. Only those that fail there too need fixing; the rest are fine."),
        issue("response_slow", .responseCodes, .notice, "Slow Response (over 1 second)",
              "Internal HTML pages that took more than one second to download.",
              fix: "Investigate server response time, caching and page weight for these URLs.", columns: [.responseMs, .ttfbMs, .sizeBytes]),
        issue("response_meta_refresh", .responseCodes, .warning, "Meta Refresh Redirect",
              "Pages that redirect using a meta refresh tag rather than an HTTP redirect.",
              fix: "Replace meta refresh redirects with server-side 301 redirects."),
        issue("redirect_chain", .responseCodes, .warning, "Redirect Chain",
              "Redirects that lead to another redirect before reaching the final URL.",
              fix: "Point each redirect straight at the final destination.", columns: [.redirectURL], post: true),
        issue("redirect_loop", .responseCodes, .error, "Redirect Loop",
              "Redirects that eventually point back to themselves, so the page can never load.",
              fix: "Break the loop so the redirect resolves to a live 200 page.", columns: [.redirectURL], post: true),

        // Links
        issue("links_to_broken_internal", .links, .error, "Links to Broken Internal URLs",
              "Pages linking to internal URLs that return 4xx or 5xx errors.",
              fix: "Open the Outlinks tab for each page and update or remove the broken links.", columns: [.outlinks], post: true),
        issue("links_to_redirect_internal", .links, .notice, "Links to Internal Redirects",
              "Pages linking to internal URLs that redirect.",
              fix: "Update these links to point at the redirect's final destination.", columns: [.outlinks], post: true),
        issue("links_to_broken_external", .links, .warning, "Links to Broken External URLs",
              "Pages linking to external URLs that return errors or don't respond.",
              fix: "Update or remove the broken external links.", columns: [.externalOutlinks], post: true),
        issue("links_to_unverified_external", .links, .notice, "Links to External URLs That Refused a Check",
              "Pages linking to external URLs that wouldn't answer an automated request — bot protection, paywalls or sign-in. They usually work in a browser.",
              fix: "Click the links on these pages. Only replace the ones that don't open for a person either.",
              columns: [.externalOutlinks], post: true),
        issue("links_internal_nofollow", .links, .notice, "Internal Nofollow Links",
              "Pages with rel=\"nofollow\" on links to other internal pages, which stops link equity flowing through the site.",
              fix: "Remove nofollow from internal links unless you deliberately don't want those pages crawled.", columns: [.outlinks]),
        issue("links_no_internal_outlinks", .links, .warning, "No Internal Outlinks",
              "Indexable pages that don't link to any other internal page, creating dead ends for users and crawlers.",
              fix: "Add relevant internal links, such as navigation or related content.", columns: [.outlinks]),
        issue("links_non_descriptive_anchor", .links, .notice, "Non-Descriptive Anchor Text",
              "Pages with internal links using generic anchor text such as \"click here\" or \"read more\".",
              fix: "Use anchor text that describes the destination page."),
        issue("links_high_crawl_depth", .links, .notice, "Crawl Depth 4+",
              "Pages that are four or more clicks from the start URL. Deep pages tend to be crawled less often and rank less well.",
              fix: "Link to important pages from higher up the site structure.", columns: [.depth]),

        // URL
        issue("url_uppercase", .url, .notice, "Uppercase Characters",
              "URLs containing uppercase characters, which can cause duplicate URLs on case-insensitive servers.",
              fix: "Use lowercase URLs and redirect uppercase variants."),
        issue("url_underscores", .url, .notice, "Underscores",
              "URLs using underscores. Google recommends hyphens to separate words.",
              fix: "Prefer hyphens in new URLs; changing existing ones needs redirects."),
        issue("url_over_115_characters", .url, .notice, "Over 115 Characters",
              "Long URLs are harder to share and are often truncated in search results.",
              fix: "Keep URLs short and descriptive."),
        issue("url_http_on_https_site", .url, .warning, "HTTP URL on HTTPS Site",
              "Internal http:// URLs found on a site whose start URL is https://.",
              fix: "Redirect HTTP to HTTPS and update internal links to use https://."),

        // Security
        issue("security_mixed_content", .security, .warning, "Mixed Content",
              "HTTPS pages loading images, scripts, stylesheets or iframes over insecure http://.",
              fix: "Load every resource over HTTPS."),
        issue("security_missing_hsts", .security, .notice, "Missing HSTS Header",
              "HTTPS pages without a Strict-Transport-Security header, so browsers may still try HTTP first.",
              fix: "Send Strict-Transport-Security with an appropriate max-age."),
        issue("security_missing_nosniff", .security, .notice, "Missing X-Content-Type-Options",
              "Pages without X-Content-Type-Options: nosniff, which prevents browsers guessing content types.",
              fix: "Send X-Content-Type-Options: nosniff."),
        issue("security_missing_csp", .security, .notice, "Missing Content-Security-Policy",
              "Pages without a Content-Security-Policy header to restrict where resources can load from.",
              fix: "Define a Content-Security-Policy suited to the site."),

        // Titles
        issue("title_missing", .titles, .error, "Missing",
              "Pages with no <title> element, or an empty one. Titles are a key relevance signal and shown in search results.",
              fix: "Write a unique, descriptive title for every page.", columns: [.title, .titleLength]),
        issue("title_multiple", .titles, .warning, "Multiple",
              "Pages with more than one <title> element. Search engines may pick the wrong one.",
              fix: "Keep a single <title> in the <head>.", columns: [.title, .titleCount]),
        issue("title_duplicate", .titles, .warning, "Duplicate",
              "Indexable pages sharing the same title, which makes it hard for search engines to tell them apart.",
              fix: "Give each page a unique title.", columns: [.title, .titleLength], post: true),
        issue("title_over_60_characters", .titles, .notice, "Over 60 Characters",
              "Titles longer than 60 characters may be truncated in search results.",
              fix: "Put the most important words first and shorten where possible.", columns: [.title, .titleLength, .titlePixels]),
        issue("title_over_561_pixels", .titles, .warning, "Over 561 Pixels",
              "Titles wider than Google's desktop display width, so they are likely to be truncated.",
              fix: "Shorten the title to fit within roughly 561 pixels.", columns: [.title, .titleLength, .titlePixels]),
        issue("title_below_30_characters", .titles, .notice, "Below 30 Characters",
              "Short titles may be missing useful keywords or context.",
              fix: "Expand the title to describe the page more fully.", columns: [.title, .titleLength]),
        issue("title_same_as_h1", .titles, .notice, "Same as H1",
              "The title exactly matches the page's H1, a missed chance to target related wording.",
              fix: "Consider varying the title and H1.", columns: [.title, .h1]),

        // Meta description
        issue("meta_description_missing", .metaDescription, .warning, "Missing",
              "Pages without a meta description. Search engines will generate a snippet from page content.",
              fix: "Write a compelling, unique meta description for important pages.", columns: [.metaDescription]),
        issue("meta_description_multiple", .metaDescription, .warning, "Multiple",
              "Pages with more than one meta description tag.",
              fix: "Keep a single meta description.", columns: [.metaDescription, .metaDescriptionCount]),
        issue("meta_description_duplicate", .metaDescription, .warning, "Duplicate",
              "Indexable pages sharing the same meta description.",
              fix: "Write a unique description for each page.", columns: [.metaDescription, .metaDescriptionLength], post: true),
        issue("meta_description_over_155_characters", .metaDescription, .notice, "Over 155 Characters",
              "Descriptions longer than 155 characters may be truncated in search results.",
              fix: "Keep the key message within the first 155 characters.", columns: [.metaDescription, .metaDescriptionLength, .metaDescriptionPixels]),
        issue("meta_description_over_985_pixels", .metaDescription, .notice, "Over 985 Pixels",
              "Descriptions wider than Google's desktop snippet width.",
              fix: "Shorten the description.", columns: [.metaDescription, .metaDescriptionLength, .metaDescriptionPixels]),
        issue("meta_description_below_70_characters", .metaDescription, .notice, "Below 70 Characters",
              "Very short descriptions may not persuade people to click.",
              fix: "Expand the description to summarise the page.", columns: [.metaDescription, .metaDescriptionLength]),

        // Headings
        issue("h1_missing", .h1, .warning, "Missing",
              "Pages without an H1 heading.",
              fix: "Add one clear H1 that describes the page.", columns: [.h1, .h1Count]),
        issue("h1_multiple", .h1, .notice, "Multiple",
              "Pages with more than one H1. Not an error, but a single H1 usually gives clearer structure.",
              fix: "Consider using one H1 with H2s for sections.", columns: [.h1, .h1Second, .h1Count]),
        issue("h1_duplicate", .h1, .notice, "Duplicate",
              "Indexable pages sharing the same H1.",
              fix: "Make each page's H1 unique.", columns: [.h1], post: true),
        issue("h1_over_70_characters", .h1, .notice, "Over 70 Characters",
              "Long H1s can be less clear to users.",
              fix: "Keep the H1 concise.", columns: [.h1, .h1Length]),
        issue("h2_missing", .h2, .notice, "Missing",
              "Pages without any H2 headings to structure the content.",
              fix: "Use H2s to break content into sections.", columns: [.h2, .h2Count]),

        // Content
        issue("content_low_word_count", .content, .notice, "Low Content (under 200 words)",
              "Indexable pages with little visible text, which can be seen as thin content.",
              fix: "Add useful content, or consider whether the page should be indexed.", columns: [.wordCount]),
        issue("content_near_duplicate", .content, .warning, "Near Duplicates",
              "Indexable pages whose text is almost the same as another page's — often thin variations such as location or filter pages.",
              fix: "Consolidate them, differentiate the content, or canonicalise the variants to one page.",
              columns: [.wordCount, .canonical], post: true),
        issue("content_exact_duplicate", .content, .warning, "Exact Duplicates",
              "Indexable pages whose visible text is identical to another page's.",
              fix: "Consolidate duplicates with redirects or canonical tags, or differentiate the content.", columns: [.wordCount, .canonical], post: true),

        // Images
        issue("images_missing_alt_attribute", .images, .warning, "Missing Alt Attribute",
              "Pages containing images with no alt attribute at all, which hurts accessibility and image search.",
              fix: "Add alt text to meaningful images, or alt=\"\" to decorative ones."),
        issue("images_missing_alt_text", .images, .notice, "Missing Alt Text",
              "Pages containing images with an empty alt attribute. Correct for decorative images only.",
              fix: "Check each image; describe any that convey information."),
        issue("images_alt_over_100_characters", .images, .notice, "Alt Text Over 100 Characters",
              "Pages with very long alt text, which is tedious for screen reader users.",
              fix: "Keep alt text concise."),
        issue("images_missing_dimensions", .images, .notice, "Missing Size Attributes",
              "Pages with images lacking width and height attributes, which causes layout shift (CLS).",
              fix: "Add width and height attributes (or CSS aspect-ratio) to images."),
        issue("images_over_100kb", .images, .warning, "Over 100 KB",
              "Image files larger than 100 KB, which slow page loads.",
              fix: "Compress images, serve modern formats (WebP/AVIF) and size them for their display dimensions.", columns: [.sizeBytes]),

        // Canonicals
        issue("canonical_missing", .canonicals, .notice, "Missing",
              "Indexable pages without a canonical link.",
              fix: "Add a self-referencing canonical to indexable pages.", columns: [.canonical]),
        issue("canonical_canonicalised", .canonicals, .notice, "Canonicalised",
              "Pages whose canonical points to a different URL, so they are unlikely to be indexed themselves.",
              fix: "Check the canonical is intended, and avoid linking internally to canonicalised URLs.", columns: [.canonical, .indexabilityReason]),
        issue("canonical_multiple_conflicting", .canonicals, .error, "Multiple Conflicting",
              "Pages declaring more than one different canonical URL. Search engines may ignore them all.",
              fix: "Keep a single canonical link.", columns: [.canonical, .canonicalCount]),
        issue("canonical_relative", .canonicals, .notice, "Relative URL",
              "Canonicals using relative URLs, which are easy to get wrong.",
              fix: "Use absolute URLs for canonicals.", columns: [.canonical]),
        issue("canonical_outside_head", .canonicals, .warning, "Outside <head>",
              "Canonical links found in the <body>, which search engines ignore.",
              fix: "Move the canonical link into the <head>.", columns: [.canonical]),
        issue("canonical_target_non_200", .canonicals, .error, "Canonical Points to Non-200",
              "Pages whose canonical URL redirects, errors or doesn't respond.",
              fix: "Point canonicals at live 200 URLs.", columns: [.canonical], post: true),
        issue("canonical_target_non_indexable", .canonicals, .warning, "Canonical Points to Non-Indexable",
              "Pages whose canonical URL is itself non-indexable (noindex, canonicalised elsewhere or blocked).",
              fix: "Point canonicals at indexable URLs.", columns: [.canonical], post: true),

        // Directives
        issue("directives_noindex", .directives, .warning, "Noindex",
              "Pages telling search engines not to index them, via meta robots or X-Robots-Tag.",
              fix: "Check each noindex is intentional.", columns: [.metaRobots, .xRobotsTag]),
        issue("directives_nofollow", .directives, .notice, "Nofollow",
              "Pages telling search engines not to follow any of their links.",
              fix: "Check each page-level nofollow is intentional.", columns: [.metaRobots, .xRobotsTag]),

        // Hreflang
        issue("hreflang_invalid_code", .hreflang, .error, "Invalid Language or Region Code",
              "Hreflang values that aren't ISO 639-1 language codes with optional ISO 3166-1 alpha-2 regions (e.g. en-UK instead of en-GB).",
              fix: "Correct the codes, e.g. en, en-GB, zh-Hant, x-default.", columns: [.hreflangCount, .lang]),
        issue("hreflang_missing_self_reference", .hreflang, .notice, "Missing Self-Reference",
              "Pages with hreflang annotations that don't include themselves.",
              fix: "Add an hreflang entry pointing to the page itself.", columns: [.hreflangCount]),
        issue("hreflang_missing_x_default", .hreflang, .notice, "Missing x-default",
              "Pages with hreflang annotations but no x-default fallback.",
              fix: "Add an x-default entry for users who don't match any language.", columns: [.hreflangCount]),
        issue("hreflang_missing_return_links", .hreflang, .warning, "Missing Return Links",
              "Pages referencing alternates that don't link back. Google ignores hreflang pairs without return links.",
              fix: "Make hreflang annotations reciprocal across all alternates.", columns: [.hreflangCount], post: true),
        issue("hreflang_non_200_target", .hreflang, .warning, "Non-200 Hreflang URLs",
              "Pages with hreflang entries pointing at URLs that redirect, error or are blocked.",
              fix: "Point hreflang annotations at live 200 URLs.", columns: [.hreflangCount], post: true),

        // JavaScript rendering
        issue("javascript_render_failed", .javaScript, .error, "Rendering Failed",
              "Pages that couldn't be rendered, so only their raw HTML was audited.",
              fix: "Check the page loads in a browser; long-running scripts may need a longer render wait.",
              columns: [.javaScriptRendered]),
        issue("javascript_content_only_rendered", .javaScript, .warning, "Content Only in Rendered HTML",
              "Pages whose visible text mostly appears after JavaScript runs. Search engines render pages too, but rendering is queued and delayed, so important content is safer in the HTML response.",
              fix: "Server-render or pre-render key content instead of building it in the browser.",
              columns: [.wordCount, .rawWordCount]),
        issue("javascript_links_only_rendered", .javaScript, .warning, "Links Only in Rendered HTML",
              "Pages with links that only exist after JavaScript runs, which delays discovery of those URLs.",
              fix: "Use real <a href> links in the HTML response for anything that should be crawled.",
              columns: [.rawLinkCount, .outlinks]),
        issue("javascript_title_changed", .javaScript, .notice, "Title Changed by JavaScript",
              "The rendered title differs from the one in the HTML response.",
              fix: "Check which title you want indexed; set it server-side to avoid ambiguity.", columns: [.title]),
        issue("javascript_meta_description_changed", .javaScript, .notice, "Meta Description Changed by JavaScript",
              "The rendered meta description differs from the HTML response.",
              fix: "Set the description server-side where possible.", columns: [.metaDescription]),
        issue("javascript_canonical_changed", .javaScript, .warning, "Canonical Changed by JavaScript",
              "The rendered canonical differs from the raw HTML. Google uses the rendered canonical, but a mismatch is a common source of indexing mistakes.",
              fix: "Declare one canonical server-side and don't change it in the browser.", columns: [.canonical]),

        // Sitemaps
        issue("sitemap_non_200", .sitemaps, .error, "Non-200 URLs in Sitemap",
              "URLs listed in an XML sitemap that redirect, error or don't respond.",
              fix: "Sitemaps should only list live, canonical 200 URLs.", columns: [.inSitemap], post: true),
        issue("sitemap_non_indexable", .sitemaps, .warning, "Non-Indexable URLs in Sitemap",
              "URLs in a sitemap that are noindexed, canonicalised elsewhere or blocked, which sends mixed signals.",
              fix: "Remove non-indexable URLs from the sitemap.", columns: [.indexabilityReason], post: true),
        issue("sitemap_orphan", .sitemaps, .warning, "Orphan URLs",
              "URLs listed in a sitemap that nothing on the site links to, so they're hard to find and get little authority.",
              fix: "Link to these pages from relevant sections of the site.", columns: [.inlinks], post: true),
        issue("sitemap_missing", .sitemaps, .notice, "Indexable URLs Not in Sitemap",
              "Indexable pages that no sitemap lists.",
              fix: "Add them to a sitemap, or check they should be indexable at all.", columns: [.inSitemap], post: true),

        // Speed — from Lighthouse, run on the most-linked pages after a crawl or on demand. Each check
        // looks at mobile and desktop and flags the page if either is affected.
        issue("lh_low_score", .speed, .warning, "Lighthouse Score Below 50",
              "Pages Lighthouse scores in the red on mobile or desktop. Slow pages lose visitors and rank worse.",
              fix: "Open the page's Lighthouse report and work through the top opportunities, biggest savings first.",
              columns: [.lhMobileScore, .lhDesktopScore], post: true),
        issue("lh_needs_improvement", .speed, .notice, "Lighthouse Score 50–89",
              "Pages in Lighthouse's amber band on mobile or desktop: not slow, but with room to improve.",
              fix: "Work through the report's top opportunities; images and unused JavaScript are the usual wins.",
              columns: [.lhMobileScore, .lhDesktopScore], post: true),
        issue("lh_poor_lcp", .speed, .warning, "Poor Largest Contentful Paint",
              "Pages where the main content takes longer than 4 seconds to appear, Google's “poor” threshold.",
              fix: "Speed up the server response, preload the hero image, serve it in a modern format at the right size, and cut render-blocking CSS and JavaScript.",
              columns: [.lhMobileLCP, .lhDesktopLCP], post: true),
        issue("lh_poor_cls", .speed, .warning, "Poor Cumulative Layout Shift",
              "Pages whose layout moves while loading, above Google's 0.25 “poor” threshold.",
              fix: "Set width and height on images, embeds and ads, reserve space for banners, and avoid inserting content above what's already shown.",
              columns: [.lhMobileCLS, .lhDesktopCLS], post: true),
        issue("lh_high_tbt", .speed, .notice, "High Total Blocking Time",
              "Pages where JavaScript keeps the browser busy for more than 600 ms, so taps and clicks feel slow to respond.",
              fix: "Remove or defer scripts that aren't needed on load, break up long tasks, and audit third-party tags and apps.",
              columns: [.lhMobileTBT, .lhDesktopTBT], post: true),

        // Structured data
        issue("structured_data_parse_error", .structuredData, .error, "JSON-LD Parse Error",
              "Pages with JSON-LD blocks that aren't valid JSON, so search engines ignore them.",
              fix: "Fix the JSON syntax (a common cause is trailing commas) and validate with the Rich Results Test.",
              columns: [.structuredDataCount]),

        // E-commerce — only when the crawl is in e-commerce mode.
        issue("ecom_product_schema_missing", .ecommerce, .warning, "Product Page Without Product Data",
              "Product pages with no Product structured data. Google can't show price, stock or reviews for them in search results, and Merchant Center has nothing to read.",
              fix: "Add Product JSON-LD to the product template. Shopify themes normally output it with {{ product | structured_data }}; a theme that has dropped it, or an app that replaced it, is the usual cause."),
        issue("ecom_product_no_price", .ecommerce, .error, "Product Data Missing a Price",
              "Products whose structured data has no price on one or more variants. Without a price the product isn't eligible for rich results or Merchant Center listings.",
              fix: "Each variant's offer needs a price and priceCurrency. Custom JSON-LD often fills these in for the first variant and drops them for the rest."),
        issue("ecom_product_no_availability", .ecommerce, .warning, "Product Data Missing Availability",
              "Products whose structured data doesn't say whether a variant is in stock. Google shows stock status beside the price and uses it to decide whether to show the product.",
              fix: "Add availability (for example https://schema.org/InStock) to every variant's offer."),
        issue("ecom_product_no_image", .ecommerce, .warning, "Product Data Missing an Image",
              "Products whose structured data has no image. Google requires one for product rich results.",
              fix: "Add the product's image URL to the structured data."),
        issue("ecom_product_no_identifier", .ecommerce, .notice, "Product Data Without GTIN or MPN",
              "Products with no barcode (GTIN, ISBN) or manufacturer part number in their structured data. Google matches products to its catalogue by these, and Merchant Center expects them for branded goods.",
              fix: "Add barcodes in the product admin. Products you make and brand yourself, with no barcode, can be left as they are."),
        issue("ecom_product_duplicate_path", .ecommerce, .warning, "Product Indexable Under a Collection Path",
              "The same product reachable at /collections/x/products/y is indexable there as well as at /products/y, so it competes with itself in search results.",
              fix: "Shopify points the collection path's canonical at /products/y by default. Restore {{ canonical_url }} in the theme's head if it has been removed or overridden.",
              post: true),
        issue("ecom_links_to_duplicate_product", .ecommerce, .notice, "Links to Collection-Path Product URLs",
              "Pages linking to /collections/x/products/y instead of /products/y. Each collection then shows its own address for the product, which spreads links and crawl effort across copies.",
              fix: "Change the theme's product card so it links to the product's own address.",
              columns: [.outlinks], post: true),
        issue("ecom_product_orphan", .ecommerce, .warning, "Product With No Links to It",
              "Products no page links to. They were found through the sitemap, so search engines know them, but shoppers browsing the site can't reach them and they get no link value from it.",
              fix: "Add the product to a collection or link to it from a page. If it isn't meant to be sold, unpublish it so it leaves the sitemap.",
              columns: [.inlinks], post: true),
        issue("ecom_product_no_collection", .ecommerce, .notice, "Product Not in Any Collection",
              "Products linked from other pages but not from any collection. Collections are where shoppers and search engines expect to find a product, and they carry the internal links that rank it.",
              fix: "Add the product to the collection it belongs in.",
              columns: [.inlinks], post: true),
    ]
}
