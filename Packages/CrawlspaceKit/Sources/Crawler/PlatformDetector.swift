import CrawlCore
import Foundation

/// Works out which platform a site runs on, so the crawl can start with the right defaults.
public enum PlatformDetector {
    /// The settings a crawl should actually run with: the chosen profile applied, or for
    /// `.automatic`, whichever profile the start page turns out to need. A site that can't be
    /// reached is crawled as configured; the crawl itself will say why it can't reach it.
    public static func tailor(_ config: CrawlConfig, session: URLSession = .shared) async -> CrawlConfig {
        var config = config

        // Looked up once, and only if something is waiting on the answer.
        var shopify: Bool?
        func isStore() async -> Bool {
            if let shopify { return shopify }
            let answer = await isShopify(config.startURL, userAgent: config.userAgent, session: session)
            shopify = answer
            return answer
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
        guard let url = URL(string: address) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        let headers = Dictionary(http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key.lowercased(), "\(value)")
        }, uniquingKeysWith: { first, _ in first })
        let body = String(decoding: data.prefix(200_000), as: UTF8.self)
        return ShopifyProfile.recognises(headers: headers, body: body)
    }
}
