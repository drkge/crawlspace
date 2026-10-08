import CrawlCore
import Foundation
import GRDB
import Storage

/// Cross-page analysis run once the crawl finishes (or on demand): duplicates, link targets,
/// canonical and hreflang targets, inlink counts and redirect chains.
public enum PostCrawlAnalyzer {
    public static func run(store: CrawlStore) throws {
        let config = try store.loadConfig()
        try store.pool.write { db in
            let codes = IssueCatalogue.postCrawlCodes
            let placeholders = Array(repeating: "?", count: codes.count).joined(separator: ",")
            try db.execute(sql: "DELETE FROM issues WHERE code IN (\(placeholders))", arguments: StatementArguments(codes))

            try duplicates(db)
            try linkTargets(db)
            if config.ecommerceActive { try ecommerce(db, config: config) }
            try canonicalTargets(db)
            try hreflangTargets(db)
            try inlinkCounts(db)
            try redirectChains(db)
            try sitemapAudit(db)
            try NearDuplicateAnalyzer.run(db, indexableHTML: indexableHTML)
            try speed(db)

            try db.execute(
                sql: "INSERT INTO meta(key, value) VALUES ('analysed_at', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [ISO8601DateFormatter().string(from: Date())]
            )
        }
    }

    private static let indexableHTML = "is_internal = 1 AND state = 1 AND resource_type = 0 AND indexability = 1"

    /// Codes worked out from Lighthouse results, which can arrive after the crawl's own analysis.
    public static let speedCodes = ["lh_low_score", "lh_needs_improvement", "lh_poor_lcp", "lh_poor_cls", "lh_high_tbt"]

    /// Recomputes only the Lighthouse issues, for when new results come in without a full re-analysis.
    public static func runSpeedChecks(store: CrawlStore) throws {
        try store.pool.write { db in
            let placeholders = Array(repeating: "?", count: speedCodes.count).joined(separator: ",")
            try db.execute(sql: "DELETE FROM issues WHERE code IN (\(placeholders))", arguments: StatementArguments(speedCodes))
            try speed(db)
        }
    }

    /// A page is flagged when either device is affected: Google ranks on mobile, but plenty of
    /// clients' customers buy on desktop.
    private static func speed(_ db: Database) throws {
        let rules: [(code: String, condition: (String) -> String)] = [
            ("lh_low_score", { "\($0)score < 50" }),
            ("lh_poor_lcp", { "\($0)lcp_ms > 4000" }),
            ("lh_poor_cls", { "\($0)cls > 0.25" }),
            ("lh_high_tbt", { "\($0)tbt_ms > 600" }),
        ]
        for rule in rules {
            try db.execute(sql: """
                INSERT OR IGNORE INTO issues (code, url_id)
                SELECT ?, id FROM urls WHERE (\(rule.condition("lh_m_"))) OR (\(rule.condition("lh_d_")))
                """, arguments: [rule.code])
        }
        // Amber: neither device is red, and at least one is below green.
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'lh_needs_improvement', id FROM urls
            WHERE (lh_m_score < 90 OR lh_d_score < 90)
              AND COALESCE(lh_m_score, 100) >= 50 AND COALESCE(lh_d_score, 100) >= 50
            """)
    }

    private static func duplicates(_ db: Database) throws {
        for (code, column) in [
            ("title_duplicate", "title"),
            ("meta_description_duplicate", "meta_description"),
            ("h1_duplicate", "h1"),
        ] {
            try db.execute(sql: """
                INSERT OR IGNORE INTO issues (code, url_id)
                SELECT ?, id FROM urls
                WHERE \(indexableHTML) AND \(column) IS NOT NULL AND \(column) != ''
                  AND \(column) IN (
                    SELECT \(column) FROM urls
                    WHERE \(indexableHTML) AND \(column) IS NOT NULL AND \(column) != ''
                    GROUP BY \(column) HAVING COUNT(*) > 1)
                """, arguments: [code])
        }
        // Pages with no words all hash the same; don't call them duplicates of each other.
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'content_exact_duplicate', id FROM urls
            WHERE \(indexableHTML) AND word_count > 0 AND content_hash IN (
                SELECT content_hash FROM urls WHERE \(indexableHTML) AND word_count > 0
                GROUP BY content_hash HAVING COUNT(*) > 1)
            """)
    }

    private static func linkTargets(_ db: Database) throws {
        let followableTypes = [LinkType.anchor, .image, .stylesheet, .script, .iframe, .metaRefresh]
            .map { String($0.rawValue) }.joined(separator: ",")
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT DISTINCT 'links_to_broken_internal', l.source_id FROM links l JOIN urls t ON t.id = l.target_id
            WHERE l.type IN (\(followableTypes)) AND t.is_internal = 1 AND t.state = 1
              AND (t.status_code >= 400 OR (t.status_code IS NULL AND t.blocked_by_robots = 0))
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT DISTINCT 'links_to_redirect_internal', l.source_id FROM links l JOIN urls t ON t.id = l.target_id
            WHERE l.type IN (\(followableTypes)) AND t.is_internal = 1 AND t.state = 1 AND t.status_code BETWEEN 300 AND 399
              AND NOT \(LinkCheck.sqlRedirectByDesign("t"))
            """)
        // Crawls saved before LinkCheck existed filed refusals as broken; move them across, so
        // running the analysis again corrects an old crawl without recrawling it.
        try db.execute(sql: """
            DELETE FROM issues WHERE code = 'response_external_broken'
              AND url_id IN (SELECT t.id FROM urls t WHERE t.is_internal = 0 AND \(LinkCheck.sql("t")))
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'response_external_unverified', t.id FROM urls t
            WHERE t.is_internal = 0 AND t.state = 1 AND \(LinkCheck.sql("t"))
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT DISTINCT 'links_to_broken_external', l.source_id FROM links l JOIN urls t ON t.id = l.target_id
            WHERE l.type IN (\(followableTypes)) AND t.is_internal = 0 AND t.state = 1
              AND (t.status_code >= 400 OR (t.status_code IS NULL AND t.blocked_by_robots = 0))
              AND NOT \(LinkCheck.sql("t"))
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT DISTINCT 'links_to_unverified_external', l.source_id FROM links l JOIN urls t ON t.id = l.target_id
            WHERE l.type IN (\(followableTypes)) AND t.is_internal = 0 AND t.state = 1
              AND \(LinkCheck.sql("t"))
            """)
    }

    // MARK: - E-commerce

    private static func ecommerce(_ db: Database, config: CrawlConfig) throws {
        // The same product under a collection's path, indexable there as well as at /products/x.
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'ecom_product_duplicate_path', id FROM urls
            WHERE is_internal = 1 AND state = 1 AND resource_type = 0 AND status_code = 200 AND indexability = 1
              AND url LIKE '%/collections/%/products/%'
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT DISTINCT 'ecom_links_to_duplicate_product', l.source_id FROM links l JOIN urls t ON t.id = l.target_id
            WHERE l.type = \(LinkType.anchor.rawValue) AND t.is_internal = 1 AND t.state = 1
              AND t.url LIKE '%/collections/%/products/%'
            """)
        try productReachability(db, config: config)
    }

    /// Products nothing links to, and products no collection lists.
    ///
    /// Both rest on the link graph being complete, which it isn't always, so this says nothing
    /// rather than guess: a crawl that stopped or hit its URL limit hasn't seen every link, and one
    /// that only followed the sitemap or a list never followed links at all. And a store whose
    /// collection pages build their product grid with JavaScript shows no product links in the
    /// raw HTML, which would make every product look unlisted.
    private static func productReachability(_ db: Database, config: CrawlConfig) throws {
        guard config.mode == .spider else { return }
        let unvisited = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM urls WHERE state = 0") ?? 0
        guard unvisited == 0 else { return }

        var linkedFromAnywhere: Set<String> = []
        var linkedFromCollection: Set<String> = []
        let links = try Row.fetchCursor(db, sql: """
            SELECT t.url, s.url FROM links l
            JOIN urls t ON t.id = l.target_id JOIN urls s ON s.id = l.source_id
            WHERE l.type = \(LinkType.anchor.rawValue) AND t.is_internal = 1 AND s.state = 1 AND t.url LIKE '%/products/%'
            """)
        while let row = try links.next() {
            let targetURL: String = row[0]
            let sourceURL: String = row[1]
            guard let target = URL(string: targetURL).flatMap(EcommercePaths.product(in:)),
                  let source = URL(string: sourceURL) else { continue }
            // A product's collection-path page linking to its own address doesn't make it reachable.
            if EcommercePaths.product(in: source)?.handle == target.handle { continue }
            linkedFromAnywhere.insert(target.handle)
            if EcommercePaths.isCollection(source) { linkedFromCollection.insert(target.handle) }
        }
        guard !linkedFromCollection.isEmpty else { return }

        let products = try Row.fetchAll(db, sql: """
            SELECT id, url FROM urls
            WHERE is_internal = 1 AND state = 1 AND resource_type = 0 AND status_code = 200 AND indexability = 1
              AND url LIKE '%/products/%'
            """)
        var flagged: [(id: Int64, code: String)] = []
        var checked = 0
        for row in products {
            let id: Int64 = row[0]
            let address: String = row[1]
            guard let product = URL(string: address).flatMap(EcommercePaths.product(in:)), !product.collectionScoped else { continue }
            checked += 1
            if !linkedFromAnywhere.contains(product.handle) {
                flagged.append((id, "ecom_product_orphan"))
            } else if !linkedFromCollection.contains(product.handle) {
                flagged.append((id, "ecom_product_no_collection"))
            }
        }

        // A few products out of place is a finding; most of a catalogue out of place is a sign the
        // crawler can't see the links — a grid built by JavaScript, infinite scroll, a theme that
        // links products some way the parser doesn't read. Better silent than a hundred false alarms.
        if checked >= 10, Double(flagged.count) / Double(checked) > 0.5 {
            try db.execute(sql: """
                INSERT INTO meta(key, value) VALUES ('ecommerce_note', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: ["Left out the checks for products no page or collection links to: \(flagged.count) of \(checked) products would have been flagged, which points to the crawler not seeing the links rather than to a catalogue that isn't linked."])
            return
        }
        for (id, code) in flagged {
            try db.execute(sql: "INSERT OR IGNORE INTO issues (code, url_id) VALUES (?, ?)", arguments: [code, id])
        }
    }

    private static func canonicalTargets(_ db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'canonical_target_non_200', u.id FROM urls u JOIN urls t ON t.id = u.canonical_id
            WHERE u.canonical_id != u.id AND u.state = 1 AND t.state = 1
              AND (t.status_code IS NULL OR t.status_code NOT BETWEEN 200 AND 299)
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'canonical_target_non_indexable', u.id FROM urls u JOIN urls t ON t.id = u.canonical_id
            WHERE u.canonical_id != u.id AND u.state = 1 AND t.state = 1
              AND t.status_code BETWEEN 200 AND 299 AND t.indexability = 2
            """)
    }

    private static func hreflangTargets(_ db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT DISTINCT 'hreflang_non_200_target', h.source_id FROM hreflang h JOIN urls t ON t.id = h.target_id
            WHERE t.state = 1 AND (t.status_code IS NULL OR t.status_code NOT BETWEEN 200 AND 299)
            """)
        // Only check reciprocity where the alternate was crawled and parsed as HTML.
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT DISTINCT 'hreflang_missing_return_links', h.source_id FROM hreflang h JOIN urls t ON t.id = h.target_id
            WHERE h.target_id != h.source_id AND t.state = 1 AND t.is_internal = 1 AND t.resource_type = 0
              AND t.status_code BETWEEN 200 AND 299
              AND NOT EXISTS (SELECT 1 FROM hreflang r WHERE r.source_id = h.target_id AND r.target_id = h.source_id)
            """)
    }

    private static func inlinkCounts(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE urls SET inlinks = 0, unique_inlinks = 0 WHERE inlinks != 0 OR unique_inlinks != 0;
            CREATE TEMP TABLE inlink_totals AS
              SELECT target_id AS id, COUNT(*) AS total, COUNT(DISTINCT source_id) AS uniq
              FROM links WHERE type NOT IN (\(LinkType.canonical.rawValue), \(LinkType.hreflang.rawValue))
              GROUP BY target_id;
            UPDATE urls SET inlinks = t.total, unique_inlinks = t.uniq FROM inlink_totals t WHERE t.id = urls.id;
            DROP TABLE inlink_totals;
            """)
    }

    /// Marks which crawled URLs a sitemap lists, then compares the two sets. Only runs when the
    /// crawl actually read a sitemap.
    private static func sitemapAudit(_ db: Database) throws {
        try db.execute(sql: "UPDATE urls SET in_sitemap = 0 WHERE in_sitemap = 1")
        let listed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sitemap_urls") ?? 0
        guard listed > 0 else { return }

        try db.execute(sql: "UPDATE urls SET in_sitemap = 1 WHERE url IN (SELECT url FROM sitemap_urls)")
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'sitemap_non_200', id FROM urls
            WHERE in_sitemap = 1 AND state = 1 AND (status_code IS NULL OR status_code NOT BETWEEN 200 AND 299)
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'sitemap_non_indexable', id FROM urls
            WHERE in_sitemap = 1 AND state = 1 AND status_code BETWEEN 200 AND 299 AND indexability = 2
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'sitemap_orphan', id FROM urls
            WHERE in_sitemap = 1 AND state = 1 AND status_code BETWEEN 200 AND 299 AND inlinks = 0
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT 'sitemap_missing', id FROM urls
            WHERE in_sitemap = 0 AND \(indexableHTML)
            """)
    }

    private static func redirectChains(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM redirect_chains")

        var next: [Int64: Int64] = [:]
        var info: [Int64: (url: String, status: Int?)] = [:]
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT id, url, status_code, redirect_to_id FROM urls WHERE state = 1
            AND (redirect_to_id IS NOT NULL OR id IN (SELECT redirect_to_id FROM urls WHERE redirect_to_id IS NOT NULL))
            """)
        while let row = try cursor.next() {
            let id: Int64 = row[0]
            info[id] = (row[1], row[2])
            if let target: Int64 = row[3] { next[id] = target }
        }

        let insertChain = try db.cachedStatement(sql: """
            INSERT INTO redirect_chains (start_id, hops, final_id, final_status, is_loop, path) VALUES (?, ?, ?, ?, ?, ?)
            """)
        let insertIssue = try db.cachedStatement(sql: "INSERT OR IGNORE INTO issues (code, url_id) VALUES (?, ?)")

        for start in next.keys {
            var path = [start]
            var seen: Set<Int64> = [start]
            var current = start
            var isLoop = false
            while let target = next[current], path.count <= 25 {
                path.append(target)
                if !seen.insert(target).inserted {
                    isLoop = true
                    break
                }
                current = target
            }
            let hops = path.count - 1
            guard isLoop || hops >= 2 else { continue }
            let finalID = path.last!
            let urls = path.map { info[$0]?.url ?? "#\($0)" }.joined(separator: "\n")
            try insertChain.execute(arguments: [start, hops, isLoop ? nil : finalID, isLoop ? nil : info[finalID]?.status, isLoop, urls])
            try insertIssue.execute(arguments: [isLoop ? "redirect_loop" : "redirect_chain", start])
        }
    }
}
