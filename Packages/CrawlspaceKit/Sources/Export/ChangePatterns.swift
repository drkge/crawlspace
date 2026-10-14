import CrawlCore
import Foundation

/// Broken and redirecting addresses that changed for the same reason, found so each reason is one
/// fix rather than one per address.
///
/// A store that has been reorganised over time leaves trails: fifteen removed products all sent to
/// the home page, "®" taken out of five handles, "-1" dropped from five more, a blog moved from
/// /blog to /blogs/blog, a theme snippet writing a Liquid error into its links. Each address is
/// right on its own, but the fix is the reason: update the links that still use the old shape, or
/// mend the one line of the theme.
///
/// Only clear, repeated evidence makes a pattern — three addresses or more sharing the reason, and
/// a theme error even once, since that's always one line to mend. Anything else keeps its own fix.
public enum ChangePatterns {
    public enum Kind: Sendable, Hashable {
        /// Redirects that all land on the same address — removed pages sent to the home page.
        case destination(String)
        /// Addresses that redirect to themselves with something taken out: "®", "-1".
        case removed(String)
        /// Addresses that redirect to themselves with something added.
        case inserted(String)
        /// Addresses that moved from one part of the site to another: /blog/… to /blogs/blog/….
        case moved(from: String, to: String)
        /// Links that use a product's number, /products/8529003577650, where its handle belongs.
        case productNumbers
        /// A theme error written into links: "Liquid error (snippets/size-guide-snippet line 253)".
        case liquid(String)
        /// Products removed but still linked inside collections.
        case removedFromCollections
    }

    struct Address {
        var id: Int64
        /// The path and query, as the site writes them, percent-encoding and all.
        var path: String
        var status: Int?
        /// Where it redirects to, as a path on the same site; nil if it doesn't, or goes elsewhere.
        var redirect: String?
        var isBroken: Bool { status.map { $0 >= 400 } ?? (redirect == nil) }
    }

    struct Pattern {
        var kind: Kind
        var members: [Int64]
    }

    /// How many addresses have to share a reason before it counts as one.
    static let minimum = 3

    static func find(_ addresses: [Address]) -> [Pattern] {
        var left = addresses
        var patterns: [Pattern] = []
        func take(_ groups: [Kind: [Address]], minimum: Int) {
            for (kind, members) in groups where members.count >= minimum {
                patterns.append(Pattern(kind: kind, members: members.map(\.id).sorted()))
                let ids = Set(members.map(\.id))
                left.removeAll { ids.contains($0.id) }
            }
        }

        // A theme error in the address, broken or redirected: always the theme's to mend.
        take(Dictionary(grouping: left.compactMap { address in liquid(in: address.path).map { (address, Kind.liquid($0)) } },
                        by: \.1).mapValues { $0.map(\.0) }, minimum: 1)

        // Redirects that all go to the same place.
        let redirects = left.filter { $0.redirect != nil }
        take(Dictionary(grouping: redirects, by: { Kind.destination($0.redirect!.lowercased()) }), minimum: minimum)

        // Redirects that rewrite the address the same way.
        let rewritten = left.compactMap { address in address.redirect.flatMap { rewrite(from: address.path, to: $0) }.map { (address, $0) } }
        take(Dictionary(grouping: rewritten, by: \.1).mapValues { $0.map(\.0) }, minimum: minimum)

        // Broken addresses of one shape.
        let broken = left.filter(\.isBroken)
        take([.productNumbers: broken.filter { $0.path.wholeMatch(of: /(?:\/[a-z]{2}(?:-[a-z]{2,4})?)?\/products\/[0-9]+\/?/) != nil }],
             minimum: minimum)
        take([.removedFromCollections: broken.filter { EcommercePaths.product(path: $0.path)?.collectionScoped == true }],
             minimum: minimum)
        return patterns
    }

    /// The part of the theme a Liquid error names, if the address carries one.
    static func liquid(in path: String) -> String? {
        let text = (path.removingPercentEncoding ?? path).replacingOccurrences(of: "+", with: " ")
        guard text.range(of: "liquid error", options: .caseInsensitive) != nil else { return nil }
        let file = text.firstMatch(of: /(snippets|sections|templates|layout)\/[A-Za-z0-9_.-]+/).map { String($0.0) }
        let line = text.firstMatch(of: /line ([0-9]+)/).map { "line \($0.1)" }
        let place = [file, line].compactMap { $0 }.joined(separator: " ")
        return place.isEmpty ? "the theme" : place
    }

    /// How an address was rewritten into where it redirects, when it's a change worth naming:
    /// something taken out, something added, or one part of the path swapped for another.
    static func rewrite(from source: String, to target: String) -> Kind? {
        let a = Array(source.lowercased()), b = Array(target.lowercased())
        guard a != b else { return nil }
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let removed = String(a[prefix..<(a.count - suffix)])
        let added = String(b[prefix..<(b.count - suffix)])
        func general(_ text: String) -> String {
            text.wholeMatch(of: /-?[0-9]+/) != nil ? text.replacing(/[0-9]+/, with: "#") : text
        }
        // Within a segment it's a rename; across a "/" it's a move, said as one.
        let crossesSegments = removed.contains("/") || added.contains("/")
        if added.isEmpty, !removed.isEmpty, !crossesSegments { return .removed(general(removed)) }
        if removed.isEmpty, !added.isEmpty, !crossesSegments { return .inserted(general(added)) }
        // A part of the path swapped for another, the rest kept: only at a boundary, and only when
        // what's kept is more than a character or two.
        let kept = String(a[(a.count - suffix)...])
        guard kept.hasPrefix("/"), kept.count > 2 else { return nil }
        return .moved(from: String(a[..<(a.count - suffix)]), to: String(b[..<(b.count - suffix)]))
    }

    // MARK: - Words

    static func shown(_ text: String) -> String {
        let plain = text.removingPercentEncoding ?? text
        // A number generalised to "#" reads better as an example of one.
        return plain.replacingOccurrences(of: "#", with: "1")
    }

    /// The fix's name: the reason, without counts, so the next crawl finds it again.
    static func name(of kind: Kind) -> String {
        switch kind {
        case .destination(let path): path == "/" ? "Removed pages sent to the home page" : "Redirects that all go to \(shown(path))"
        case .removed(let text): "“\(shown(text))” removed from addresses"
        case .inserted(let text): "“\(shown(text))” added to addresses"
        case .moved(let from, let to): "\(shown(from)) moved to \(shown(to))"
        case .productNumbers: "Product links by number"
        case .liquid(let place): "Liquid error in \(place)"
        case .removedFromCollections: "Removed products still in collections"
        }
    }

    /// What happened, and the one fix for it.
    static func explanation(of kind: Kind) -> (what: String, fix: String) {
        switch kind {
        case .destination(let path) where path == "/":
            ("These addresses no longer exist, and the site sends every one of them to the home page — usually products or pages that were removed.",
             "Update or remove the links to them, listed here. Where a page has a real replacement, redirect it there instead of the home page: visitors and search engines both read a redirect to the home page as \"gone\".")
        case .destination(let path):
            ("These addresses all redirect to \(shown(path)).",
             "Change the links to point at \(shown(path)) directly, or, if they should each have their own page, redirect each to its closest replacement.")
        case .removed(let text):
            ("These pages were renamed with “\(shown(text))” taken out of their addresses, and the old addresses redirect to the new ones.",
             "Update the links that still use the old addresses — usually menus, collection or product descriptions, and blog posts — so they point at the new ones directly.")
        case .inserted(let text):
            ("These pages were renamed with “\(shown(text))” added to their addresses, and the old addresses redirect to the new ones.",
             "Update the links that still use the old addresses so they point at the new ones directly.")
        case .moved(let from, let to):
            ("These pages moved from \(shown(from)) to \(shown(to)), and the old addresses redirect.",
             "Update the links that still use \(shown(from)) to use \(shown(to)), wherever they're written — menus, templates, posts.")
        case .productNumbers:
            ("Links point at /products/ followed by the product's number, which isn't an address Shopify answers.",
             "Something builds these links from the product's ID rather than its handle — a theme snippet, an app, or links pasted from the admin. Make it use the product's URL (product.url), and the links work again.")
        case .liquid(let place):
            ("The theme writes a Liquid error into these links, so they lead nowhere.",
             "Mend \(place) in the theme: the error is that line failing, and every link it writes goes with it.")
        case .removedFromCollections:
            ("Products that were deleted or unpublished are still linked from inside collections.",
             "Remove them from the collections they're still listed in, or put them back. If the collection is built by rules, check the conditions still match only live products.")
        }
    }
}
