import Foundation

/// What a page's Product structured data says, boiled down to what an e-commerce audit asks of it.
///
/// A Shopify product with options is a `ProductGroup` whose variants each carry their own offer,
/// so the counts are per variant: "3 of 12 variants have no price" is the useful finding, not
/// "the product has no price".
public struct ProductData: Sendable, Hashable, Codable {
    public var name: String?
    public var brand: String?
    /// Variants described (1 for a plain product).
    public var variants = 1
    /// Separate Product blocks on the page. A theme plus a reviews or SEO app often each add one,
    /// and Google checks every block on its own: a bare one is an error even beside a complete one.
    public var entities = 1
    public var entitiesNoPrice = 0
    public var entitiesNoAvailability = 0
    public var withPrice = 0
    public var withAvailability = 0
    /// A GTIN (any length), ISBN or MPN.
    public var withIdentifier = 0
    public var withSKU = 0
    public var lowPrice: Double?
    public var highPrice: Double?
    public var currency: String?
    /// Distinct availabilities offered, e.g. "InStock", "OutOfStock".
    public var availabilities: [String] = []
    public var images = 0
    public var reviewCount: Int?
    public var rating: Double?

    public init() {}

    public var hasPrice: Bool { withPrice > 0 }

    /// Folds several products on one page into one, summing what's counted per variant.
    public static func merged(_ items: [ProductData]) -> ProductData? {
        guard var result = items.first else { return nil }
        for other in items.dropFirst() {
            result.entities += other.entities
            result.entitiesNoPrice += other.entitiesNoPrice
            result.entitiesNoAvailability += other.entitiesNoAvailability
            result.variants += other.variants
            result.withPrice += other.withPrice
            result.withAvailability += other.withAvailability
            result.withIdentifier += other.withIdentifier
            result.withSKU += other.withSKU
            result.images = max(result.images, other.images)
            result.lowPrice = [result.lowPrice, other.lowPrice].compactMap { $0 }.min()
            result.highPrice = [result.highPrice, other.highPrice].compactMap { $0 }.max()
            result.currency = result.currency ?? other.currency
            result.brand = result.brand ?? other.brand
            result.availabilities = Array(Set(result.availabilities + other.availabilities)).sorted()
            result.reviewCount = result.reviewCount ?? other.reviewCount
            result.rating = result.rating ?? other.rating
        }
        return result
    }
}

/// Where products live in a store's URLs. Shopify's paths, including the market prefixes
/// (`/en-gb/`) it puts in front of everything on multi-region stores.
public enum EcommercePaths {
    private static let productPattern = try! NSRegularExpression(
        pattern: #"^(?:/[a-z]{2}(?:-[a-z]{2,4})?)?(/collections/[^/?#]+)?/products/([^/?#]+)"#,
        options: [.caseInsensitive]
    )
    private static let collectionPattern = try! NSRegularExpression(
        pattern: #"^(?:/[a-z]{2}(?:-[a-z]{2,4})?)?/collections/([^/?#]+)/?$"#,
        options: [.caseInsensitive]
    )

    public struct Product: Sendable, Hashable {
        public var handle: String
        /// True for `/collections/x/products/y`, the same product under a collection's path.
        public var collectionScoped: Bool
        /// The canonical path Shopify means: `/products/y`.
        public var cleanPath: String { "/products/\(handle)" }

        public init(handle: String, collectionScoped: Bool) {
            self.handle = handle
            self.collectionScoped = collectionScoped
        }
    }

    public static func product(in url: URL) -> Product? {
        product(path: url.path())
    }

    public static func product(path: String) -> Product? {
        let range = NSRange(path.startIndex..., in: path)
        guard let match = productPattern.firstMatch(in: path, range: range),
              let handleRange = Range(match.range(at: 2), in: path) else { return nil }
        return Product(handle: String(path[handleRange]).lowercased(), collectionScoped: match.range(at: 1).location != NSNotFound)
    }

    /// A collection's own page (`/collections/candles`, `/collections/candles?page=2`), not a product in one.
    public static func isCollection(_ url: URL) -> Bool {
        let path = url.path()
        return collectionPattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
