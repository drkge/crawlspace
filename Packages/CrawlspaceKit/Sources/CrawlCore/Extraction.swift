import Foundation

/// A user-defined field pulled out of every crawled page — a price, a schema value, a tracking tag.
public struct Extractor: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case cssSelector
        case xpath
        case regex

        public var label: String {
            switch self {
            case .cssSelector: "CSS selector"
            case .xpath: "XPath"
            case .regex: "Regex"
            }
        }
    }

    /// What to take from each match. Regex extractors always return text (capture group 1 if present).
    public enum Output: String, Codable, Sendable, CaseIterable {
        case text
        case innerHTML
        case outerHTML
        case attribute

        public var label: String {
            switch self {
            case .text: "Text"
            case .innerHTML: "Inner HTML"
            case .outerHTML: "Outer HTML"
            case .attribute: "Attribute"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var expression: String
    public var output: Output
    /// Attribute name when `output` is `.attribute`.
    public var attribute: String
    /// Join every match rather than keeping only the first.
    public var collectAll: Bool
    /// Run against the rendered DOM instead of the raw HTML (only differs when rendering is on).
    public var useRenderedHTML: Bool

    public init(id: UUID = UUID(), name: String = "", kind: Kind = .cssSelector, expression: String = "",
                output: Output = .text, attribute: String = "", collectAll: Bool = false,
                useRenderedHTML: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.expression = expression
        self.output = output
        self.attribute = attribute
        self.collectAll = collectAll
        self.useRenderedHTML = useRenderedHTML
    }

    public var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !expression.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == .regex, (try? NSRegularExpression(pattern: expression)) == nil { return false }
        if output == .attribute, attribute.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }
}

/// "Which pages mention X?" — a whole-page search recorded per URL.
public struct CustomSearch: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case contains
        case doesNotContain
        case matchesRegex
        case doesNotMatchRegex

        public var label: String {
            switch self {
            case .contains: "Contains"
            case .doesNotContain: "Does not contain"
            case .matchesRegex: "Matches regex"
            case .doesNotMatchRegex: "Doesn't match regex"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var mode: Mode
    public var term: String
    public var caseSensitive: Bool
    /// Search the visible text rather than the HTML source.
    public var visibleTextOnly: Bool
    public var useRenderedHTML: Bool

    public init(id: UUID = UUID(), name: String = "", mode: Mode = .contains, term: String = "",
                caseSensitive: Bool = false, visibleTextOnly: Bool = false, useRenderedHTML: Bool = true) {
        self.id = id
        self.name = name
        self.mode = mode
        self.term = term
        self.caseSensitive = caseSensitive
        self.visibleTextOnly = visibleTextOnly
        self.useRenderedHTML = useRenderedHTML
    }

    public var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !term.isEmpty else { return false }
        if mode == .matchesRegex || mode == .doesNotMatchRegex, (try? NSRegularExpression(pattern: term)) == nil {
            return false
        }
        return true
    }
}

/// A 64-bit fingerprint of a page's text. Two pages are near-duplicates when their fingerprints
/// differ in only a few bits, which finds "same page, small changes" that exact hashing misses.
public enum SimHash {
    /// Hashes overlapping three-word shingles, then keeps the majority bit in each position.
    public static func compute(words: [String]) -> UInt64 {
        guard words.count >= 3 else {
            return words.isEmpty ? 0 : StableHash.fnv1a64(words.joined(separator: " "))
        }
        var columns = [Int](repeating: 0, count: 64)
        for index in 0...(words.count - 3) {
            let shingle = words[index] + " " + words[index + 1] + " " + words[index + 2]
            let hash = StableHash.fnv1a64(shingle)
            for bit in 0..<64 {
                columns[bit] += (hash >> UInt64(bit)) & 1 == 1 ? 1 : -1
            }
        }
        var result: UInt64 = 0
        for bit in 0..<64 where columns[bit] > 0 {
            result |= 1 << UInt64(bit)
        }
        return result
    }

    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 0–1, where 1 is identical.
    public static func similarity(_ a: UInt64, _ b: UInt64) -> Double {
        1 - Double(hammingDistance(a, b)) / 64
    }

    /// The four 16-bit bands used to bucket candidates: near-duplicates share at least one band,
    /// so only pages in the same bucket need comparing.
    public static func bands(_ hash: UInt64) -> [UInt64] {
        (0..<4).map { (hash >> UInt64($0 * 16)) & 0xFFFF }
    }
}
