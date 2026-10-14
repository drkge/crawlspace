import Audit
import CrawlCore
import Foundation
import GRDB
import Storage

/// The lists a crawl's issues are filed into. Links, images, site settings and duplicates each get
/// a list of their own, because one fix there usually clears many pages. What's left is filed page
/// by page: on a Shopify store into a list per kind of page (products, collections, pages, blog
/// posts and the rest), elsewhere into a list per severity, with speed and products beside them.
public enum FixGroup: String, CaseIterable, Codable, Sendable {
    case links, images, siteSettings, duplicates, speed, products, collections, storePages, blog, otherPages
    case errors, warnings, notices

    /// The lists a crawl files into: by kind of page on a Shopify store, by severity elsewhere.
    public static func groups(shopify: Bool) -> [FixGroup] {
        shopify ? [.links, .images, .siteSettings, .duplicates, .products, .collections, .storePages, .blog, .otherPages]
                : [.links, .images, .siteSettings, .duplicates, .speed, .products, .errors, .warnings, .notices]
    }

    /// The list a Shopify page goes into, by the template it's built from.
    public static func list(for template: ShopifyProfile.Template?) -> FixGroup {
        switch template {
        case .product: .products
        case .collection, .allProducts: .collections
        case .page: .storePages
        case .blog, .article: .blog
        default: .otherPages
        }
    }

    /// The list of pages for a severity.
    public static func pages(_ severity: IssueSeverity) -> FixGroup {
        switch severity {
        case .error: .errors
        case .warning: .warnings
        case .notice: .notices
        }
    }

    /// Set for the three lists of pages.
    public var pageSeverity: IssueSeverity? {
        switch self {
        case .errors: .error
        case .warnings: .warning
        case .notices: .notice
        default: nil
        }
    }

    public static func group(for definition: IssueDefinition) -> FixGroup {
        let code = definition.code
        if FixBuilder.targetCodes[code] != nil || FixBuilder.linkSourceCodes.contains(code)
            || FixBuilder.linkAttributeCodes.contains(code) || code == FixBuilder.productCardCode { return .links }
        if definition.category == .images { return .images }
        if definition.category == .security || definition.category == .sitemaps
            || FixBuilder.settingCodes.contains(code) { return .siteSettings }
        if FixBuilder.clusterColumns[code] != nil { return .duplicates }
        if definition.category == .speed { return .speed }
        if definition.category == .ecommerce { return .products }
        return pages(definition.severity)
    }
}

/// One thing to fix: a broken URL and every link to it, an image and every
/// page showing it, a server setting, a group of pages sharing a title, or a page and its issues.
public struct Fix: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A URL that is broken, redirects or couldn't be checked, and the links pointing at it.
        case target(Int64)
        /// An image, and the pages showing it.
        case image(Int64)
        /// One link in the theme, carried by many pages.
        case link(code: String, target: Int64, text: String)
        /// One issue that is one setting for the whole site.
        case setting(String)
        /// Pages sharing a title, description, H1 or their content.
        case cluster(code: String, value: String?)
        /// A Lighthouse template, standing for every page built from it.
        case template(String)
        /// A page and its own issues.
        case page(Int64)
        /// Product cards linking through a collection's address: one snippet in the theme, however
        /// many products and pages it reaches.
        case productCards
        /// Broken or redirecting addresses that changed for the same reason; `members` holds them.
        case pattern(ChangePatterns.Kind)
    }

    public var group: FixGroup
    public var kind: Kind
    /// Its name, which is also how the next crawl finds it again.
    public var name: String
    /// The worst of its issues.
    public var severity: IssueSeverity
    /// Issue codes, worst first.
    public var codes: [String]
    /// The pages it lists, most linked-to first.
    public var pages: [Int64]
    /// Pages per issue code, where that differs from `pages`.
    public var counts: [String: Int] = [:]
    /// Each issue as a issue: a Shopify page's issues, or a template's.
    public var issues: [FixIssue] = []
    /// Everything it stands for, where that's more than one URL: every size of an image file.
    public var members: [Int64] = []
    /// True when it has issues only at severities left out: kept as it is, if there is
    /// one, is left as it is rather than closed.
    public var heldOpen = false
    /// The fixes it takes over, as "group|name" keys: its addresses filed one by one, or a page's
    /// links filed apart from the page. The worklist carries their status over rather than taking
    /// them as fixed.
    public var aliases: [String] = []

    /// What its count is of: issues on a page, otherwise pages.
    public var countsIssues: Bool {
        switch kind {
        case .page, .template: true
        default: false
        }
    }

    var count: Int { countsIssues ? codes.count : pages.count }

    var noun: String {
        countsIssues ? (count == 1 ? "issue" : "issues") : (count == 1 ? "page" : "pages")
    }
}

/// One issue under a fix: on a page, or on most pages built from a template.
public struct FixIssue: Sendable, Hashable {
    public var name: String
    public var code: String
    public var severity: IssueSeverity
    /// The pages it's on, most linked-to first.
    public var pages: [Int64]
    /// The other half of a pair measured two ways, filed with it as one: a title over 60 characters
    /// and over 561 pixels is one title to shorten.
    public var also: [String] = []
    /// The fixes it takes over, as "group|name" keys, like a fix's.
    public var aliases: [String] = []
}

/// Works out the fixes a crawl's issues come to, and writes each one's description.
public enum FixBuilder {
    /// Issues on a URL that links lead to, and the issue on the pages that link to it. Both are one
    /// fix, so both go in the URL's fix.
    static let targetCodes: [String: String?] = [
        "response_internal_4xx": "links_to_broken_internal",
        "response_internal_5xx": "links_to_broken_internal",
        "response_internal_no_response": "links_to_broken_internal",
        "response_external_broken": "links_to_broken_external",
        "response_external_unverified": "links_to_unverified_external",
        "response_internal_3xx": "links_to_redirect_internal",
        "redirect_chain": nil,
        "redirect_loop": nil,
    ]
    static let linkSourceCodes = Set(targetCodes.values.compactMap { $0 })
    static let brokenCodes: Set = ["response_internal_4xx", "response_internal_5xx", "response_internal_no_response",
                                   "response_external_broken"]

    /// Pages linking to products at a collection's address, which is the product card's doing.
    static let productCardCode = "ecom_links_to_duplicate_product"
    /// Issues on a URL that are only its redirect, which a collection's product address has when
    /// the store sends it on to the product's own.
    static let redirectCodes: Set = ["response_internal_3xx", "redirect_chain"]

    /// /collections/x/products/y on the crawled site: where a product card sends people when it
    /// builds its link inside the collection.
    static func isCollectionProduct(_ address: String, site: String) -> Bool {
        guard let url = URL(string: address), url.host() == site else { return false }
        return EcommercePaths.product(in: url)?.collectionScoped == true
    }

    /// Issues with a link itself, rather than where it leads.
    static let linkAttributeCodes: Set = ["links_internal_nofollow", "links_non_descriptive_anchor"]

    /// Issues with a link itself, and the links on a flagged page that carry them.
    static var linkAttributeConditions: [String: String] {
        let generic = PageAuditor.genericAnchors.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        return [
            "links_internal_nofollow": "t.is_internal = 1 AND l.type = 0 AND (l.flags & 1) = 1",
            "links_non_descriptive_anchor": "t.is_internal = 1 AND l.type = 0 AND lower(trim(l.text)) IN (\(generic))",
        ]
    }

    /// Issues with an image on a page, and the images on a flagged page that carry them.
    static let imageConditions: [String: String] = [
        "images_missing_alt_attribute": "(l.flags & \(LinkFlags.altAttributeMissing.rawValue)) != 0",
        "images_missing_alt_text": "(l.flags & \(LinkFlags.altAttributeMissing.rawValue)) = 0 AND l.text = ''",
        "images_missing_dimensions": "(l.flags & \(LinkFlags.dimensionsMissing.rawValue)) != 0",
        "images_alt_over_100_characters": "length(l.text) > 100",
    ]

    /// Issues that are one setting for the whole site, beyond the security and sitemap ones.
    static let settingCodes: Set = ["url_http_on_https_site", "response_internal_blocked_robots"]

    /// Duplicate issues, and the column pages share. Near duplicates are grouped by similarity.
    static let clusterColumns: [String: String] = [
        "title_duplicate": "title", "meta_description_duplicate": "meta_description", "h1_duplicate": "h1",
        "content_exact_duplicate": "content_hash", "content_near_duplicate": "",
    ]

    /// What a group of pages has in common, as "they …" finishes it.
    static func likeness(_ code: String, value: String?) -> String {
        switch code {
        case "title_duplicate": "share the title “\(value ?? "")”"
        case "meta_description_duplicate": "share the meta description “\(value ?? "")”"
        case "h1_duplicate": "share the H1 “\(value ?? "")”"
        case "content_exact_duplicate": "have exactly the same content"
        default: "have very similar content"
        }
    }

    /// The title, description or H1 a group of pages shares, read from one of them; nil for content.
    static func clusterValue(_ code: String, page: Int64?, store: CrawlStore) throws -> String? {
        guard let page, let column = clusterColumns[code], !column.isEmpty, column != "content_hash" else { return nil }
        return try store.pool.read { db in
            try String.fetchOne(db, sql: "SELECT CAST(\(column) AS TEXT) FROM urls WHERE id = ?", arguments: [page])
        }
    }

    /// Which of a group of pages' likenesses leads, and names the fix: the content before the title,
    /// description and H1 that come of it.
    static func clusterOrder(of fix: Fix) -> Int {
        ["content_exact_duplicate", "content_near_duplicate", "title_duplicate", "meta_description_duplicate", "h1_duplicate"]
            .firstIndex(of: fix.codes.first ?? "") ?? 9
    }

    /// Issues the theme makes rather than a page's own content: on most pages of a template, they
    /// are the template's to fix, once.
    static let templateCodes: Set = [
        "h1_missing", "h1_multiple", "h2_missing", "title_multiple", "meta_description_multiple",
        "canonical_missing", "canonical_canonicalised", "canonical_multiple_conflicting", "canonical_relative",
        "canonical_outside_head", "canonical_target_non_200", "canonical_target_non_indexable",
        "structured_data_parse_error", "ecom_product_schema_missing", "ecom_product_no_price",
        "ecom_product_no_availability", "ecom_product_no_image",
        "hreflang_invalid_code", "hreflang_missing_self_reference", "hreflang_missing_x_default",
        "hreflang_missing_return_links", "hreflang_non_200_target", "directives_noindex", "directives_nofollow",
        "javascript_render_failed", "javascript_content_only_rendered", "javascript_links_only_rendered",
        "javascript_title_changed", "javascript_meta_description_changed", "javascript_canonical_changed",
        "links_no_internal_outlinks",
    ]
    /// Issues that are one problem measured two ways, or set by one tag: on the same page, one
    /// issue and one fix. The first of each is the worse, and names the problem.
    static let measuredPairs: [(primary: String, other: String, name: String)] = [
        ("title_over_561_pixels", "title_over_60_characters", "Page Titles: Too Long"),
        ("meta_description_over_985_pixels", "meta_description_over_155_characters", "Meta Description: Too Long"),
        ("directives_noindex", "directives_nofollow", "Directives: Noindex and Nofollow"),
    ]

    /// The pair a code belongs to, if any.
    static func pair(of code: String) -> (primary: String, other: String, name: String)? {
        measuredPairs.first { $0.primary == code || $0.other == code }
    }

    /// Issues for issues, a pair measured two ways as one where both are there.
    static func issues(for codes: [String], pages: (String) -> [Int64], severity: (String) -> IssueSeverity) -> [FixIssue] {
        var result: [FixIssue] = []
        var done: Set<String> = []
        for code in codes where !done.contains(code) {
            if let pair = pair(of: code), codes.contains(pair.primary), codes.contains(pair.other) {
                done.formUnion([pair.primary, pair.other])
                let first = pages(pair.primary)
                let together = first + pages(pair.other).filter { !first.contains($0) }
                result.append(FixIssue(name: pair.name, code: pair.primary, severity: min(severity(pair.primary), severity(pair.other)),
                                             pages: together, also: [pair.other]))
            } else {
                done.insert(code)
                result.append(FixIssue(name: title(code), code: code, severity: severity(code), pages: pages(code)))
            }
        }
        return result
    }

    /// The share of a template's pages an issue has to be on to count as the template's.
    static let templateShare = 0.8

    /// An image's file, whatever size or version it's asked for at: its address without the query,
    /// when the address names an image file (logo.png?width=600, logo.png?ver=3). An address that
    /// doesn't, such as image.php?id=12, keeps its query, since that's what says which image it is.
    ///
    /// A Shopify store's file is the same file at cdn.shopify.com/s/files/1/<shop>/… and at the
    /// store's own /cdn/shop/…, so both are taken as the store's.
    static func imageFile(_ address: String, origin: String = "", sizes: Bool = true) -> String {
        var file = address
        let parts = address.split(separator: "?", maxSplits: 1)
        if parts.count == 2, let path = URL(string: String(parts[0]))?.pathExtension.lowercased(), imageExtensions.contains(path) {
            file = String(parts[0])
        }
        file = shopifyFile(file).map { origin + $0 } ?? file
        // Shopify serves a file resized at logo_480x480.png, logo_large.png and the like.
        if sizes, file.contains("/cdn/shop/") || file.contains("cdn.shopify.com/") {
            file = file.replacing(shopifySize, with: "")
        }
        return file
    }

    /// The size Shopify's older image addresses put before the extension: _480x480, _x200,
    /// _1024x1024@2x, _large, _480x480_crop_center.
    nonisolated(unsafe) static let shopifySize =
        /_(?:\d+x\d*|x\d+|pico|icon|thumb|small|compact|medium|large|grande|original|master)(?:_crop_(?:top|center|bottom|left|right))?(?:@\dx)?(?=\.[A-Za-z0-9]+$)/

    /// The store's own path for a file on Shopify's CDN: /cdn/shop/files/logo.png for
    /// https://cdn.shopify.com/s/files/1/0750/7322/5010/files/logo.png; nil for any other address.
    static func shopifyFile(_ address: String) -> String? {
        address.wholeMatch(of: /https?:\/\/cdn\.shopify\.com\/s\/files\/1\/(?:[0-9]{4}\/){2,3}(.+)/).map { "/cdn/shop/\($0.1)" }
    }

    static let imageExtensions: Set = ["jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "bmp", "tif", "tiff", "ico", "heic"]

    /// Lighthouse templates that stand for many pages; home, cart and search are one page each.
    static let sharedTemplates: Set = ["Product", "Collection", "Article", "Blog", "Page"]

    // MARK: - Units

    public static func units(store: CrawlStore, severities: Set<IssueSeverity>,
                             groups chosen: Set<FixGroup> = Set(FixGroup.allCases)) throws -> [Fix] {
        let config = try store.loadConfig()
        let shopify = ShopifyProfile.isStore(config)
        let groups = chosen.intersection(FixGroup.groups(shopify: shopify))
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let origin = URL(string: config.startURL).flatMap { url in url.scheme.map { "\($0)://\(url.host() ?? "")" } } ?? ""

        return try store.pool.read { db in
            var byCode: [String: [Int64]] = [:]
            let cursor = try Row.fetchCursor(db, sql: "SELECT code, url_id FROM issues")
            while let row = try cursor.next() { byCode[row[0], default: []].append(row[1]) }

            // A copy of a page with only tracking added isn't a fix: its issues are its page's, filed
            // with the page, as long as the page was crawled too. Nor is Shopify's sign-in.
            var leftOut: Set<Int64> = []
            for row in try Row.fetchAll(db, sql: """
                SELECT id, url FROM urls WHERE is_internal = 1 AND (url LIKE '%?%' OR url LIKE '%/customer_authentication/%')
                """) {
                let (id, address): (Int64, String) = (row[0], row[1])
                if isShopifySignIn(address) {
                    leftOut.insert(id)
                } else if isTrackingCopy(address), let clean = withoutTracking(address),
                          try Bool.fetchOne(db, sql: "SELECT 1 FROM urls WHERE url = ? AND status_code IS NOT NULL",
                                            arguments: [clean]) == true {
                    leftOut.insert(id)
                }
            }
            if !leftOut.isEmpty {
                byCode = byCode.mapValues { $0.filter { !leftOut.contains($0) } }.filter { !$0.value.isEmpty }
            }

            var urls = URLLookup()
            try urls.load(Set(byCode.values.joined()), db: db)

            func lookup(_ code: String) -> IssueDefinition? { IssueCatalogue.definition(for: code) }
            func wanted(_ code: String, in group: FixGroup) -> Bool {
                guard let definition = lookup(code), groups.contains(group),
                      FixGroup.group(for: definition) == group else { return false }
                if severities.contains(definition.severity) { return true }
                // A broken URL counts at the severity of the links to it, too.
                if let paired = targetCodes[code] ?? nil, let pairedDefinition = lookup(paired) {
                    return severities.contains(pairedDefinition.severity)
                }
                return false
            }
            func worst(_ codes: [String]) -> IssueSeverity {
                codes.compactMap { lookup($0)?.severity }.min() ?? .notice
            }
            func sorted(_ codes: some Sequence<String>) -> [String] {
                Array(Set(codes)).sorted {
                    let (a, b) = (lookup($0)?.severity ?? .notice, lookup($1)?.severity ?? .notice)
                    return a != b ? a < b : $0 < $1
                }
            }
            func byInlinks(_ ids: some Sequence<Int64>) throws -> [Int64] {
                let unique = Set(ids).subtracting(leftOut)
                try urls.load(unique, db: db)
                return unique.sorted {
                    let (a, b) = (urls[$0], urls[$1])
                    return a.inlinks != b.inlinks ? a.inlinks > b.inlinks : a.url < b.url
                }
            }
            func shown(_ id: Int64) -> String { IssueEvidenceBuilder.shorten(urls[id].url, site: origin) }
            func pageName(_ id: Int64) -> String { FixBuilder.pageName(for: urls[id].url, site: site) }

            var units: [Fix] = []
            var claimed: Set<String> = []

            // Links: one fix per URL that links lead somewhere wrong.
            var targets: [Int64: [String]] = [:]
            for (code, ids) in byCode where targetCodes[code] != nil && wanted(code, in: .links) {
                claimed.insert(code)
                for id in ids { targets[id, default: []].append(code) }
            }
            // A collection's product addresses that redirect to the product's own are the product
            // card's doing, as are pages flagged for linking to them: one fix for the lot.
            var cardTargets: [Int64] = []
            var cardCodes: Set<String> = []
            for (id, codes) in targets where codes.allSatisfy(redirectCodes.contains) && isCollectionProduct(urls[id].url, site: site) {
                cardTargets.append(id)
                cardCodes.formUnion(codes)
                targets[id] = nil
            }
            let flagged = wanted(productCardCode, in: .links) ? byCode[productCardCode] ?? [] : []
            claimed.insert(productCardCode)
            // On a Shopify store, collection copies that answer with the product's page are the
            // card's doing too: they're filed with it, not page by page.
            var copies: Set<Int64> = []
            var servedCopies: [Int64] = []
            if shopify {
                for row in try Row.fetchAll(db, sql: """
                    SELECT id, url, status_code FROM urls WHERE is_internal = 1 AND url LIKE '%/collections/%/products/%'
                    """) {
                    let (id, address, status): (Int64, String, Int?) = (row[0], row[1], row[2])
                    guard isCollectionProduct(address, site: site) else { continue }
                    copies.insert(id)
                    if status == 200 { servedCopies.append(id) }
                }
            }
            if !cardTargets.isEmpty || !flagged.isEmpty {
                let addresses = cardTargets + servedCopies
                var linkers = Set(flagged)
                for chunk in addresses.chunked(900) {
                    linkers.formUnion(try Int64.fetchAll(db, sql: """
                        SELECT DISTINCT source_id FROM links WHERE type = \(LinkType.anchor.rawValue)
                          AND target_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                        """, arguments: StatementArguments(chunk)))
                }
                var codes = cardCodes
                if !cardTargets.isEmpty, byCode["links_to_redirect_internal"] != nil { codes.insert("links_to_redirect_internal") }
                if !flagged.isEmpty { codes.insert(productCardCode) }
                units.append(Fix(group: .links, kind: .productCards, name: "Product cards: links through collection addresses",
                                         severity: worst(Array(codes)), codes: sorted(codes), pages: try byInlinks(linkers),
                                         counts: ["addresses": cardTargets.count, "copies": servedCopies.count]))
            }
            // Addresses on the site that broke or moved for the same reason: one fix for the reason.
            var addresses: [ChangePatterns.Address] = []
            for chunk in Array(targets.keys).chunked(900) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, url, status_code, redirect_url, is_internal FROM urls
                    WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    let (id, address, status, redirect, isInternal): (Int64, String, Int?, String?, Bool) = (row[0], row[1], row[2], row[3], row[4])
                    guard isInternal, let url = URL(string: address), url.host() == site else { continue }
                    let path = url.path() + (url.query().map { "?\($0)" } ?? "")
                    let destination = redirect.flatMap(URL.init(string:)).flatMap { target -> String? in
                        guard target.host() == nil || target.host() == site else { return nil }
                        return target.path() + (target.query().map { "?\($0)" } ?? "")
                    }
                    addresses.append(ChangePatterns.Address(id: id, path: path, status: status, redirect: destination))
                }
            }
            for pattern in ChangePatterns.find(addresses) {
                var codes: Set<String> = []
                for member in pattern.members {
                    codes.formUnion(targets[member] ?? [])
                    targets[member] = nil
                }
                for code in codes { if let paired = targetCodes[code] ?? nil, byCode[paired] != nil { codes.insert(paired) } }
                var linkers: Set<Int64> = []
                for chunk in pattern.members.chunked(900) {
                    linkers.formUnion(try Int64.fetchAll(db, sql: """
                        SELECT DISTINCT source_id FROM links WHERE target_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                        """, arguments: StatementArguments(chunk)))
                }
                try urls.load(Set(pattern.members), db: db)
                units.append(Fix(group: .links, kind: .pattern(pattern.kind), name: ChangePatterns.name(of: pattern.kind),
                                         severity: worst(Array(codes)), codes: sorted(codes), pages: try byInlinks(linkers),
                                         counts: ["addresses": pattern.members.count],
                                         members: pattern.members.sorted { urls[$0].url < urls[$1].url }))
            }
            // Addresses that differ only by tracking — a link shared with ?sh=1, and with ?sh=2 — are
            // one link to fix.
            var byAddress: [String: [(id: Int64, codes: [String], prefix: String)]] = [:]
            for (id, codes) in targets {
                let prefix = codes.contains(where: brokenCodes.contains) ? "Broken link"
                    : codes.contains("response_external_unverified") ? "Unverified link" : "Redirect"
                let address = urls[id].url
                byAddress["\(prefix) \(withoutTracking(address) ?? address)", default: []].append((id, codes, prefix))
            }
            for same in byAddress.values {
                let ordered = same.sorted { urls[$0.id].url < urls[$1.id].url }
                // Named by the address without tracking, if it's one of them.
                let first = ordered.first { withoutTracking(urls[$0.id].url) == nil } ?? ordered[0]
                var linkers: Set<Int64> = []
                var all: Set<String> = []
                for member in ordered {
                    linkers.formUnion(try Int64.fetchAll(db, sql: "SELECT DISTINCT source_id FROM links WHERE target_id = ?",
                                                         arguments: [member.id]))
                    all.formUnion(member.codes)
                    for code in member.codes { if let paired = targetCodes[code] ?? nil, byCode[paired] != nil { all.insert(paired) } }
                }
                units.append(Fix(group: .links, kind: .target(first.id), name: "\(first.prefix): \(shown(first.id))",
                                 severity: worst(Array(all)), codes: sorted(Array(all)), pages: try byInlinks(linkers),
                                 members: ordered.count > 1 ? ordered.map(\.id) : [],
                                 aliases: ordered.filter { $0.id != first.id }.map { "links|\($0.prefix): \(shown($0.id))" }))
            }
            for code in linkSourceCodes { claimed.insert(code) }

            // Links that are wrong in themselves: one fix per link in the theme, and one per page
            // for the rest.
            var pageLinks: [Int64: [String]] = [:]
            for (code, condition) in linkAttributeConditions where wanted(code, in: .links) {
                claimed.insert(code)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT l.source_id, l.target_id, l.text, l.flags FROM links l JOIN urls t ON t.id = l.target_id
                    WHERE \(condition) AND l.source_id IN (SELECT url_id FROM issues WHERE code = ?)
                    """, arguments: [code])
                var groups: [LinkKey: [(source: Int64, position: LinkPosition)]] = [:]
                for row in rows {
                    let key = LinkKey(target: row[1], text: row[2])
                    groups[key, default: []].append((row[0], LinkFlags(rawValue: row[3]).position))
                }
                for (key, occurrences) in groups {
                    let sources = Set(occurrences.map(\.source))
                    if isTheme(pages: sources.count, positions: occurrences.map(\.position)) {
                        try urls.load([key.target], db: db)
                        let text = key.text.isEmpty ? "" : "“\(truncated(key.text, 60))” → "
                        let label = code == "links_internal_nofollow" ? "Nofollow link" : "Link text"
                        units.append(Fix(group: .links, kind: .link(code: code, target: key.target, text: key.text),
                                                 name: "\(label): \(text)\(shown(key.target))", severity: worst([code]),
                                                 codes: [code], pages: try byInlinks(sources)))
                    } else {
                        for source in sources where !leftOut.contains(source) { pageLinks[source, default: []].append(code) }
                    }
                }
            }
            // The rest are the page's to fix, with its other issues: see the page lists below.
            try urls.load(Set(pageLinks.keys), db: db)

            // Images: one fix per image file, with every page showing it. A CDN serves one file at
            // many sizes and versions, and its alt text and weight are set once.
            var images: [Int64: (codes: Set<String>, pages: Set<Int64>, counts: [String: Set<Int64>])] = [:]
            for (code, condition) in imageConditions where wanted(code, in: .images) {
                claimed.insert(code)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT l.source_id, l.target_id FROM links l
                    WHERE l.type = \(LinkType.image.rawValue) AND \(condition)
                      AND l.source_id IN (SELECT url_id FROM issues WHERE code = ?)
                    """, arguments: [code])
                for row in rows {
                    let (source, image): (Int64, Int64) = (row[0], row[1])
                    images[image, default: ([], [], [:])].codes.insert(code)
                    images[image]!.pages.insert(source)
                    images[image]!.counts[code, default: []].insert(source)
                }
            }
            if wanted("images_over_100kb", in: .images) {
                claimed.insert("images_over_100kb")
                for image in byCode["images_over_100kb"] ?? [] {
                    let pages = try Int64.fetchAll(db, sql: "SELECT DISTINCT source_id FROM links WHERE target_id = ? AND type = ?",
                                                   arguments: [image, LinkType.image.rawValue])
                    images[image, default: ([], [], [:])].codes.insert("images_over_100kb")
                    images[image]!.pages.formUnion(pages)
                }
            }
            try urls.load(Set(images.keys), db: db)
            var files: [String: [Int64]] = [:]
            for image in images.keys { files[imageFile(urls[image].url, origin: origin), default: []].append(image) }
            for (file, sizes) in files {
                let ordered = sizes.sorted { (images[$0]?.pages.count ?? 0, $1) > (images[$1]?.pages.count ?? 0, $0) }
                var codes: Set<String> = []
                var pages: Set<Int64> = []
                var counts: [String: Set<Int64>] = [:]
                for size in ordered {
                    guard let found = images[size] else { continue }
                    codes.formUnion(found.codes)
                    pages.formUnion(found.pages)
                    counts.merge(found.counts) { $0.union($1) }
                }
                let first = ordered[0]
                let name = IssueEvidenceBuilder.shorten(file, site: origin)
                // A resized copy was a fix of its own before it was known to be the file.
                let earlier = Set(ordered.map { IssueEvidenceBuilder.shorten(imageFile(urls[$0].url, origin: origin, sizes: false), site: origin) })
                    .filter { $0 != name }
                units.append(Fix(group: .images, kind: .image(first), name: name,
                                         severity: worst(Array(codes)), codes: sorted(codes),
                                         pages: try byInlinks(pages), counts: counts.mapValues(\.count),
                                         members: ordered.count > 1 ? ordered : [], aliases: earlier.map { "images|\($0)" }))
            }

            // Site settings: one fix per issue.
            for (code, ids) in byCode where wanted(code, in: .siteSettings) {
                claimed.insert(code)
                guard let definition = lookup(code) else { continue }
                units.append(Fix(group: .siteSettings, kind: .setting(code),
                                         name: "\(definition.category.rawValue): \(definition.title)",
                                         severity: definition.severity, codes: [code], pages: try byInlinks(ids)))
            }

            // Duplicates: one fix per group of pages sharing something.
            var clusters: [Fix] = []
            for (code, column) in clusterColumns where wanted(code, in: .duplicates) {
                claimed.insert(code)
                let ids = byCode[code] ?? []
                guard !ids.isEmpty else { continue }
                var groups: [[Int64]] = []
                var values: [String?] = []
                if column.isEmpty {
                    let members = Set(ids)
                    var parent: [Int64: Int64] = [:]
                    func root(_ id: Int64) -> Int64 {
                        var id = id
                        while let next = parent[id], next != id { id = next }
                        return id
                    }
                    for row in try Row.fetchAll(db, sql: "SELECT url_id, other_id FROM near_duplicates") {
                        let (a, b): (Int64, Int64) = (row[0], row[1])
                        guard members.contains(a), members.contains(b) else { continue }
                        parent[root(a)] = root(b)
                    }
                    groups = Array(Dictionary(grouping: ids, by: root).values)
                    values = groups.map { _ in nil }
                } else {
                    var byValue: [String: [Int64]] = [:]
                    for chunk in ids.chunked(900) {
                        let rows = try Row.fetchAll(db, sql: """
                            SELECT id, CAST(\(column) AS TEXT) FROM urls WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                            """, arguments: StatementArguments(chunk))
                        for row in rows { byValue[row[1] ?? "", default: []].append(row[0]) }
                    }
                    for (value, members) in byValue {
                        groups.append(members)
                        values.append(column == "content_hash" ? nil : value)
                    }
                }
                for (members, value) in zip(groups, values) {
                    // Collection copies are the product card's, and a list's later pages are its first
                    // page split up: alike by design, so neither makes a duplicate.
                    let members = members.filter { !copies.contains($0) && !(shopify && paginationBase(of: urls[$0].url) != nil) }
                    guard members.count >= 2 else { continue }
                    let pages = try byInlinks(members)
                    let first = pages.map(pageName).min() ?? ""
                    // The whole of what they share: quoted to 80 characters, two descriptions that
                    // differ only after that would share a name. The list shows it shorter.
                    func name(quoting length: Int) -> String {
                        switch code {
                        case "title_duplicate": "Duplicate title: “\(truncated(value ?? "", length))”"
                        case "meta_description_duplicate": "Duplicate description: “\(truncated(value ?? "", length))”"
                        case "h1_duplicate": "Duplicate H1: “\(truncated(value ?? "", length))”"
                        case "content_exact_duplicate": "Duplicate content: \(first)"
                        default: "Similar content: \(first)"
                        }
                    }
                    let (whole, earlier) = (name(quoting: .max), name(quoting: 80))
                    clusters.append(Fix(group: .duplicates, kind: .cluster(code: code, value: value), name: whole,
                                        severity: worst([code]), codes: [code], pages: pages,
                                        aliases: earlier == whole ? [] : ["duplicates|\(earlier)"]))
                }
            }
            // Pages that share their content, title, description and H1 are one decision — which to
            // keep — so they're one fix, with each way they're alike as an issue under it.
            for same in Dictionary(grouping: clusters, by: { Set($0.pages) }).values {
                guard same.count > 1 else { units += same; continue }
                let ordered = same.sorted { clusterOrder(of: $0) < clusterOrder(of: $1) }
                let lead = ordered[0]
                let codes = ordered.flatMap(\.codes)
                units.append(Fix(group: .duplicates, kind: lead.kind, name: lead.name, severity: worst(codes),
                                 codes: sorted(codes), pages: lead.pages,
                                 issues: ordered.map { cluster in
                                     FixIssue(name: title(cluster.codes[0]), code: cluster.codes[0], severity: cluster.severity,
                                              pages: cluster.pages,
                                              aliases: cluster.name == lead.name ? [] : ["duplicates|\(cluster.name)"] + cluster.aliases)
                                 }, aliases: lead.aliases))
            }

            if shopify {
                units += try shopifyPages(db: db, byCode: byCode, claimed: claimed, copies: copies, pageLinks: pageLinks,
                                          groups: groups, severities: severities, urls: &urls, site: site)
            } else {
            // Speed: one fix per template a page was measured as, or per page without one.
            var speedPages: [Int64: [String]] = [:]
            for (code, ids) in byCode where wanted(code, in: .speed) {
                claimed.insert(code)
                for id in ids { speedPages[id, default: []].append(code) }
            }
            if !speedPages.isEmpty {
                var templates: [Int64: String] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT url_id, template FROM lighthouse_reports WHERE template IS NOT NULL") {
                    let template: String = row[1]
                    if sharedTemplates.contains(template) { templates[row[0]] = template }
                }
                var byTemplate: [String: [Int64]] = [:]
                for (page, codes) in speedPages {
                    if let template = templates[page] {
                        byTemplate[template, default: []].append(page)
                    } else {
                        units.append(Fix(group: .speed, kind: .page(page), name: pageName(page),
                                                 severity: worst(codes), codes: sorted(codes), pages: [page]))
                    }
                }
                for (template, pages) in byTemplate {
                    let codes = pages.flatMap { speedPages[$0] ?? [] }
                    units.append(Fix(group: .speed, kind: .template(template), name: "\(template) template",
                                             severity: worst(codes), codes: sorted(codes), pages: try byInlinks(pages)))
                }
            }

            // Products, and everything else: one fix per page, with its issues.
            var perPage: [FixGroup: [Int64: [String]]] = [:]
            for (code, ids) in byCode where !claimed.contains(code) {
                guard let definition = lookup(code) else { continue }
                let group = FixGroup.group(for: definition)
                guard group == .products || group.pageSeverity != nil, wanted(code, in: group) else { continue }
                for id in ids { perPage[group, default: [:]][id, default: []].append(code) }
            }
            // Links on a page that are wrong in themselves, and not the theme's, go with its issues.
            for (page, codes) in pageLinks {
                for code in codes {
                    guard let definition = lookup(code), severities.contains(definition.severity) else { continue }
                    let group = FixGroup.pages(definition.severity)
                    if groups.contains(group) { perPage[group, default: [:]][page, default: []].append(code) }
                }
            }
            // A pair measured two ways can straddle two severities: a title over 561 pixels is a
            // warning, over 60 characters a notice. On the same page it's one title, so the milder
            // half goes in with the worse, into its list.
            for pair in measuredPairs {
                guard let primary = lookup(pair.primary), let other = lookup(pair.other) else { continue }
                let (to, from) = (FixGroup.group(for: primary), FixGroup.group(for: other))
                guard to != from, let pages = perPage[from] else { continue }
                for (page, codes) in pages where codes.contains(pair.other) && perPage[to]?[page]?.contains(pair.primary) == true {
                    perPage[from]?[page]?.removeAll { $0 == pair.other }
                    if perPage[from]?[page]?.isEmpty == true { perPage[from]?[page] = nil }
                    perPage[to]?[page]?.append(pair.other)
                }
            }
            // A page's links were once a fix of their own, now taken over by its worst list's fix.
            var linksFix: [Int64: FixGroup] = [:]
            for (page, codes) in pageLinks {
                let worstCode = codes.min { (lookup($0)?.severity ?? .notice) < (lookup($1)?.severity ?? .notice) }
                if let severity = worstCode.flatMap(lookup)?.severity { linksFix[page] = FixGroup.pages(severity) }
            }
            for (group, pages) in perPage {
                for (page, codes) in pages {
                    units.append(Fix(group: group, kind: .page(page), name: pageName(page),
                                             severity: worst(codes), codes: sorted(codes), pages: [page],
                                             aliases: linksFix[page] == group ? ["links|Links on \(pageName(page))"] : []))
                }
            }
            }

            // A name is how the worklist knows a fix from one crawl to the next, so no two in a list
            // may share one. Should two ever be named alike — a link's text is quoted to 60
            // characters — each is told apart by its first page, and by number if even that's shared.
            for same in Dictionary(grouping: units.indices, by: { "\(units[$0].group.rawValue)|\(units[$0].name)" }).values
            where same.count > 1 {
                for index in same {
                    if let first = units[index].pages.map(pageName).min() { units[index].name += " (\(first))" }
                }
                func order(_ index: Int) -> String { "\(units[index].codes) \(units[index].pages.map(pageName).sorted())" }
                for (number, index) in Dictionary(grouping: same, by: { units[$0].name }).values
                    .filter({ $0.count > 1 }).flatMap({ $0.sorted { order($0) < order($1) }.enumerated().dropFirst() }) {
                    units[index].name += " \(number + 1)"
                }
            }

            let order = Dictionary(uniqueKeysWithValues: FixGroup.allCases.enumerated().map { ($1, $0) })
            return units.sorted { a, b in
                if a.group != b.group { return order[a.group]! < order[b.group]! }
                if a.severity != b.severity { return a.severity < b.severity }
                if a.count != b.count { return a.count > b.count }
                return a.name < b.name
            }
        }
    }

    /// A Shopify store's pages, each in the list for its kind of page with its issues as issues.
    /// An issue the theme makes, on most pages of a template, becomes an issue of one fix for the
    /// template instead, and so does a speed problem Lighthouse measured on a template's page.
    /// Collection copies of products are left out: the product-card fix stands for them.
    private static func shopifyPages(db: Database, byCode: [String: [Int64]], claimed: Set<String>,
                                     copies: Set<Int64>, pageLinks: [Int64: [String]], groups: Set<FixGroup>,
                                     severities: Set<IssueSeverity>, urls: inout URLLookup, site: String) throws -> [Fix] {
        func lookup(_ code: String) -> IssueDefinition? { IssueCatalogue.definition(for: code) }
        func severity(_ code: String) -> IssueSeverity { lookup(code)?.severity ?? .notice }
        func title(_ code: String) -> String { FixBuilder.title(code) }
        let pageGroups: Set<FixGroup> = [.errors, .warnings, .notices, .products, .speed]

        // Every issue a page has of its own, at any severity, so a page with only issues left out
        // isn't mistaken for one that's clean.
        var perPage: [Int64: Set<String>] = [:]
        for (code, ids) in byCode where !claimed.contains(code) {
            guard let definition = lookup(code), pageGroups.contains(FixGroup.group(for: definition)) else { continue }
            for id in ids where !copies.contains(id) { perPage[id, default: []].insert(code) }
        }
        // Links on the page that are wrong in themselves, and not the theme's.
        for (page, codes) in pageLinks where !copies.contains(page) { perPage[page, default: []].formUnion(codes) }
        try urls.load(Set(perPage.keys), db: db)

        // How many pages each template has, to judge what's on most of them.
        var templateOf: [Int64: String] = [:]
        var pagesPerTemplate: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, url FROM urls WHERE is_internal = 1 AND state = 1 AND resource_type = 0") {
            let (id, address): (Int64, String) = (row[0], row[1])
            guard !copies.contains(id), let template = ShopifyProfile.template(of: address, ignoringQuery: true) else { continue }
            templateOf[id] = template.rawValue
            pagesPerTemplate[template.rawValue, default: 0] += 1
        }
        var measured: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT url_id, template FROM lighthouse_reports WHERE template IS NOT NULL") {
            let template: String = row[1]
            if sharedTemplates.contains(template) { measured[row[0]] = template }
        }

        // What moves to a template: per template, per issue, the pages.
        var onTemplate: [String: [String: [Int64]]] = [:]
        for (page, codes) in perPage {
            for code in codes {
                if code.hasPrefix("lh_"), let template = measured[page] {
                    onTemplate[template, default: [:]][code, default: []].append(page)
                } else if templateCodes.contains(code), let template = templateOf[page] {
                    onTemplate[template, default: [:]][code, default: []].append(page)
                }
            }
        }
        var moved: [String: [String: [Int64]]] = [:]
        for (template, issues) in onTemplate {
            let total = pagesPerTemplate[template] ?? 0
            for (code, pages) in issues {
                let speed = code.hasPrefix("lh_")
                let most = pages.count >= IssueEvidenceBuilder.templatePages && Double(pages.count) >= templateShare * Double(total)
                if speed || most { moved[template, default: [:]][code] = pages }
            }
        }

        func byInlinks(_ ids: some Sequence<Int64>) throws -> [Int64] {
            let unique = Set(ids)
            try urls.load(unique, db: db)
            return unique.sorted {
                let (a, b) = (urls[$0], urls[$1])
                return a.inlinks != b.inlinks ? a.inlinks > b.inlinks : a.url < b.url
            }
        }
        func ordered(_ codes: some Sequence<String>) -> [String] {
            Array(Set(codes)).sorted { severity($0) != severity($1) ? severity($0) < severity($1) : $0 < $1 }
        }

        var units: [Fix] = []
        for (template, pagesByCode) in moved {
            let group = FixGroup.list(for: ShopifyProfile.Template(rawValue: template))
            guard groups.contains(group) else { continue }
            let all = ordered(pagesByCode.keys)
            let chosen = all.filter { severities.contains(severity($0)) }
            var pagesOf: [String: [Int64]] = [:]
            for code in chosen { pagesOf[code] = try byInlinks(pagesByCode[code] ?? []) }
            units.append(Fix(group: group, kind: .template(template), name: "\(template) template",
                             severity: severity((chosen.isEmpty ? all : chosen)[0]), codes: chosen,
                             pages: try byInlinks(pagesByCode.values.joined()),
                             issues: Self.issues(for: chosen, pages: { pagesOf[$0] ?? [] }, severity: severity),
                             heldOpen: chosen.isEmpty))
        }
        func own(_ page: Int64) -> Set<String> {
            let template = templateOf[page] ?? measured[page]
            return (perPage[page] ?? []).filter { code in !(template.flatMap { moved[$0]?[code] }?.contains(page) ?? false) }
        }

        // The pages of a paginated collection or blog (?page=2, ?page=9…) are one fix with the
        // first: page 9 of a collection is the same template and settings as page 1, and its own
        // fix would repeat page 1's issues once for every page.
        var paginated: [String: [Int64]] = [:]
        for page in perPage.keys {
            if let first = paginationBase(of: urls[page].url) { paginated[first, default: []].append(page) }
        }
        var firstPages: [String: Int64] = [:]
        for first in paginated.keys {
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url = ?", arguments: [first]) { firstPages[first] = id }
        }
        try urls.load(Set(firstPages.values), db: db)
        let grouped = Set(paginated.values.joined()).union(firstPages.values)
        var entries: [(id: Int64, address: String, members: [Int64])] = perPage.keys
            .filter { !grouped.contains($0) }
            .map { ($0, urls[$0].url, [$0]) }
        for (first, pages) in paginated {
            let later = pages.sorted { pageNumber(urls[$0].url) < pageNumber(urls[$1].url) }
            let members = (firstPages[first].map { [$0] } ?? []) + later
            entries.append((firstPages[first] ?? later[0], first, members))
        }

        for entry in entries {
            var codesOn: [String: [Int64]] = [:]
            for member in entry.members {
                for code in own(member) { codesOn[code, default: []].append(member) }
            }
            guard !codesOn.isEmpty else { continue }
            let group = FixGroup.list(for: ShopifyProfile.template(of: entry.address, ignoringQuery: true))
            guard groups.contains(group) else { continue }
            let all = ordered(codesOn.keys)
            let chosen = all.filter { severities.contains(severity($0)) }
            let pages = entry.members.filter { member in codesOn.values.contains { $0.contains(member) } }
            units.append(Fix(group: group, kind: .page(entry.id), name: FixBuilder.pageName(for: entry.address, site: site),
                                     severity: severity((chosen.isEmpty ? all : chosen)[0]), codes: chosen, pages: pages,
                                     issues: Self.issues(for: chosen, pages: { codesOn[$0] ?? [] }, severity: severity),
                                     heldOpen: chosen.isEmpty,
                                     // Its links were once a fix of their own.
                                     aliases: entry.members.filter { pageLinks[$0] != nil }.map {
                                         "links|Links on \(FixBuilder.pageName(for: urls[$0].url, site: site))"
                                     }))
        }
        return units
    }

    /// The first page of a paginated collection or blog, for one of its later pages: /collections/x
    /// for /collections/x?page=9. Nil for anything else, including a query that isn't only the page.
    static func paginationBase(of address: String) -> String? {
        let parts = address.split(separator: "?", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let names = parts[1].split(separator: "&").map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" }
        guard names == ["page"], [.collection, .allProducts, .blog].contains(ShopifyProfile.template(of: parts[0])) else { return nil }
        return parts[0]
    }

    /// Which page of a paginated list an address is: 1 for the first, which has no ?page=.
    static func pageNumber(_ address: String) -> Int {
        guard let query = address.split(separator: "?", maxSplits: 1).dropFirst().first,
              let value = query.split(separator: "=", maxSplits: 1).dropFirst().first, let number = Int(value) else { return 1 }
        return number
    }

    /// A link in the theme: on enough pages that it can't have been typed into each, or in a part
    /// of the page every page shares.
    static func isTheme(pages: Int, positions: [LinkPosition]) -> Bool {
        pages >= IssueEvidenceBuilder.templatePages || (pages >= 2 && positions.contains { $0.isTemplate })
    }

    static func truncated(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
    }

    struct LinkKey: Hashable {
        var target: Int64
        var text: String
    }

    /// Addresses and inlink counts, loaded as they're needed.
    struct URLLookup {
        private var known: [Int64: (url: String, inlinks: Int)] = [:]

        subscript(id: Int64) -> (url: String, inlinks: Int) { known[id] ?? ("", 0) }

        mutating func load(_ ids: Set<Int64>, db: Database) throws {
            let missing = ids.filter { known[$0] == nil }
            for chunk in Array(missing).chunked(900) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, url, inlinks FROM urls WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments(chunk))
                for row in rows { known[row[0]] = (row[1], row[2]) }
            }
        }
    }

    // MARK: - Descriptions

    /// A fix's description: what's wrong where, and how to fix it.
    static func markdown(for unit: Fix, store: CrawlStore, rows: Int) throws -> String {
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let origin = URL(string: config.startURL).flatMap { url in url.scheme.map { "\($0)://\(url.host() ?? "")" } } ?? ""
        let shown = unit.pages.prefix(rows)
        let pageRows = try store.rows(ids: Array(shown))
        func link(_ url: String) -> String {
            "[\(FixBuilder.cell(FixBuilder.pageName(for: url, site: site)))](\(FixBuilder.linkTarget(url)))"
        }
        func heading(_ count: Int, _ what: String) -> String {
            "**\(what)**" + (count > shown.count ? " — the first \(shown.count.formatted()) of \(count.formatted()), most linked-to first" : "")
        }
        func plainTable(_ title: String) -> String {
            ([heading(unit.pages.count, title), "", "| Page |", "|---|"] + pageRows.map { "| \(link($0.url)) |" })
                .joined(separator: "\n")
        }
        func fix(_ code: String, page: Int64) throws -> String {
            try IssueEvidenceBuilder.evidence(for: code, urlID: page, store: store).fix
        }
        var parts: [String] = []

        switch unit.kind {
        case .target(let id):
            guard let target = try store.row(id: id) else { break }
            let status = IssueEvidenceBuilder.statusText(target.statusCode, target.error)
            parts.append("**[\(FixBuilder.cell(IssueEvidenceBuilder.shorten(target.url, site: origin)))](\(FixBuilder.linkTarget(target.url)))** answers \(status). "
                + "Linked from \(unit.pages.count.formatted()) \(unit.pages.count == 1 ? "page" : "pages").")
            let others = try store.rows(ids: unit.members.filter { $0 != id })
            if !others.isEmpty {
                parts.append((["**Also linked with tracking added**, which goes to the same page:", ""] + others.map {
                    "- [\(FixBuilder.cell(IssueEvidenceBuilder.shorten($0.url, site: origin)))](\(FixBuilder.linkTarget($0.url)))"
                }).joined(separator: "\n"))
            }
            for code in unit.codes where targetCodes[code] != nil {
                let evidence = try IssueEvidenceBuilder.evidence(for: code, urlID: id, store: store)
                var section = "**\(title(code))**"
                if code == "redirect_chain" || code == "redirect_loop" {
                    section += evidence.items.map { "\n- \($0.text)" }.joined()
                }
                section += "\n\n**How to fix:** \(evidence.fix)"
                parts.append(section)
            }
            let places = try store.pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT s.id, l.text, l.flags FROM links l JOIN urls s ON s.id = l.source_id
                    WHERE l.target_id IN (\(([id] + unit.members).map { _ in "?" }.joined(separator: ","))) GROUP BY s.id
                    """, arguments: StatementArguments([id] + unit.members))
            }
            var where_: [Int64: (text: String, position: LinkPosition)] = [:]
            for row in places { where_[row[0]] = (row[1], LinkFlags(rawValue: row[2]).position) }
            if let lead = themeLead(where_.values.map(\.position), total: unit.pages.count) { parts.append(lead) }
            if !unit.pages.isEmpty {
                parts.append(([heading(unit.pages.count, "Linked from"), "", "| Page | Link text | Where |", "|---|---|---|"]
                    + pageRows.map { row in
                        let place = where_[row.id]
                        return "| \(link(row.url)) | \(FixBuilder.cell(place?.text ?? "")) | \(place.map { $0.position == .unknown ? "" : $0.position.label } ?? "") |"
                    }).joined(separator: "\n"))
            }

        case .image(let id):
            guard let image = try store.row(id: id) else { break }
            var lead = "**[\(FixBuilder.cell(IssueEvidenceBuilder.shorten(image.url, site: origin)))](\(FixBuilder.linkTarget(image.url)))** "
                + "is on \(unit.pages.count.formatted()) \(unit.pages.count == 1 ? "page" : "pages") with an issue."
            if unit.members.count > 1 {
                lead += " It's one file, at \(unit.members.count) addresses: its alt text and weight are set once, for all of them."
            }
            parts.append(lead)
            if unit.members.count > 1 {
                let addresses = try store.rows(ids: Array(unit.members.prefix(rows)))
                parts.append((["**Its addresses**", ""] + addresses.map {
                    "- [\(FixBuilder.cell(IssueEvidenceBuilder.shorten($0.url, site: origin)))](\(FixBuilder.linkTarget($0.url)))"
                }).joined(separator: "\n"))
            }
            for code in unit.codes {
                var section = "**\(title(code))**"
                if code == "images_over_100kb" {
                    section += " — \((image.sizeBytes ?? 0) / 1_024) KB"
                    section += "\n\n**How to fix:** \(try fix(code, page: id))"
                } else {
                    let count = unit.counts[code] ?? 0
                    section += " — on \(count.formatted()) \(count == 1 ? "page" : "pages")"
                    if let page = unit.pages.first { section += "\n\n**How to fix:** \(try fix(code, page: page))" }
                }
                parts.append(section)
            }
            let sizes = unit.members.isEmpty ? [id] : unit.members
            let places = try store.pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT source_id, text, flags FROM links WHERE type = \(LinkType.image.rawValue)
                      AND target_id IN (\(sizes.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments(sizes))
            }
            var where_: [Int64: (text: String, position: LinkPosition)] = [:]
            for row in places { where_[row[0]] = (row[1], LinkFlags(rawValue: row[2]).position) }
            if let lead = themeLead(where_.values.map(\.position), total: unit.pages.count) { parts.append(lead) }
            parts.append(([heading(unit.pages.count, "Shown on"), "", "| Page | Alt text | Where |", "|---|---|---|"]
                + pageRows.map { row in
                    let place = where_[row.id]
                    let alt = place.map { $0.text.isEmpty ? "—" : FixBuilder.cell(truncated($0.text, 120)) } ?? ""
                    return "| \(link(row.url)) | \(alt) | \(place.map { $0.position == .unknown ? "" : $0.position.label } ?? "") |"
                }).joined(separator: "\n"))

        case .link(let code, let target, let text):
            let address = try store.row(id: target)?.url ?? ""
            let anchor = text.isEmpty ? "The link" : "“\(text)”"
            parts.append("**\(anchor) → [\(FixBuilder.cell(IssueEvidenceBuilder.shorten(address, site: origin)))](\(FixBuilder.linkTarget(address)))** "
                + "is on \(unit.pages.count.formatted()) pages. It's part of the theme: change it once and it clears from all of them.")
            if let definition = IssueCatalogue.definition(for: code) {
                parts.append("**\(title(code))**\n\n\(definition.description)\n\n**How to fix:** \(definition.howToFix)")
            }
            parts.append(plainTable("Pages"))

        case .setting(let code):
            guard let definition = IssueCatalogue.definition(for: code) else { break }
            parts.append("**\(unit.pages.count.formatted()) \(unit.pages.count == 1 ? "URL" : "URLs") affected on \(site).** "
                + "It's one setting for the whole site, so this is one task rather than one per page.")
            parts.append("\(definition.description)\n\n**How to fix:** \(definition.howToFix)")
            parts.append(try FixBuilder.urlTable(code: code, ids: unit.pages, site: site, store: store, rows: rows))

        case .cluster(let code, _) where !unit.issues.isEmpty:
            guard let definition = IssueCatalogue.definition(for: code) else { break }
            parts.append("**These \(unit.pages.count.formatted()) pages are alike \(unit.issues.count) ways**, so they're one "
                + "decision — which page to keep — rather than a fix for each:")
            parts.append(try unit.issues.map { issue in
                "- \(issue.name): they \(likeness(issue.code, value: try clusterValue(issue.code, page: issue.pages.first, store: store)))"
            }.joined(separator: "\n"))
            let advice = unit.pages.first.flatMap { try? fix(code, page: $0) }
            parts.append("**How to fix:** \(advice ?? definition.howToFix)")
            parts.append(plainTable("Pages"))

        case .cluster(let code, let value):
            guard let definition = IssueCatalogue.definition(for: code) else { break }
            parts.append("**\(unit.pages.count.formatted()) pages \(likeness(code, value: value)).**")
            let advice = unit.pages.first.flatMap { try? fix(code, page: $0) }
            parts.append("\(definition.description)\n\n**How to fix:** \(advice ?? definition.howToFix)")
            parts.append(plainTable("Pages"))

        case .template(let template) where !unit.issues.isEmpty:
            let kind = template.lowercased()
            parts.append("**These issues are on most \(kind) pages**, so they come from the theme's \(kind) template rather "
                + "than each page: fix them there, once, and every page clears. Each is a issue listing its pages.")
            parts.append(unit.issues.map { "- \($0.name) — on \($0.pages.count.formatted()) \($0.pages.count == 1 ? "page" : "pages")" }
                .joined(separator: "\n"))

        case .template(let template):
            parts.append("**Measured as the store's \(template) page.** Every \(template.lowercased()) page is built from the theme's "
                + "\(template.lowercased()) template, so fix it there, once.")
            for row in pageRows { parts.append(try pageIssues(row.id, url: row.url, unit: unit, store: store, site: site, heading: true)) }

        case .pattern(let kind):
            let (what, fix) = ChangePatterns.explanation(of: kind)
            parts.append("**\(unit.members.count.formatted()) addresses, linked from \(unit.pages.count.formatted()) "
                + "\(unit.pages.count == 1 ? "page" : "pages").** \(what)")
            parts.append("**How to fix:** \(fix)")
            let members = try store.rows(ids: Array(unit.members.prefix(rows)))
            let linked = try store.pool.read { db in
                Dictionary(uniqueKeysWithValues: try members.map { member in
                    (member.id, try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT source_id) FROM links WHERE target_id = ?",
                                                 arguments: [member.id]) ?? 0)
                })
            }
            parts.append((["**The addresses**", "", "| Address | Answers | Linked from |", "|---|---|---|"] + members.map { member in
                let answer = member.redirectURL.map { "\(member.statusCode.map(String.init) ?? "") → \(link($0))" }
                    ?? IssueEvidenceBuilder.statusText(member.statusCode, member.error)
                return "| \(link(member.url)) | \(answer) | \((linked[member.id] ?? 0).formatted()) |"
            }).joined(separator: "\n"))
            if !unit.pages.isEmpty { parts.append(plainTable("Pages linking to them")) }

        case .productCards:
            let addresses = unit.counts["addresses"] ?? 0
            var lead = "**\(unit.pages.count.formatted()) \(unit.pages.count == 1 ? "page links" : "pages link") to products through a collection's address** "
                + "(/collections/…/products/…) rather than the product's own (/products/…)."
            if addresses > 0 {
                lead += " \(addresses.formatted()) of those \(addresses == 1 ? "address redirects" : "addresses redirect") to the product's own, "
                    + "so every click, and every visit from a search engine, takes an extra hop."
            }
            if let copies = unit.counts["copies"], copies > 0 {
                lead += " \(copies.formatted()) more \(copies == 1 ? "is a copy" : "are copies") of the product's page, pointing search "
                    + "engines at the product's own: their notices are counted here, not as a task each, and go when the card is fixed."
            }
            parts.append(lead)
            parts.append("**It's one change.** The links come from the theme's product card, the snippet every collection and "
                + "product page uses to show a product. Make it link to the product's own address and every page listed "
                + "here clears at once. On Shopify the card usually builds the link with `product.url | within: collection`: "
                + "drop `| within: collection`.")
            if addresses > 0 {
                let examples = try store.pool.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT u.url, u.redirect_url FROM issues i JOIN urls u ON u.id = i.url_id
                        WHERE i.code IN ('response_internal_3xx', 'redirect_chain') AND u.url LIKE '%/collections/%/products/%'
                        GROUP BY u.id ORDER BY u.inlinks DESC, u.url LIMIT 10
                        """)
                }
                parts.append((["**For example**", "", "| Linked as | Goes to |", "|---|---|"] + examples.map { row in
                    let from: String = row[0]
                    let to: String? = row[1]
                    return "| \(link(from)) | \(to.map(link) ?? "") |"
                }).joined(separator: "\n"))
            }
            parts.append(plainTable("Pages with these links"))

        case .page(let id) where !unit.issues.isEmpty:
            guard let row = try store.row(id: id) else { break }
            let address = paginationBase(of: row.url) ?? row.url
            var lead = "**\(link(address))** has \(unit.issues.count) \(unit.issues.count == 1 ? "issue" : "issues"), "
                + "each a issue with what's wrong and how to fix it"
            if unit.pages.count > 1 || paginationBase(of: row.url) != nil {
                lead += ". Its later pages (?page=2 and on) are filed here too, since they're built the same way; "
                    + "each issue says which pages have it"
            }
            parts.append(lead + ":")
            parts.append(unit.issues.map { "- \($0.name) — \(label($0.severity))" }.joined(separator: "\n"))

        case .page(let id):
            guard let row = pageRows.first else { break }
            parts.append(try pageIssues(id, url: row.url, unit: unit, store: store, site: site, heading: false))
        }
        return parts.joined(separator: "\n\n")
    }

    /// A issue's description: the issue on its page, or on every page of a template.
    static func markdown(for issue: FixIssue, in unit: Fix, store: CrawlStore, rows: Int) throws -> String {
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        guard let first = issue.pages.first else { return "" }
        // One way a group of pages is alike reads as that likeness on its own.
        if case .cluster = unit.kind {
            let alone = Fix(group: unit.group, kind: .cluster(code: issue.code, value: try clusterValue(issue.code, page: first, store: store)),
                            name: issue.name, severity: issue.severity, codes: [issue.code], pages: issue.pages)
            return try markdown(for: alone, store: store, rows: rows)
        }
        if case .template(let template) = unit.kind {
            let shown = try store.rows(ids: Array(issue.pages.prefix(rows)))
            let evidence = try IssueEvidenceBuilder.evidence(for: issue.code, urlID: first, store: store)
            var parts = ["**On \(issue.pages.count.formatted()) \(template.lowercased()) pages**, so it's the theme's \(template.lowercased()) template to fix, once."]
            if let definition = IssueCatalogue.definition(for: issue.code) { parts.append(definition.description) }
            for other in issue.also { parts.append("Also flagged as *\(title(other))*: the same problem, measured another way.") }
            if !evidence.items.isEmpty {
                parts.append("**On \(FixBuilder.pageName(for: shown.first?.url ?? "", site: site)), for example**"
                    + evidence.items.prefix(5).map { "\n- \($0.text)" }.joined())
            }
            parts.append("**How to fix:** \(evidence.fix)")
            let more = issue.pages.count > shown.count
                ? " — the first \(shown.count.formatted()) of \(issue.pages.count.formatted()), most linked-to first" : ""
            parts.append((["**Pages**\(more)", "", "| Page |", "|---|"] + shown.map {
                "| [\(FixBuilder.cell(FixBuilder.pageName(for: $0.url, site: site)))](\(FixBuilder.linkTarget($0.url))) |"
            }).joined(separator: "\n"))
            return parts.joined(separator: "\n\n")
        }
        let url = try store.row(id: first)?.url ?? ""
        var single = unit
        single.codes = [issue.code] + issue.also
        var text = try pageIssues(first, url: url, unit: single, store: store, site: site, heading: false)
        if issue.pages.count > 1 {
            let others = try store.rows(ids: Array(issue.pages.dropFirst().prefix(rows)))
            text += "\n\n**Also on** " + others.map {
                "[\(FixBuilder.cell(FixBuilder.pageName(for: $0.url, site: site)))](\(FixBuilder.linkTarget($0.url)))"
            }.joined(separator: ", ")
            if issue.pages.count - 1 > others.count { text += " and \((issue.pages.count - 1 - others.count).formatted()) more" }
        }
        return text
    }

    static func label(_ severity: IssueSeverity) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .notice: "notice"
        }
    }

    /// A page's issues in a unit: each one's specifics and its fix.
    private static func pageIssues(_ id: Int64, url: String, unit: Fix, store: CrawlStore,
                                   site: String, heading: Bool) throws -> String {
        let link = "[\(FixBuilder.cell(FixBuilder.pageName(for: url, site: site)))](\(FixBuilder.linkTarget(url)))"
        let codes = Set(try store.issueCodes(for: id))
        var text = heading ? "### \(link)" : "**\(link)**"
        for code in unit.codes where codes.contains(code) {
            // A pair measured two ways is one problem: shown once, under the worse, with both
            // measurements and one fix.
            let pair = pair(of: code).flatMap { codes.contains($0.primary) && codes.contains($0.other)
                && unit.codes.contains($0.primary) && unit.codes.contains($0.other) ? $0 : nil }
            if let pair, code == pair.other { continue }
            var evidence = try IssueEvidenceBuilder.evidence(for: code, urlID: id, store: store)
            if let pair {
                let other = try IssueEvidenceBuilder.evidence(for: pair.other, urlID: id, store: store)
                evidence.items += other.items.filter { item in !evidence.items.contains { $0.text == item.text } }
            }
            // Links in the theme are fixes of their own.
            if unit.group == .links {
                evidence.items.removeAll { isTheme(pages: $0.pagesWithSameLink ?? 1, positions: [$0.position ?? .unknown]) }
            }
            text += "\n\n**\(pair?.name ?? title(code))**"
            text += evidence.items.map { item in
                var line = "\n- \(item.text)"
                if let position = item.position { line += " — in the \(position.label.lowercased())" }
                return line
            }.joined()
            if evidence.more > 0 { text += "\n- …and \(evidence.more.formatted()) more" }
            text += "\n\n**How to fix:** \(evidence.fix)"
        }
        return text
    }

    /// When most of the links come from the theme, the one place to fix it.
    private static func themeLead(_ positions: [LinkPosition], total: Int) -> String? {
        let theme = positions.filter(\.isTemplate)
        guard theme.count >= IssueEvidenceBuilder.templatePages,
              let place = Dictionary(grouping: theme, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        return "**Start here:** \(theme.count.formatted()) of these \(total.formatted()) pages carry it in the "
            + "\(place.label.lowercased()). It's part of the theme: change it once and they clear together."
    }

    static func title(_ code: String) -> String {
        guard let definition = IssueCatalogue.definition(for: code) else { return code }
        return "\(definition.category.rawValue): \(definition.title)"
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - Formatting

extension FixBuilder {
    /// What the fixes list shows for a fix: its name, shortened. The name stays as it is, since
    /// it's how the worklist knows the fix from one crawl to the next; the label can change freely.
    ///
    /// An image is its file name; an address elsewhere loses its https://www. and tracking, and
    /// the middle of its path when long; encoded characters (%C2%AE) are shown as themselves; and
    /// a duplicated title, description or H1 is quoted shorter.
    public static func label(group: String, name: String) -> String {
        if group == FixGroup.images.rawValue, name.hasPrefix("/") || name.hasPrefix("http") {
            let parts = name.split(separator: "?", maxSplits: 1).map(String.init)
            let file = parts[0].split(separator: "/").last.map(String.init) ?? parts[0]
            return decoded(file) + (parts.count == 2 ? "?\(parts[1])" : "")
        }
        if let match = name.wholeMatch(of: /(Duplicate (?:title|description|H1)): “(.*)”( \(.*\))?/) {
            var quote = String(match.2)
            if quote.hasSuffix("…") { quote.removeLast() }
            return "\(match.1): “\(truncated(quote, labelQuote))”" + (match.3.map { decoded(String($0)) } ?? "")
        }
        // An address ends the name, if there's one in it: "Broken link: /gone", "Links on /about".
        guard let space = name.lastIndex(of: " ").map(name.index(after:)) ?? (name.hasPrefix("/") ? name.startIndex : nil) else {
            return name
        }
        let address = String(name[space...])
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            return String(name[..<space]) + readable(external: address)
        }
        if address.hasPrefix("/") { return String(name[..<space]) + decoded(address) }
        return name
    }

    /// How long a duplicated title, description or H1 is quoted in a label.
    static let labelQuote = 50
    /// How long another site's address gets in a label before its middle is left out.
    static let labelAddress = 80

    /// Query parameters that only say where a click came from.
    /// Ads and analytics, share buttons (Forbes' ?sh=, YouTube's ?si=), and Shopify's search and
    /// recommendations (?_psid=, ?_pos=); utm_ parameters are matched by their prefix.
    static let trackingParameters: Set = ["gclid", "gclsrc", "gbraid", "wbraid", "dclid", "msclkid", "fbclid", "srsltid",
                                          "pscid", "mc_cid", "mc_eid", "_ga", "_gl", "igshid", "yclid", "ref_src",
                                          "sh", "si", "smid",
                                          "_psid", "_pos", "_psq", "_ss", "_v", "_sid", "_fid",
                                          "pr_prod_strat", "pr_rec_id", "pr_rec_pid", "pr_ref_pid", "pr_seq"]

    static func isTracking(_ parameter: Substring) -> Bool {
        let name = parameter.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        return trackingParameters.contains(name) || name.hasPrefix("utm_")
    }

    /// The address without its tracking parameters; nil when it has none.
    static func withoutTracking(_ address: String) -> String? {
        var rest = Substring(address)
        var fragment: Substring = ""
        if let hash = rest.firstIndex(of: "#") { (rest, fragment) = (rest[..<hash], rest[hash...]) }
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let items = parts[1].split(separator: "&")
        let kept = items.filter { !isTracking($0) }
        guard kept.count < items.count else { return nil }
        return String(parts[0]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + fragment
    }

    /// A copy of a page with nothing but tracking added — /products/x?_psid=1 — which answers with
    /// the page itself.
    static func isTrackingCopy(_ address: String) -> Bool {
        guard let clean = withoutTracking(address) else { return false }
        return !clean.contains("?")
    }

    /// Shopify's sign-in, which the theme's account link goes through: Shopify's to run, not the store's.
    static func isShopifySignIn(_ address: String) -> Bool {
        let path = address.hasPrefix("/") ? address : URL(string: address)?.path() ?? ""
        return path.firstMatch(of: /^(\/[a-z]{2}(-[a-z]{2,4})?)?\/customer_authentication\//) != nil
    }

    /// Whether a name the worklist has is for something no longer filed as a fix: a tracking copy of
    /// a page, Shopify's sign-in, or the links on a product's collection copy, which are the
    /// product's — "/products/x?_psid=1", "Links on /products/x?_psid=1", "Redirect:
    /// /customer_authentication/redirect", "Links on /collections/c/products/x".
    static func isLeftOut(name: String) -> Bool {
        let address = name.split(separator: " ").last.map(String.init) ?? name
        guard address.hasPrefix("/") else { return false }
        if name.hasPrefix("Links on "), EcommercePaths.product(path: address)?.collectionScoped == true { return true }
        return isTrackingCopy(address) || isShopifySignIn(address)
    }

    /// Another site's address as a label: without https:// or tracking, and with the middle of a
    /// long path left out. http:// and www. stay, since either can be why a link redirects.
    static func readable(external address: String) -> String {
        guard let url = URL(string: address), let host = url.host() else { return address }
        let site = (url.scheme == "https" ? "" : "\(url.scheme ?? "http")://") + host + (url.port.map { ":\($0)" } ?? "")
        let path = decoded(url.path())
        let query = (url.query() ?? "").split(separator: "&").filter { !isTracking($0) }
        let whole = site + (path == "/" ? "" : path) + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        guard whole.count > labelAddress else { return whole }
        // As much of the end of the path as fits: the end is what tells one page from another.
        var tail: [Substring] = []
        for segment in path.split(separator: "/").reversed() {
            let longer = "\(site)/…/" + ([segment] + tail).joined(separator: "/")
            if !tail.isEmpty, longer.count > labelAddress { break }
            tail.insert(segment, at: 0)
        }
        return truncated("\(site)/…/" + tail.joined(separator: "/"), labelAddress)
    }

    /// An address with its percent-encoding read: "chimney-sheep®" for "chimney-sheep%C2%AE".
    static func decoded(_ address: String) -> String {
        address.removingPercentEncoding ?? address
    }

    /// The whole URL is unreadable as a name, so the path leads and the host follows.
    static func pageName(for address: String, site: String) -> String {
        guard let url = URL(string: address) else { return address }
        let path = url.path().isEmpty ? "/" : url.path()
        let query = url.query().map { "?\($0)" } ?? ""
        let host = url.host() ?? site
        return host == site ? "\(path)\(query)" : "\(host)\(path)\(query)"
    }

    /// Affected URLs as a Markdown table: the page (a link), what on it is wrong, and where. When no
    /// page has anything more specific to say — an uppercase URL is just its URL — it's one column.
    static func urlTable(code: String, ids: [Int64], site: String, store: CrawlStore, rows limit: Int) throws -> String {
        let shown = Array(ids.prefix(max(1, limit)))
        var entries: [(page: String, wrong: String, place: String)] = []
        for row in try store.rows(ids: shown) {
            let evidence = try IssueEvidenceBuilder.evidence(for: code, urlID: row.id, store: store)
            var wrong = evidence.items.first?.text ?? ""
            let others = evidence.items.count + evidence.more - 1
            if others > 0 { wrong += " (and \(others) more)" }
            let link = "[\(cell(pageName(for: row.url, site: site)))](\(linkTarget(row.url)))"
            entries.append((link, cell(wrong), evidence.items.first?.position?.label ?? ""))
        }
        var lines = ["**Affected URLs**" + (ids.count > shown.count
            ? " — the first \(shown.count.formatted()) of \(ids.count.formatted()), most linked-to first" : ""), ""]
        if entries.allSatisfy({ $0.wrong.isEmpty && $0.place.isEmpty }) {
            lines += ["| URL |", "|---|"] + entries.map { "| \($0.page) |" }
        } else {
            lines += ["| URL | What's wrong | Where |", "|---|---|---|"]
                + entries.map { "| \($0.page) | \($0.wrong) | \($0.place) |" }
        }
        return lines.joined(separator: "\n")
    }

    /// Text safe inside a table cell: a pipe would start a new column and a newline a new row.
    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// A URL safe as a Markdown link target. Brackets and spaces end the link early — and one
    /// client's broken Liquid template put both into its URLs.
    static func linkTarget(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }
}
