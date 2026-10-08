import CrawlCore
import Foundation

/// Reads Product and ProductGroup structured data out of a parsed JSON-LD document.
enum ProductExtractor {
    /// Walks arrays and `@graph`, and stops at a Product: a collection's item list would otherwise
    /// make every product it shows look like this page's own.
    static func products(in object: Any) -> [ProductData] {
        if let array = object as? [Any] { return array.flatMap(products(in:)) }
        guard let node = object as? [String: Any] else { return [] }
        var found: [ProductData] = []
        if let graph = node["@graph"] { found += products(in: graph) }

        let types = typeNames(node)
        if types.contains("ProductGroup") {
            found.append(group(node))
        } else if types.contains("Product") {
            found.append(single(node))
        }
        return found
    }

    // MARK: - Shapes

    private static func group(_ node: [String: Any]) -> ProductData {
        let variantNodes = (node["hasVariant"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        // A group that lists no variants is described by its own offers.
        var result = variantNodes.isEmpty ? single(node) : ProductData.merged(variantNodes.map(single)) ?? single(node)
        result.name = string(node["name"]) ?? result.name
        result.brand = brand(node) ?? result.brand
        result.images = max(result.images, imageCount(node["image"]))
        if let rating = aggregateRating(node) { (result.reviewCount, result.rating) = rating }
        // The variants were folded into one, but a group is a single block on the page.
        result.entities = 1
        result.entitiesNoPrice = result.withPrice == 0 ? 1 : 0
        result.entitiesNoAvailability = result.withAvailability == 0 ? 1 : 0
        return result
    }

    private static func single(_ node: [String: Any]) -> ProductData {
        var data = ProductData()
        data.name = string(node["name"])
        data.brand = brand(node)
        data.images = imageCount(node["image"])
        if string(node["sku"]) != nil { data.withSKU = 1 }
        let identifiers = ["gtin", "gtin8", "gtin12", "gtin13", "gtin14", "isbn", "mpn"]
        if identifiers.contains(where: { string(node[$0]) != nil }) { data.withIdentifier = 1 }
        if let rating = aggregateRating(node) { (data.reviewCount, data.rating) = rating }

        var prices: [Double] = []
        var availabilities: Set<String> = []
        for offer in offers(node["offers"]) {
            for key in ["price", "lowPrice", "highPrice"] {
                if let price = number(offer[key]) { prices.append(price) }
            }
            if data.currency == nil { data.currency = string(offer["priceCurrency"]) }
            if let availability = string(offer["availability"]) {
                availabilities.insert(availability.split(separator: "/").last.map(String.init) ?? availability)
            }
        }
        if !prices.isEmpty {
            data.withPrice = 1
            data.lowPrice = prices.min()
            data.highPrice = prices.max()
        }
        if !availabilities.isEmpty {
            data.withAvailability = 1
            data.availabilities = availabilities.sorted()
        }
        data.entitiesNoPrice = data.withPrice == 0 ? 1 : 0
        data.entitiesNoAvailability = data.withAvailability == 0 ? 1 : 0
        return data
    }

    // MARK: - Values

    /// `offers` is one offer, a list, or an AggregateOffer that holds a list of its own.
    private static func offers(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [Any] { return array.flatMap(offers) }
        guard let offer = value as? [String: Any] else { return [] }
        return [offer] + offers(offer["offers"])
    }

    private static func typeNames(_ node: [String: Any]) -> Set<String> {
        let raw = node["@type"]
        let names = (raw as? [Any])?.compactMap { $0 as? String } ?? (raw as? String).map { [$0] } ?? []
        // "https://schema.org/Product" and "schema:Product" both mean Product.
        return Set(names.map { $0.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? $0 })
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    /// Prices arrive as "9.99", 9.99 or "£9.99"; anything that isn't a plain amount is no price.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        guard let text = string(value) else { return nil }
        let amount = text.filter { $0.isNumber || $0 == "." }
        return Double(amount)
    }

    private static func brand(_ node: [String: Any]) -> String? {
        if let name = string(node["brand"]) { return name }
        return string((node["brand"] as? [String: Any])?["name"])
    }

    private static func imageCount(_ value: Any?) -> Int {
        switch value {
        case let array as [Any]: return array.reduce(0) { $0 + imageCount($1) }
        case let text as String: return text.isEmpty ? 0 : 1
        case let object as [String: Any]: return string(object["url"] ?? object["contentUrl"]) == nil ? 0 : 1
        default: return 0
        }
    }

    private static func aggregateRating(_ node: [String: Any]) -> (Int?, Double?)? {
        guard let rating = node["aggregateRating"] as? [String: Any] else { return nil }
        let count = number(rating["reviewCount"] ?? rating["ratingCount"]).map(Int.init)
        return (count, number(rating["ratingValue"]))
    }
}
