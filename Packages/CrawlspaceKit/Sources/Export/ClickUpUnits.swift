import Audit
import CrawlCore
import Foundation
import GRDB
import Storage

/// The lists a crawl's issues are filed into. Links, images, site settings and duplicates each get
/// a list of their own, because one fix there usually clears many pages. What's left is filed page
/// by page: on a Shopify store into a list per kind of page (products, collections, pages, blog
/// posts and the rest), elsewhere into a list per severity, with speed and products beside them.
public enum ClickUpTopic: String, CaseIterable, Codable, Sendable {
    case links, images, siteSettings, duplicates, speed, products, collections, storePages, blog, otherPages
    case errors, warnings, notices

    /// The lists a crawl files into: by kind of page on a Shopify store, by severity elsewhere.
    public static func topics(shopify: Bool) -> [ClickUpTopic] {
        shopify ? [.links, .images, .siteSettings, .duplicates, .products, .collections, .storePages, .blog, .otherPages]
                : [.links, .images, .siteSettings, .duplicates, .speed, .products, .errors, .warnings, .notices]
    }

    /// The list a Shopify page goes into, by the template it's built from.
    public static func list(for template: ShopifyProfile.Template?) -> ClickUpTopic {
        switch template {
        case .product: .products
        case .collection, .allProducts: .collections
        case .page: .storePages
        case .blog, .article: .blog
        default: .otherPages
        }
    }

    /// A line for the export panel saying what the list holds.
    public func hint(shopify: Bool) -> String {
        switch self {
        case .links: "A task per broken or redirecting URL, with every page linking to it, and per link in the theme."
        case .images: "A task per image file, whatever sizes it's shown at, with every page showing it."
        case .siteSettings: "A task per setting, such as a security header, rather than per page."
        case .duplicates: "A task per group of pages sharing a title, description, H1 or content."
        case .speed: "A task per template Lighthouse measured."
        case .products: shopify ? "A task per product page, its issues as subtasks; theme issues on most products in one Product template task."
            : "A task per product page, with what its data is missing."
        case .collections: "A task per collection page, its issues as subtasks; theme issues in one Collection template task."
        case .storePages: "A task per page (/pages/…), its issues as subtasks."
        case .blog: "A task per blog and blog post, its issues as subtasks; theme issues in one Article template task."
        case .otherPages: "The home page and anything else, a task each with its issues as subtasks."
        case .errors: "A task per page, with the rest of its errors."
        case .warnings: "A task per page, with the rest of its warnings."
        case .notices: "A task per page, with the rest of its notices."
        }
    }

    public var label: String {
        switch self {
        case .links: "Links"
        case .images: "Images"
        case .siteSettings: "Site settings"
        case .duplicates: "Duplicates"
        case .speed: "Speed"
        case .products: "Products"
        case .collections: "Collections"
        case .storePages: "Pages"
        case .blog: "Blog posts"
        case .otherPages: "Other pages"
        case .errors: "Errors"
        case .warnings: "Warnings"
        case .notices: "Notices"
        }
    }

    /// The list of pages for a severity.
    public static func pages(_ severity: IssueSeverity) -> ClickUpTopic {
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

    /// The tag that says which list a task belongs to, so a list shared by several can tell them
    /// apart. Page tasks share one, and their severity tag says which.
    var tag: String {
        switch self {
        case .siteSettings: "site-settings"
        case .storePages: "shopify-pages"
        case .otherPages: "other-pages"
        case .errors, .warnings, .notices: "pages"
        default: rawValue
        }
    }

    public static func topic(for definition: IssueDefinition) -> ClickUpTopic {
        let code = definition.code
        if ClickUpUnitBuilder.targetCodes[code] != nil || ClickUpUnitBuilder.linkSourceCodes.contains(code)
            || ClickUpUnitBuilder.linkAttributeCodes.contains(code) || code == ClickUpUnitBuilder.productCardCode { return .links }
        if definition.category == .images { return .images }
        if definition.category == .security || definition.category == .sitemaps
            || ClickUpUnitBuilder.settingCodes.contains(code) { return .siteSettings }
        if ClickUpUnitBuilder.clusterColumns[code] != nil { return .duplicates }
        if definition.category == .speed { return .speed }
        if definition.category == .ecommerce { return .products }
        return pages(definition.severity)
    }
}

/// One thing to fix, which becomes one task: a broken URL and every link to it, an image and every
/// page showing it, a server setting, a group of pages sharing a title, or a page and its issues.
public struct ClickUpUnit: Sendable, Hashable {
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
    }

    public var topic: ClickUpTopic
    public var kind: Kind
    /// The task's name, which is also how the next export finds it.
    public var name: String
    /// The worst of its issues: the task's priority and severity tag.
    public var severity: IssueSeverity
    /// Issue codes, worst first.
    public var codes: [String]
    /// The pages it lists, most linked-to first.
    public var pages: [Int64]
    /// Pages per issue code, where that differs from `pages`.
    public var counts: [String: Int] = [:]
    /// Each issue as a subtask: a Shopify page's issues, or a template's.
    public var subtasks: [ClickUpSubtask] = []
    /// Everything it stands for, where that's more than one URL: every size of an image file.
    public var members: [Int64] = []
    /// True when it has issues only at severities left out of this export: its task, if there is
    /// one, is left as it is rather than closed.
    public var heldOpen = false

    /// What the task's count is of: issues on a page, otherwise pages.
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

/// One issue under a task: on a page, or on most pages built from a template.
public struct ClickUpSubtask: Sendable, Hashable {
    public var name: String
    public var code: String
    public var severity: IssueSeverity
    /// The pages it's on, most linked-to first.
    public var pages: [Int64]
    /// The other half of a pair measured two ways, filed with it as one: a title over 60 characters
    /// and over 561 pixels is one title to shorten.
    public var also: [String] = []
}

/// Works out the units a crawl's issues come to, and writes each one's task.
public enum ClickUpUnitBuilder {
    /// Issues on a URL that links lead to, and the issue on the pages that link to it. Both are one
    /// fix, so both go in the URL's task.
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
    /// subtask and one fix. The first of each is the worse, and names the problem.
    static let measuredPairs: [(primary: String, other: String, name: String)] = [
        ("title_over_561_pixels", "title_over_60_characters", "Page Titles: Too Long"),
        ("meta_description_over_985_pixels", "meta_description_over_155_characters", "Meta Description: Too Long"),
        ("directives_noindex", "directives_nofollow", "Directives: Noindex and Nofollow"),
    ]

    /// The pair a code belongs to, if any.
    static func pair(of code: String) -> (primary: String, other: String, name: String)? {
        measuredPairs.first { $0.primary == code || $0.other == code }
    }

    /// Subtasks for issues, a pair measured two ways as one where both are there.
    static func subtasks(for codes: [String], pages: (String) -> [Int64], severity: (String) -> IssueSeverity) -> [ClickUpSubtask] {
        var result: [ClickUpSubtask] = []
        var done: Set<String> = []
        for code in codes where !done.contains(code) {
            if let pair = pair(of: code), codes.contains(pair.primary), codes.contains(pair.other) {
                done.formUnion([pair.primary, pair.other])
                let first = pages(pair.primary)
                let together = first + pages(pair.other).filter { !first.contains($0) }
                result.append(ClickUpSubtask(name: pair.name, code: pair.primary, severity: min(severity(pair.primary), severity(pair.other)),
                                             pages: together, also: [pair.other]))
            } else {
                done.insert(code)
                result.append(ClickUpSubtask(name: title(code), code: code, severity: severity(code), pages: pages(code)))
            }
        }
        return result
    }

    /// The share of a template's pages an issue has to be on to count as the template's.
    static let templateShare = 0.8

    /// An image's file, whatever size or version it's asked for at: its address without the query,
    /// when the address names an image file (logo.png?width=600, logo.png?ver=3). An address that
    /// doesn't, such as image.php?id=12, keeps its query, since that's what says which image it is.
    static func imageFile(_ address: String) -> String {
        let parts = address.split(separator: "?", maxSplits: 1)
        guard parts.count == 2, let path = URL(string: String(parts[0]))?.pathExtension.lowercased(),
              imageExtensions.contains(path) else { return address }
        return String(parts[0])
    }

    static let imageExtensions: Set = ["jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "bmp", "tif", "tiff", "ico", "heic"]

    /// Lighthouse templates that stand for many pages; home, cart and search are one page each.
    static let sharedTemplates: Set = ["Product", "Collection", "Article", "Blog", "Page"]

    // MARK: - Units

    public static func units(store: CrawlStore, severities: Set<IssueSeverity>,
                             topics chosen: Set<ClickUpTopic> = Set(ClickUpTopic.allCases)) throws -> [ClickUpUnit] {
        let config = try store.loadConfig()
        let shopify = ShopifyProfile.isStore(config)
        let topics = chosen.intersection(ClickUpTopic.topics(shopify: shopify))
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let origin = URL(string: config.startURL).flatMap { url in url.scheme.map { "\($0)://\(url.host() ?? "")" } } ?? ""

        return try store.pool.read { db in
            var byCode: [String: [Int64]] = [:]
            let cursor = try Row.fetchCursor(db, sql: "SELECT code, url_id FROM issues")
            while let row = try cursor.next() { byCode[row[0], default: []].append(row[1]) }

            var urls = URLLookup()
            try urls.load(Set(byCode.values.joined()), db: db)

            func lookup(_ code: String) -> IssueDefinition? { IssueCatalogue.definition(for: code) }
            func wanted(_ code: String, in topic: ClickUpTopic) -> Bool {
                guard let definition = lookup(code), topics.contains(topic),
                      ClickUpTopic.topic(for: definition) == topic else { return false }
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
                let unique = Set(ids)
                try urls.load(unique, db: db)
                return unique.sorted {
                    let (a, b) = (urls[$0], urls[$1])
                    return a.inlinks != b.inlinks ? a.inlinks > b.inlinks : a.url < b.url
                }
            }
            func shown(_ id: Int64) -> String { IssueEvidenceBuilder.shorten(urls[id].url, site: origin) }
            func pageName(_ id: Int64) -> String { ClickUpExporter.pageName(for: urls[id].url, site: site) }

            var units: [ClickUpUnit] = []
            var claimed: Set<String> = []

            // Links: one task per URL that links lead somewhere wrong.
            var targets: [Int64: [String]] = [:]
            for (code, ids) in byCode where targetCodes[code] != nil && wanted(code, in: .links) {
                claimed.insert(code)
                for id in ids { targets[id, default: []].append(code) }
            }
            // A collection's product addresses that redirect to the product's own are the product
            // card's doing, as are pages flagged for linking to them: one task for the lot.
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
                units.append(ClickUpUnit(topic: .links, kind: .productCards, name: "Product cards: links through collection addresses",
                                         severity: worst(Array(codes)), codes: sorted(codes), pages: try byInlinks(linkers),
                                         counts: ["addresses": cardTargets.count, "copies": servedCopies.count]))
            }
            for (id, codes) in targets {
                let linkers = try Int64.fetchAll(db, sql: "SELECT DISTINCT source_id FROM links WHERE target_id = ?", arguments: [id])
                var all = codes
                for code in codes { if let paired = targetCodes[code] ?? nil, byCode[paired] != nil { all.append(paired) } }
                let prefix = codes.contains(where: brokenCodes.contains) ? "Broken link"
                    : codes.contains("response_external_unverified") ? "Unverified link" : "Redirect"
                units.append(ClickUpUnit(topic: .links, kind: .target(id), name: "\(prefix): \(shown(id))",
                                         severity: worst(all), codes: sorted(all), pages: try byInlinks(linkers)))
            }
            for code in linkSourceCodes { claimed.insert(code) }

            // Links that are wrong in themselves: one task per link in the theme, and one per page
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
                        units.append(ClickUpUnit(topic: .links, kind: .link(code: code, target: key.target, text: key.text),
                                                 name: "\(label): \(text)\(shown(key.target))", severity: worst([code]),
                                                 codes: [code], pages: try byInlinks(sources)))
                    } else {
                        for source in sources { pageLinks[source, default: []].append(code) }
                    }
                }
            }
            for (page, codes) in pageLinks {
                units.append(ClickUpUnit(topic: .links, kind: .page(page), name: "Links on \(pageName(page))",
                                         severity: worst(codes), codes: sorted(codes), pages: [page]))
            }

            // Images: one task per image file, with every page showing it. A CDN serves one file at
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
            for image in images.keys { files[imageFile(urls[image].url), default: []].append(image) }
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
                units.append(ClickUpUnit(topic: .images, kind: .image(first), name: name,
                                         severity: worst(Array(codes)), codes: sorted(codes),
                                         pages: try byInlinks(pages), counts: counts.mapValues(\.count),
                                         members: ordered.count > 1 ? ordered : []))
            }

            // Site settings: one task per issue.
            for (code, ids) in byCode where wanted(code, in: .siteSettings) {
                claimed.insert(code)
                guard let definition = lookup(code) else { continue }
                units.append(ClickUpUnit(topic: .siteSettings, kind: .setting(code),
                                         name: "\(definition.category.rawValue): \(definition.title)",
                                         severity: definition.severity, codes: [code], pages: try byInlinks(ids)))
            }

            // Duplicates: one task per group of pages sharing something.
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
                    let name = switch code {
                    case "title_duplicate": "Duplicate title: “\(truncated(value ?? "", 80))”"
                    case "meta_description_duplicate": "Duplicate description: “\(truncated(value ?? "", 80))”"
                    case "h1_duplicate": "Duplicate H1: “\(truncated(value ?? "", 80))”"
                    case "content_exact_duplicate": "Duplicate content: \(first)"
                    default: "Similar content: \(first)"
                    }
                    units.append(ClickUpUnit(topic: .duplicates, kind: .cluster(code: code, value: value), name: name,
                                             severity: worst([code]), codes: [code], pages: pages))
                }
            }

            if shopify {
                units += try shopifyPages(db: db, byCode: byCode, claimed: claimed, copies: copies, topics: topics,
                                          severities: severities, urls: &urls, site: site)
            } else {
            // Speed: one task per template a page was measured as, or per page without one.
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
                        units.append(ClickUpUnit(topic: .speed, kind: .page(page), name: pageName(page),
                                                 severity: worst(codes), codes: sorted(codes), pages: [page]))
                    }
                }
                for (template, pages) in byTemplate {
                    let codes = pages.flatMap { speedPages[$0] ?? [] }
                    units.append(ClickUpUnit(topic: .speed, kind: .template(template), name: "\(template) template",
                                             severity: worst(codes), codes: sorted(codes), pages: try byInlinks(pages)))
                }
            }

            // Products, and everything else: one task per page, with its issues.
            var perPage: [ClickUpTopic: [Int64: [String]]] = [:]
            for (code, ids) in byCode where !claimed.contains(code) {
                guard let definition = lookup(code) else { continue }
                let topic = ClickUpTopic.topic(for: definition)
                guard topic == .products || topic.pageSeverity != nil, wanted(code, in: topic) else { continue }
                for id in ids { perPage[topic, default: [:]][id, default: []].append(code) }
            }
            // A pair measured two ways can straddle two severities: a title over 561 pixels is a
            // warning, over 60 characters a notice. On the same page it's one title, so the milder
            // half goes in with the worse, into its list.
            for pair in measuredPairs {
                guard let primary = lookup(pair.primary), let other = lookup(pair.other) else { continue }
                let (to, from) = (ClickUpTopic.topic(for: primary), ClickUpTopic.topic(for: other))
                guard to != from, let pages = perPage[from] else { continue }
                for (page, codes) in pages where codes.contains(pair.other) && perPage[to]?[page]?.contains(pair.primary) == true {
                    perPage[from]?[page]?.removeAll { $0 == pair.other }
                    if perPage[from]?[page]?.isEmpty == true { perPage[from]?[page] = nil }
                    perPage[to]?[page]?.append(pair.other)
                }
            }
            for (topic, pages) in perPage {
                for (page, codes) in pages {
                    units.append(ClickUpUnit(topic: topic, kind: .page(page), name: pageName(page),
                                             severity: worst(codes), codes: sorted(codes), pages: [page]))
                }
            }
            }

            let order = Dictionary(uniqueKeysWithValues: ClickUpTopic.allCases.enumerated().map { ($1, $0) })
            return units.sorted { a, b in
                if a.topic != b.topic { return order[a.topic]! < order[b.topic]! }
                if a.severity != b.severity { return a.severity < b.severity }
                if a.count != b.count { return a.count > b.count }
                return a.name < b.name
            }
        }
    }

    /// A Shopify store's pages, each in the list for its kind of page with its issues as subtasks.
    /// An issue the theme makes, on most pages of a template, becomes a subtask of one task for the
    /// template instead, and so does a speed problem Lighthouse measured on a template's page.
    /// Collection copies of products are left out: the product-card task stands for them.
    private static func shopifyPages(db: Database, byCode: [String: [Int64]], claimed: Set<String>,
                                     copies: Set<Int64>, topics: Set<ClickUpTopic>, severities: Set<IssueSeverity>,
                                     urls: inout URLLookup, site: String) throws -> [ClickUpUnit] {
        func lookup(_ code: String) -> IssueDefinition? { IssueCatalogue.definition(for: code) }
        func severity(_ code: String) -> IssueSeverity { lookup(code)?.severity ?? .notice }
        func title(_ code: String) -> String { ClickUpUnitBuilder.title(code) }
        let pageTopics: Set<ClickUpTopic> = [.errors, .warnings, .notices, .products, .speed]

        // Every issue a page has of its own, at any severity, so a page with only issues left out
        // of this export isn't mistaken for one that's clean.
        var perPage: [Int64: Set<String>] = [:]
        for (code, ids) in byCode where !claimed.contains(code) {
            guard let definition = lookup(code), pageTopics.contains(ClickUpTopic.topic(for: definition)) else { continue }
            for id in ids where !copies.contains(id) { perPage[id, default: []].insert(code) }
        }
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

        var units: [ClickUpUnit] = []
        for (template, issues) in moved {
            let topic = ClickUpTopic.list(for: ShopifyProfile.Template(rawValue: template))
            guard topics.contains(topic) else { continue }
            let all = ordered(issues.keys)
            let chosen = all.filter { severities.contains(severity($0)) }
            var pagesOf: [String: [Int64]] = [:]
            for code in chosen { pagesOf[code] = try byInlinks(issues[code] ?? []) }
            let subtasks = Self.subtasks(for: chosen, pages: { pagesOf[$0] ?? [] }, severity: severity)
            units.append(ClickUpUnit(topic: topic, kind: .template(template), name: "\(template) template",
                                     severity: severity((chosen.isEmpty ? all : chosen)[0]), codes: chosen,
                                     pages: try byInlinks(issues.values.joined()), subtasks: subtasks, heldOpen: chosen.isEmpty))
        }
        func own(_ page: Int64) -> Set<String> {
            let template = templateOf[page] ?? measured[page]
            return (perPage[page] ?? []).filter { code in !(template.flatMap { moved[$0]?[code] }?.contains(page) ?? false) }
        }

        // The pages of a paginated collection or blog (?page=2, ?page=9…) are one task with the
        // first: page 9 of a collection is the same template and settings as page 1, and its own
        // task would repeat page 1's issues once for every page.
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
            let topic = ClickUpTopic.list(for: ShopifyProfile.template(of: entry.address, ignoringQuery: true))
            guard topics.contains(topic) else { continue }
            let all = ordered(codesOn.keys)
            let chosen = all.filter { severities.contains(severity($0)) }
            let pages = entry.members.filter { member in codesOn.values.contains { $0.contains(member) } }
            units.append(ClickUpUnit(topic: topic, kind: .page(entry.id), name: ClickUpExporter.pageName(for: entry.address, site: site),
                                     severity: severity((chosen.isEmpty ? all : chosen)[0]), codes: chosen, pages: pages,
                                     subtasks: Self.subtasks(for: chosen, pages: { codesOn[$0] ?? [] }, severity: severity),
                                     heldOpen: chosen.isEmpty))
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

    /// The task's description, without the footer that carries the crawl's name.
    static func markdown(for unit: ClickUpUnit, store: CrawlStore, rows: Int) throws -> String {
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let origin = URL(string: config.startURL).flatMap { url in url.scheme.map { "\($0)://\(url.host() ?? "")" } } ?? ""
        let shown = unit.pages.prefix(rows)
        let pageRows = try store.rows(ids: Array(shown))
        func link(_ url: String) -> String {
            "[\(ClickUpExporter.cell(ClickUpExporter.pageName(for: url, site: site)))](\(ClickUpExporter.linkTarget(url)))"
        }
        func heading(_ count: Int, _ what: String) -> String {
            "**\(what)**" + (count > shown.count ? " — the first \(shown.count.formatted()) of \(count.formatted()), all in the attached CSV" : "")
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
            parts.append("**[\(ClickUpExporter.cell(IssueEvidenceBuilder.shorten(target.url, site: origin)))](\(ClickUpExporter.linkTarget(target.url)))** answers \(status). "
                + "Linked from \(unit.pages.count.formatted()) \(unit.pages.count == 1 ? "page" : "pages").")
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
                    WHERE l.target_id = ? GROUP BY s.id
                    """, arguments: [id])
            }
            var where_: [Int64: (text: String, position: LinkPosition)] = [:]
            for row in places { where_[row[0]] = (row[1], LinkFlags(rawValue: row[2]).position) }
            if let lead = themeLead(where_.values.map(\.position), total: unit.pages.count) { parts.append(lead) }
            if !unit.pages.isEmpty {
                parts.append(([heading(unit.pages.count, "Linked from"), "", "| Page | Link text | Where |", "|---|---|---|"]
                    + pageRows.map { row in
                        let place = where_[row.id]
                        return "| \(link(row.url)) | \(ClickUpExporter.cell(place?.text ?? "")) | \(place.map { $0.position == .unknown ? "" : $0.position.label } ?? "") |"
                    }).joined(separator: "\n"))
            }

        case .image(let id):
            guard let image = try store.row(id: id) else { break }
            var lead = "**[\(ClickUpExporter.cell(IssueEvidenceBuilder.shorten(image.url, site: origin)))](\(ClickUpExporter.linkTarget(image.url)))** "
                + "is on \(unit.pages.count.formatted()) \(unit.pages.count == 1 ? "page" : "pages") with an issue."
            if unit.members.count > 1 {
                lead += " It's one file, served at \(unit.members.count) sizes: its alt text and weight are set once, for all of them."
            }
            parts.append(lead)
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
                    let alt = place.map { $0.text.isEmpty ? "—" : ClickUpExporter.cell(truncated($0.text, 120)) } ?? ""
                    return "| \(link(row.url)) | \(alt) | \(place.map { $0.position == .unknown ? "" : $0.position.label } ?? "") |"
                }).joined(separator: "\n"))

        case .link(let code, let target, let text):
            let address = try store.row(id: target)?.url ?? ""
            let anchor = text.isEmpty ? "The link" : "“\(text)”"
            parts.append("**\(anchor) → [\(ClickUpExporter.cell(IssueEvidenceBuilder.shorten(address, site: origin)))](\(ClickUpExporter.linkTarget(address)))** "
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
            parts.append(try ClickUpExporter.urlTable(code: code, ids: unit.pages, site: site, store: store, rows: rows))

        case .cluster(let code, let value):
            guard let definition = IssueCatalogue.definition(for: code) else { break }
            let what = switch code {
            case "title_duplicate": "share the title “\(value ?? "")”"
            case "meta_description_duplicate": "share the meta description “\(value ?? "")”"
            case "h1_duplicate": "share the H1 “\(value ?? "")”"
            case "content_exact_duplicate": "have exactly the same content"
            default: "have very similar content"
            }
            parts.append("**\(unit.pages.count.formatted()) pages \(what).**")
            let advice = unit.pages.first.flatMap { try? fix(code, page: $0) }
            parts.append("\(definition.description)\n\n**How to fix:** \(advice ?? definition.howToFix)")
            parts.append(plainTable("Pages"))

        case .template(let template) where !unit.subtasks.isEmpty:
            let kind = template.lowercased()
            parts.append("**These issues are on most \(kind) pages**, so they come from the theme's \(kind) template rather "
                + "than each page: fix them there, once, and every page clears. Each is a subtask listing its pages.")
            parts.append(unit.subtasks.map { "- \($0.name) — on \($0.pages.count.formatted()) \($0.pages.count == 1 ? "page" : "pages")" }
                .joined(separator: "\n"))

        case .template(let template):
            parts.append("**Measured as the store's \(template) page.** Every \(template.lowercased()) page is built from the theme's "
                + "\(template.lowercased()) template, so fix it there, once.")
            for row in pageRows { parts.append(try pageIssues(row.id, url: row.url, unit: unit, store: store, site: site, heading: true)) }

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

        case .page(let id) where !unit.subtasks.isEmpty:
            guard let row = try store.row(id: id) else { break }
            let address = paginationBase(of: row.url) ?? row.url
            var lead = "**\(link(address))** has \(unit.subtasks.count) \(unit.subtasks.count == 1 ? "issue" : "issues"), "
                + "each a subtask with what's wrong and how to fix it"
            if unit.pages.count > 1 || paginationBase(of: row.url) != nil {
                lead += ". Its later pages (?page=2 and on) are filed here too, since they're built the same way; "
                    + "each subtask says which pages have it"
            }
            parts.append(lead + ":")
            parts.append(unit.subtasks.map { "- \($0.name) — \(label($0.severity))" }.joined(separator: "\n"))

        case .page(let id):
            guard let row = pageRows.first else { break }
            parts.append(try pageIssues(id, url: row.url, unit: unit, store: store, site: site, heading: false))
        }
        return parts.joined(separator: "\n\n")
    }

    /// A subtask's description: the issue on its page, or on every page of a template.
    static func markdown(for subtask: ClickUpSubtask, in unit: ClickUpUnit, store: CrawlStore, rows: Int) throws -> String {
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        guard let first = subtask.pages.first else { return "" }
        if case .template(let template) = unit.kind {
            let shown = try store.rows(ids: Array(subtask.pages.prefix(rows)))
            let evidence = try IssueEvidenceBuilder.evidence(for: subtask.code, urlID: first, store: store)
            var parts = ["**On \(subtask.pages.count.formatted()) \(template.lowercased()) pages**, so it's the theme's \(template.lowercased()) template to fix, once."]
            if let definition = IssueCatalogue.definition(for: subtask.code) { parts.append(definition.description) }
            for other in subtask.also { parts.append("Also flagged as *\(title(other))*: the same problem, measured another way.") }
            if !evidence.items.isEmpty {
                parts.append("**On \(ClickUpExporter.pageName(for: shown.first?.url ?? "", site: site)), for example**"
                    + evidence.items.prefix(5).map { "\n- \($0.text)" }.joined())
            }
            parts.append("**How to fix:** \(evidence.fix)")
            let more = subtask.pages.count > shown.count
                ? " — the first \(shown.count.formatted()) of \(subtask.pages.count.formatted()), all in the attached CSV" : ""
            parts.append((["**Pages**\(more)", "", "| Page |", "|---|"] + shown.map {
                "| [\(ClickUpExporter.cell(ClickUpExporter.pageName(for: $0.url, site: site)))](\(ClickUpExporter.linkTarget($0.url))) |"
            }).joined(separator: "\n"))
            return parts.joined(separator: "\n\n")
        }
        let url = try store.row(id: first)?.url ?? ""
        var single = unit
        single.codes = [subtask.code] + subtask.also
        var text = try pageIssues(first, url: url, unit: single, store: store, site: site, heading: false)
        if subtask.pages.count > 1 {
            let others = try store.rows(ids: Array(subtask.pages.dropFirst().prefix(rows)))
            text += "\n\n**Also on** " + others.map {
                "[\(ClickUpExporter.cell(ClickUpExporter.pageName(for: $0.url, site: site)))](\(ClickUpExporter.linkTarget($0.url)))"
            }.joined(separator: ", ")
            if subtask.pages.count - 1 > others.count { text += " and \((subtask.pages.count - 1 - others.count).formatted()) more" }
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
    private static func pageIssues(_ id: Int64, url: String, unit: ClickUpUnit, store: CrawlStore,
                                   site: String, heading: Bool) throws -> String {
        let link = "[\(ClickUpExporter.cell(ClickUpExporter.pageName(for: url, site: site)))](\(ClickUpExporter.linkTarget(url)))"
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
            // Links in the theme have tasks of their own.
            if unit.topic == .links {
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
