import Audit
import CrawlCore
import Foundation
import Parsing
import Rendering
import Storage

/// A link found while processing a URL, already resolved and normalised.
struct DiscoveredLink: Sendable {
    var url: URL
    var string: String
    var type: LinkType
    var flags: LinkFlags
    /// Anchor/alt text; the language code for hreflang links.
    var text: String
}

struct ProcessOutcome: Sendable {
    var result: CrawledURL
    var issues: [String] = []
    var links: [DiscoveredLink] = []
    var canonicalURL: String?
    var structuredData: [StructuredDataRecord] = []
    var html: Data?
    var renderedHTML: Data?
    var screenshot: Data?
    /// Set when the server asked us to back off (429/503); the URL should be retried.
    var retryAfterSeconds: Double?
}

/// Fetches, parses and audits one URL. Runs concurrently on many URLs; holds no mutable state.
struct PageProcessor: Sendable {
    let config: CrawlConfig
    let scope: CrawlScope
    let fetcher: Fetcher
    let robots: RobotsCache
    let limiter: RateLimiter
    let siteIsHTTPS: Bool
    let renderer: PageRenderer?

    init(config: CrawlConfig, scope: CrawlScope, password: String? = nil) {
        self.config = config
        self.scope = scope
        let authentication = Fetcher.Authentication(
            username: config.basicAuthUsername,
            password: password ?? "",
            headers: config.customHeaders,
            cookieHeader: config.cookieHeader,
            // Credentials only ever go to hosts in scope, never to external sites.
            appliesTo: { url in scope.isInternal(url) }
        )
        fetcher = Fetcher(userAgent: config.userAgent, timeout: config.timeoutSeconds,
                          maxConnectionsPerHost: config.concurrency, authentication: authentication)
        renderer = config.renderJavaScript ? PageRenderer(options: PageRenderer.Options(
            userAgent: config.userAgent,
            concurrency: config.renderConcurrency,
            settleSeconds: config.renderSettleSeconds,
            timeoutSeconds: config.timeoutSeconds,
            captureScreenshots: config.storeScreenshots,
            blockHeavyResources: config.renderBlockHeavyResources
        )) : nil
        robots = RobotsCache(fetcher: fetcher, productToken: config.robotsUserAgentToken)
        limiter = RateLimiter(maxPerSecond: config.maxURLsPerSecond)
        siteIsHTTPS = scope.startURL?.scheme == "https"
    }

    func process(_ item: DiscoveredURL, attempt: Int) async -> ProcessOutcome {
        var discovery = item
        discovery.state = .crawled
        var outcome = ProcessOutcome(result: CrawledURL(discovery: discovery))
        guard let url = URL(string: item.url) else {
            outcome.result.error = "Invalid URL"
            return outcome
        }
        var facts = PageFacts(url: url, isInternal: item.isInternal, siteIsHTTPS: siteIsHTTPS, depth: item.depth, resourceType: item.resourceType)

        if config.respectRobotsTxt, !(await robots.verdict(for: url).allowed) {
            outcome.result.blockedByRobots = true
            if config.skipRobotsBlocked {
                // Listed under Not Crawled with its reason, and out of every report and count.
                outcome.result.discovery.state = .skipped
                outcome.result.discovery.skipReason = "Blocked by robots.txt"
                return outcome
            }
            facts.blockedByRobots = true
            finish(&outcome, facts: facts)
            return outcome
        }

        await limiter.acquire(host: item.host)

        let policy: Fetcher.BodyPolicy = switch (item.isInternal, item.resourceType) {
        case (true, .page): .htmlOnly(maxBytes: config.maxHTMLBytes)
        case (true, .image): .sizeIfUnknown(maxBytes: 20 * 1024 * 1024)
        default: .never
        }

        let response: FetchResponse
        switch await fetcher.fetch(url, body: policy) {
        case .failure(let failure):
            outcome.result.error = failure.label
            facts.failed = true
            finish(&outcome, facts: facts)
            return outcome
        case .success(let value):
            response = value
        }

        if response.statusCode == 429 || response.statusCode == 503, attempt < 2 {
            let seconds = Self.retryAfter(response.headers["retry-after"]) ?? 10
            await limiter.pause(host: item.host, seconds: seconds)
            outcome.retryAfterSeconds = seconds
            return outcome
        }

        var result = outcome.result
        result.statusCode = response.statusCode
        result.statusText = response.statusText
        result.contentType = response.mimeType
        result.sizeBytes = response.sizeBytes
        result.responseMs = response.totalMs
        result.ttfbMs = response.ttfbMs
        result.headers = response.headers
        result.xRobotsTag = response.headers["x-robots-tag"]
        if (200...299).contains(response.statusCode), let type = ResourceType.from(contentType: response.mimeType) {
            result.discovery.resourceType = type
        }
        outcome.result = result

        facts.statusCode = response.statusCode
        facts.headers = response.headers
        facts.sizeBytes = response.sizeBytes
        facts.responseMs = response.totalMs
        facts.resourceType = outcome.result.discovery.resourceType
        facts.directives = RobotsDirectives(metaRobots: [], xRobotsTag: result.xRobotsTag, productToken: config.robotsUserAgentToken)

        if item.isInternal, let location = response.redirectLocation,
           let normalized = URLNormalizer.normalize(location.absoluteString, stripParameters: config.stripQueryParameters) {
            outcome.result.redirectURL = normalized.absoluteString
            outcome.links.append(DiscoveredLink(url: normalized, string: normalized.absoluteString, type: .redirect, flags: [], text: ""))
        } else if let location = response.redirectLocation {
            outcome.result.redirectURL = location.absoluteString
        }

        if item.isInternal, facts.resourceType == .page, (200...299).contains(response.statusCode), let body = response.body {
            await processHTML(body, charset: response.charset, url: url, outcome: &outcome, facts: &facts)
        }

        finish(&outcome, facts: facts)
        return outcome
    }

    private func processHTML(_ body: Data, charset: String?, url: URL, outcome: inout ProcessOutcome, facts: inout PageFacts) async {
        let tokens = ["googlebot", config.robotsUserAgentToken]
        // Extractors and searches configured for the raw HTML run here; the rest run on the
        // rendered DOM below when rendering is on.
        let rendering = config.renderJavaScript && renderer != nil
        let rawExtractors = rendering ? config.extractors.filter { !$0.useRenderedHTML } : config.extractors
        let rawSearches = rendering ? config.customSearches.filter { !$0.useRenderedHTML } : config.customSearches
        let rawPage = HTMLParser.parse(body, headerCharset: charset, robotsTokens: tokens,
                                       extractors: rawExtractors, searches: rawSearches)
        var page = rawPage
        var renderMs: Double?

        // With rendering on, the page is audited as the browser sees it and the raw HTML is kept
        // for comparison, which is what surfaces content that only exists after JavaScript runs.
        if let renderer {
            let render = await renderer.render(url)
            renderMs = render.renderMs
            if let html = render.html {
                page = HTMLParser.parse(Data(html.utf8), headerCharset: "utf-8", robotsTokens: tokens,
                                        extractors: config.extractors.filter(\.useRenderedHTML),
                                        searches: config.customSearches.filter(\.useRenderedHTML))
                // Keep results that were configured to run against the raw HTML.
                page.extractions.merge(rawPage.extractions) { rendered, _ in rendered }
                page.searchHits.merge(rawPage.searchHits) { rendered, _ in rendered }
                facts.rawPage = rawPage
                if config.storeHTML { outcome.renderedHTML = Data(html.utf8) }
                outcome.screenshot = render.screenshot
            } else {
                facts.renderFailure = render.error ?? "Rendering failed"
            }
        }
        facts.page = page
        facts.ecommerce = config.ecommerceActive
        facts.product = config.ecommerceActive ? page.product : nil
        outcome.result.product = facts.product
        facts.directives = RobotsDirectives(metaRobots: page.metaRobots, xRobotsTag: outcome.result.xRobotsTag, productToken: config.robotsUserAgentToken)

        let base = page.baseHref.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } ?? url
        func resolve(_ href: String) -> URL? {
            URLNormalizer.normalize(href, relativeTo: base, stripParameters: config.stripQueryParameters)
        }

        var seen = Set<String>()
        var internalOutlinks = 0
        var externalOutlinks = 0
        for link in page.links {
            guard let target = resolve(link.href) else { continue }
            let string = target.absoluteString
            var flags = link.flags

            if link.type == .anchor {
                if scope.isInternal(target) {
                    internalOutlinks += 1
                    if flags.contains(.nofollow) { facts.nofollowInternalOutlinks += 1 }
                    if PageAuditor.genericAnchors.contains(link.text.lowercased()) { facts.nonDescriptiveInternalAnchors += 1 }
                } else {
                    externalOutlinks += 1
                }
                // A page-level nofollow directive applies to every link on the page.
                if facts.directives.nofollow { flags.insert(.nofollow) }
            }
            if url.scheme == "https", target.scheme == "http", [.image, .script, .stylesheet, .iframe].contains(link.type) {
                facts.mixedContentResources += 1
            }
            guard seen.insert("\(link.type.rawValue)|\(string)|\(link.text)").inserted else { continue }
            outcome.links.append(DiscoveredLink(url: target, string: string, type: link.type, flags: flags, text: link.text))
        }
        facts.internalOutlinks = internalOutlinks

        facts.resolvedCanonicals = page.canonicals.compactMap { resolve($0.href)?.absoluteString }
        if let first = page.canonicals.first, let canonical = resolve(first.href) {
            outcome.canonicalURL = canonical.absoluteString
            outcome.links.append(DiscoveredLink(url: canonical, string: canonical.absoluteString, type: .canonical, flags: [], text: ""))
        }

        for entry in page.hreflang {
            guard let target = resolve(entry.href) else { continue }
            facts.resolvedHreflang.append((entry.lang, target.absoluteString))
            outcome.links.append(DiscoveredLink(url: target, string: target.absoluteString, type: .hreflang, flags: [], text: entry.lang))
        }

        outcome.structuredData = page.jsonLD.map { StructuredDataRecord(types: $0.types, error: $0.error) }
        if config.storeHTML { outcome.html = body }

        var record = PageRecord()
        record.title = page.titles.first
        record.titleLength = page.titles.first?.count ?? 0
        record.titlePixels = PixelWidth.title(page.titles.first ?? "")
        record.titleCount = page.titles.count
        record.metaDescription = page.metaDescriptions.first
        record.metaDescriptionLength = page.metaDescriptions.first?.count ?? 0
        record.metaDescriptionPixels = PixelWidth.description(page.metaDescriptions.first ?? "")
        record.metaDescriptionCount = page.metaDescriptions.count
        record.h1 = page.h1.first
        record.h1Length = page.h1.first?.count ?? 0
        record.h1Count = page.h1.count
        record.h1Second = page.h1.count > 1 ? page.h1[1] : nil
        record.h2 = page.h2.first
        record.h2Count = page.h2.count
        record.canonical = outcome.canonicalURL
        record.canonicalCount = page.canonicals.count
        record.metaRobots = page.metaRobots.isEmpty ? nil : page.metaRobots.joined(separator: "; ")
        record.lang = page.lang
        record.wordCount = page.wordCount
        record.contentHash = page.contentHash
        record.simhash = page.simhash
        record.extractions = page.extractions
        record.searchHits = page.searchHits.filter(\.value).map(\.key)
        record.outlinks = internalOutlinks
        record.externalOutlinks = externalOutlinks
        record.hreflangCount = page.hreflang.count
        record.structuredDataCount = page.jsonLD.count
        record.javaScriptRendered = facts.rawPage != nil
        record.renderMs = renderMs
        if facts.rawPage != nil {
            record.rawWordCount = rawPage.wordCount
            record.rawLinkCount = rawPage.links.count { $0.type == .anchor }
            record.renderedLinkCount = page.links.count { $0.type == .anchor }
        }
        outcome.result.page = record
    }

    private func finish(_ outcome: inout ProcessOutcome, facts: PageFacts) {
        let (indexability, reason) = PageAuditor.indexability(facts)
        outcome.result.indexability = indexability
        outcome.result.indexabilityReason = reason
        outcome.issues = PageAuditor.audit(facts)
    }

    /// `Retry-After` is either delay-seconds or an HTTP date.
    static func retryAfter(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
