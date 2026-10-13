import CrawlCore
import Foundation

/// Works out where a site answers and which platform it runs on, so the crawl can start in the
/// right place with the right defaults.
public enum PlatformDetector {
    /// The settings a crawl should actually run with: started where the site answers, and with the
    /// chosen profile applied, or for `.automatic`, whichever profile the start page turns out to
    /// need. A site that can't be reached is crawled as configured; the crawl itself will say why
    /// it can't reach it.
    public static func tailor(_ config: CrawlConfig, session: URLSession = .shared) async -> CrawlConfig {
        var config = config

        // The start page, fetched once, answers both questions.
        var fetched: StartPage??
        func startPage() async -> StartPage? {
            if let fetched { return fetched }
            let page = await fetch(config.startURL, userAgent: config.userAgent, session: session)
            fetched = .some(page)
            return page
        }

        // A site that answers somewhere else — at www.example.com when asked for example.com, or
        // over https when asked over http — is crawled where it answers. Otherwise every page of
        // it is on another host from the start, and is taken for another site's: checked that it
        // answers, never read.
        if config.mode != .list, let page = await startPage(), let moved = siteStart(config.startURL, answeredAt: page.url) {
            config.startURL = moved
        }

        func isStore() async -> Bool {
            guard let page = await startPage() else { return false }
            return ShopifyProfile.recognises(headers: page.headers, body: page.body)
        }

        switch config.platformProfile {
        case .none: break
        case .shopify: ShopifyProfile.apply(to: &config)
        case .automatic: if await isStore() { ShopifyProfile.apply(to: &config) }
        }

        // Assigned outright each time, so a rescan of a site that has since moved platforms
        // doesn't carry the old answer along.
        switch config.ecommerceMode {
        case .on: config.ecommerceActive = true
        case .off: config.ecommerceActive = false
        case .automatic: config.ecommerceActive = config.platformProfile == .shopify ? true : await isStore()
        }
        return config
    }

    public static func isShopify(_ address: String, userAgent: String = "Crawlspace/1.0",
                                 session: URLSession = .shared) async -> Bool {
        guard let page = await fetch(address, userAgent: userAgent, session: session) else { return false }
        return ShopifyProfile.recognises(headers: page.headers, body: page.body)
    }

    /// The start page as it answered, after any redirects.
    struct StartPage {
        var url: URL?
        var headers: [String: String]
        var body: String
    }

    static func fetch(_ address: String, userAgent: String, session: URLSession) async -> StartPage? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let headers = Dictionary(http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key.lowercased(), "\(value)")
        }, uniquingKeysWith: { first, _ in first })
        return StartPage(url: http.url, headers: headers, body: String(decoding: data.prefix(200_000), as: UTF8.self))
    }

    /// The start address on the host and scheme the site answered at, when that's the same site
    /// somewhere else — www added or taken away, http to https — keeping the path asked for, so the
    /// crawl stays in its folder. Nil when it answered where it was asked, or on another site
    /// altogether, which is a move worth crawling as it is.
    public static func siteStart(_ configured: String, answeredAt final: URL?) -> String? {
        guard let final, var parts = URLComponents(string: configured), let host = parts.host?.lowercased(),
              let finalHost = final.host()?.lowercased(), let scheme = final.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        func bare(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        guard bare(host) == bare(finalHost), host != finalHost || parts.scheme?.lowercased() != scheme else { return nil }
        parts.scheme = scheme
        parts.host = finalHost
        parts.port = final.port
        return parts.string
    }
}
