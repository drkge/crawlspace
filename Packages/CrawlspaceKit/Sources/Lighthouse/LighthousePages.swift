import CrawlCore
import Foundation
import Storage

/// Which pages to measure.
///
/// Usually the most-linked pages. On a Shopify store, one page of each theme template instead:
/// every product page is built from the product template, every collection from the collection
/// template, so their speed problems are the same problem, and measuring the most important page
/// of each covers the store in about ten pages rather than twenty-five near-identical products.
public enum LighthousePages {
    public static func isShopify(_ config: CrawlConfig) -> Bool {
        config.appliedProfile == "Shopify" || config.platformProfile == .shopify
    }

    public static func usesShopifyTemplates(_ config: CrawlConfig) -> Bool {
        config.lighthouseShopifyTemplates && isShopify(config)
    }

    /// What a crawl's speed check will measure, in words.
    public static func describe(_ config: CrawlConfig) -> String {
        usesShopifyTemplates(config)
            ? "one page of each Shopify template"
            : "the \(config.lighthouseTopPages) most-linked pages"
    }

    /// The pages for a speed check. `top` overrides the crawl's own number of most-linked pages;
    /// Shopify templates ignore it.
    public static func choose(store: CrawlStore, config: CrawlConfig, top: Int? = nil) throws -> [LighthouseBatch.Page] {
        if usesShopifyTemplates(config) {
            return try ShopifyTemplates.pages(store: store, config: config)
        }
        return try store.lighthouseCandidates(limit: top ?? config.lighthouseTopPages).map { .init(id: $0.id, url: $0.url) }
    }
}

/// The pages that stand for a Shopify store's templates.
enum ShopifyTemplates {
    enum Template: String, CaseIterable {
        case home = "Home"
        case collection = "Collection"
        case allProducts = "All products"
        case product = "Product"
        case cart = "Cart"
        case search = "Search"
        case blog = "Blog"
        case article = "Article"
        case page = "Page"

        /// How many of each to measure.
        var count: Int { self == .product ? 3 : 1 }
    }

    static func pages(store: CrawlStore, config: CrawlConfig) throws -> [LighthouseBatch.Page] {
        var chosen: [Template: [LighthouseBatch.Page]] = [:]
        for page in try store.measurablePages() {
            guard let template = template(of: page.url, depth: page.depth),
                  chosen[template, default: []].count < template.count else { continue }
            chosen[template, default: []].append(.init(id: page.id, url: page.url, template: template.rawValue))
        }

        // Cart and search are kept out of crawls by Shopify's robots.txt, so they're added by address.
        if let origin = origin(of: config.startURL), let host = URL(string: origin)?.host() {
            let cart = origin + "/cart"
            chosen[.cart] = [.init(id: try store.lighthouseRowID(forURL: cart, host: host), url: cart, template: Template.cart.rawValue)]
            let term = searchTerm(productNames: try store.productNames(),
                                  productURLs: chosen[.product, default: []].map(\.url))
            let search = origin + "/search?q=" + (term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term)
            chosen[.search] = [.init(id: try store.lighthouseRowID(forURL: search, host: host), url: search, template: Template.search.rawValue)]
        }
        return Template.allCases.flatMap { chosen[$0] ?? [] }
    }

    /// The template a store address is built from, allowing for a market prefix such as /en-gb.
    static func template(of address: String, depth: Int) -> Template? {
        guard let url = URL(string: address) else { return nil }
        var segments = url.path().split(separator: "/").map(String.init)
        if let first = segments.first, first.wholeMatch(of: /[a-z]{2}(-[a-z]{2,4})?/) != nil,
           segments.count == 1 || ["collections", "products", "blogs", "pages"].contains(segments[1]) {
            segments.removeFirst()
        }
        if url.query() != nil { return nil }
        switch (segments.first, segments.count) {
        case (nil, _): return .home
        case ("collections", 2): return segments[1] == "all" ? .allProducts : .collection
        case ("products", 2): return .product
        case ("blogs", 2): return .blog
        case ("blogs", 3): return segments[2] == "tagged" ? nil : .article
        case ("pages", 2): return .page
        default: return nil
        }
    }

    /// A word that's in plenty of the store's product names, so the search returns real results.
    static func searchTerm(productNames: [String], productURLs: [String]) -> String {
        let ignored: Set<String> = ["with", "from", "your", "this", "that", "pack", "size", "set", "and", "for", "the"]
        var words: [String] = []
        if productNames.isEmpty {
            for address in productURLs {
                guard let handle = URL(string: address)?.lastPathComponent else { continue }
                words += handle.split(separator: "-").map(String.init)
            }
        } else {
            for name in productNames {
                words += name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            }
        }
        var counts: [String: Int] = [:]
        for word in words where word.count >= 4 && !ignored.contains(word) {
            counts[word, default: 0] += 1
        }
        // The commonest word; ties go to the alphabetically first, so the choice is stable.
        let best = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first
        return best?.key ?? "a"
    }

    private static func origin(of startURL: String) -> String? {
        guard let url = URL(string: startURL), let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
}
