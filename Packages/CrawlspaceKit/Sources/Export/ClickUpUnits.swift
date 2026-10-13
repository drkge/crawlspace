import Audit
import CrawlCore
import Foundation
import GRDB
import Storage

/// The lists a crawl's issues are filed into. Links, images, site settings, duplicates, speed and
/// products each get a list of their own, because one fix there usually clears many pages; what's
/// left is filed page by page, into a list for each severity.
public enum ClickUpTopic: String, CaseIterable, Codable, Sendable {
    case links, images, siteSettings, duplicates, speed, products, errors, warnings, notices

    public var label: String {
        switch self {
        case .links: "Links"
        case .images: "Images"
        case .siteSettings: "Site settings"
        case .duplicates: "Duplicates"
        case .speed: "Speed"
        case .products: "Products"
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

    /// Lighthouse templates that stand for many pages; home, cart and search are one page each.
    static let sharedTemplates: Set = ["Product", "Collection", "Article", "Blog", "Page"]

    // MARK: - Units

    public static func units(store: CrawlStore, severities: Set<IssueSeverity>,
                             topics: Set<ClickUpTopic> = Set(ClickUpTopic.allCases)) throws -> [ClickUpUnit] {
        let config = try store.loadConfig()
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
            if !cardTargets.isEmpty || !flagged.isEmpty {
                var linkers = Set(flagged)
                for chunk in cardTargets.chunked(900) {
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
                                         counts: ["addresses": cardTargets.count]))
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

            // Images: one task per image, with every page showing it.
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
            for (image, found) in images {
                try urls.load([image], db: db)
                units.append(ClickUpUnit(topic: .images, kind: .image(image), name: shown(image),
                                         severity: worst(Array(found.codes)), codes: sorted(found.codes),
                                         pages: try byInlinks(found.pages), counts: found.counts.mapValues(\.count)))
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
            for (topic, pages) in perPage {
                for (page, codes) in pages {
                    units.append(ClickUpUnit(topic: topic, kind: .page(page), name: pageName(page),
                                             severity: worst(codes), codes: sorted(codes), pages: [page]))
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
            parts.append("**[\(ClickUpExporter.cell(IssueEvidenceBuilder.shorten(image.url, site: origin)))](\(ClickUpExporter.linkTarget(image.url)))** "
                + "is on \(unit.pages.count.formatted()) \(unit.pages.count == 1 ? "page" : "pages") with an issue.")
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
            let places = try store.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT source_id, text, flags FROM links WHERE target_id = ? AND type = ?",
                                 arguments: [id, LinkType.image.rawValue])
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

        case .page(let id):
            guard let row = pageRows.first else { break }
            parts.append(try pageIssues(id, url: row.url, unit: unit, store: store, site: site, heading: false))
        }
        return parts.joined(separator: "\n\n")
    }

    /// A page's issues in a unit: each one's specifics and its fix.
    private static func pageIssues(_ id: Int64, url: String, unit: ClickUpUnit, store: CrawlStore,
                                   site: String, heading: Bool) throws -> String {
        let link = "[\(ClickUpExporter.cell(ClickUpExporter.pageName(for: url, site: site)))](\(ClickUpExporter.linkTarget(url)))"
        let codes = Set(try store.issueCodes(for: id))
        var text = heading ? "### \(link)" : "**\(link)**"
        for code in unit.codes where codes.contains(code) {
            var evidence = try IssueEvidenceBuilder.evidence(for: code, urlID: id, store: store)
            // Links in the theme have tasks of their own.
            if unit.topic == .links {
                evidence.items.removeAll { isTheme(pages: $0.pagesWithSameLink ?? 1, positions: [$0.position ?? .unknown]) }
            }
            text += "\n\n**\(title(code))**"
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
