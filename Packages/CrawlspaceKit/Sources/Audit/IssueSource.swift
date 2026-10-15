/// Where a check comes from: the published guidance that says it matters — Google's or Bing's,
/// a web standard, Lighthouse — or, for a rule of thumb, why it's only that.
///
/// Most checks rest on something a search engine or standard publishes, but some are habits of
/// the trade that no search engine states (titles over 60 characters, images over 100 KB, one H1
/// a page). They're kept, because they're good advice, and labelled, so they can be weighed as
/// advice rather than read as rules.
public struct IssueSource: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case google, bing, webStandard, lighthouse, ruleOfThumb
    }

    public let kind: Kind
    /// The document, "Google Search Central: Influencing your title links in search results"; for
    /// a rule of thumb, why it's one.
    public let title: String
    public let url: String?
}

extension IssueSource {
    static func google(_ title: String, _ path: String) -> IssueSource {
        IssueSource(kind: .google, title: "Google Search Central: \(title)", url: "https://developers.google.com/search/docs/\(path)")
    }

    static func lighthouse(_ title: String, _ url: String) -> IssueSource {
        IssueSource(kind: .lighthouse, title: title, url: url)
    }

    static func standard(_ title: String, _ url: String) -> IssueSource {
        IssueSource(kind: .webStandard, title: title, url: url)
    }

    static func ruleOfThumb(_ why: String) -> IssueSource {
        IssueSource(kind: .ruleOfThumb, title: why, url: nil)
    }

    // MARK: Google Search Central

    static let statusCodes = google("How HTTP status codes affect Google's crawlers", "crawling-indexing/http-network-errors")
    static let robotsTxt = google("Introduction to robots.txt", "crawling-indexing/robots/intro")
    static let redirects = google("Redirects and Google Search", "crawling-indexing/301-redirects")
    static let links = google("Link best practices for Google", "crawling-indexing/links-crawlable")
    static let outboundLinks = google("Qualify your outbound links to Google", "crawling-indexing/qualify-outbound-links")
    static let urlStructure = google("URL structure best practices for Google Search", "crawling-indexing/url-structure")
    static let pageExperience = google("Understanding page experience in Google Search results", "appearance/page-experience")
    static let titleLinks = google("Influencing your title links in search results", "appearance/title-link")
    static let snippets = google("Control your snippets in search results", "appearance/snippet")
    static let images = google("Google image SEO best practices", "appearance/google-images")
    static let canonical = google("How to specify a canonical URL", "crawling-indexing/consolidate-duplicate-urls")
    static let canonicalization = google("What is canonicalization", "crawling-indexing/canonicalization")
    static let robotsMeta = google("Robots meta tag, data-nosnippet, and X-Robots-Tag specifications", "crawling-indexing/robots-meta-tag")
    static let hreflang = google("Tell Google about localized versions of your page", "specialty/international/localized-versions")
    static let javaScript = google("Understand the JavaScript SEO basics", "crawling-indexing/javascript/javascript-seo-basics")
    static let sitemaps = google("Build and submit a sitemap", "crawling-indexing/sitemaps/build-sitemap")
    static let structuredData = google("General structured data guidelines", "appearance/structured-data/sd-policies")
    static let productData = google("Introduction to Product structured data", "appearance/structured-data/product")
    static let merchantListing = google("Merchant listing (Product, Offer) structured data", "appearance/structured-data/merchant-listing")
    static let ecommerceStructure = google("Help Google understand your ecommerce website structure",
                                           "specialty/ecommerce/help-google-understand-your-ecommerce-site-structure")
    static let coreWebVitals = google("Understanding Core Web Vitals and Google search results", "appearance/core-web-vitals")

    // MARK: Bing

    /// One page covers it all: titles and descriptions, headings, alt text, anchor text, sitemaps,
    /// duplicates, rendering, robots.txt and noindex.
    static let bing = IssueSource(kind: .bing, title: "Bing Webmaster Guidelines",
                                  url: "https://www.bing.com/webmasters/help/webmaster-guidelines-30fba23a")

    // MARK: Lighthouse

    static let lighthouseScoring = lighthouse("Lighthouse performance scoring",
                                              "https://developer.chrome.com/docs/lighthouse/performance/performance-scoring")
    static let largestContentfulPaint = lighthouse("Largest Contentful Paint (LCP)", "https://web.dev/articles/lcp")
    static let cumulativeLayoutShift = lighthouse("Cumulative Layout Shift (CLS)", "https://web.dev/articles/cls")
    static let totalBlockingTime = lighthouse("Total Blocking Time",
                                              "https://developer.chrome.com/docs/lighthouse/performance/lighthouse-total-blocking-time")
    static let lighthouseRedirects = lighthouse("Lighthouse: Avoid multiple page redirects",
                                                "https://developer.chrome.com/docs/lighthouse/performance/redirects")
    static let unsizedImages = lighthouse("Optimize Cumulative Layout Shift: images without dimensions",
                                          "https://web.dev/articles/optimize-cls#images-without-dimensions")
    static let linkText = lighthouse("Lighthouse: Links do not have descriptive text", "https://developer.chrome.com/docs/lighthouse/seo/link-text")
    static let metaDescriptionAudit = lighthouse("Lighthouse: Document does not have a meta description",
                                                 "https://developer.chrome.com/docs/lighthouse/seo/meta-description")
    static let hreflangAudit = lighthouse("Lighthouse: Document doesn't have a valid hreflang",
                                          "https://developer.chrome.com/docs/lighthouse/seo/hreflang")
    static let canonicalAudit = lighthouse("Lighthouse: Document does not have a valid rel=canonical",
                                           "https://developer.chrome.com/docs/lighthouse/seo/canonical")
    static let indexingAudit = lighthouse("Lighthouse: Page is blocked from indexing", "https://developer.chrome.com/docs/lighthouse/seo/is-crawlable")
    static let httpsAudit = lighthouse("Lighthouse: Does not use HTTPS", "https://developer.chrome.com/docs/lighthouse/best-practices/is-on-https")
    static let cspAudit = lighthouse("Lighthouse: Ensure CSP is effective against XSS attacks",
                                     "https://developer.chrome.com/docs/lighthouse/best-practices/csp-xss")
    static let hstsAudit = lighthouse("Lighthouse: Use a strong HSTS policy", "https://developer.chrome.com/docs/lighthouse/best-practices/has-hsts")

    // MARK: Web standards

    static let htmlTitle = standard("HTML Standard: the title element", "https://html.spec.whatwg.org/multipage/semantics.html#the-title-element")
    static let htmlMetaDescription = standard("HTML Standard: the description metadata name",
                                              "https://html.spec.whatwg.org/multipage/semantics.html#meta-description")
    static let htmlAlt = standard("HTML Standard: requirements for providing text to act as an alternative for images",
                                  "https://html.spec.whatwg.org/multipage/images.html#alt")
    static let wcagNonText = standard("WCAG 2.2: Understanding SC 1.1.1 Non-text Content",
                                      "https://www.w3.org/WAI/WCAG22/Understanding/non-text-content.html")
    static let mixedContent = standard("W3C: Mixed Content", "https://www.w3.org/TR/mixed-content/")
    static let csp = standard("W3C: Content Security Policy Level 3", "https://www.w3.org/TR/CSP3/")
    static let hsts = standard("IETF RFC 6797: HTTP Strict Transport Security (HSTS)", "https://www.rfc-editor.org/rfc/rfc6797")
    static let nosniff = standard("WHATWG Fetch Standard: X-Content-Type-Options",
                                  "https://fetch.spec.whatwg.org/#x-content-type-options-header")
}
