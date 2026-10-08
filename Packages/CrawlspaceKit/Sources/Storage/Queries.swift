import CrawlCore
import Foundation
import GRDB

/// Which URLs a table shows.
public enum URLFilter: Sendable, Hashable, Codable {
    case all
    case internalAll
    case internalHTML
    case external
    case images
    case cssAndJavaScript
    case notCrawled
    case statusClass(Int)
    case noResponse
    case issue(String)
    case redirectChains
    /// URLs listed in an XML sitemap.
    case inSitemap
    /// URLs where a custom extractor found a value.
    case extraction(String)
    /// URLs matching a custom search.
    case searchHit(String)
    /// URLs with near-duplicate content.
    case nearDuplicates

    public var defaultColumns: [URLColumn] {
        switch self {
        case .internalHTML, .all:
            [.address, .statusCode, .status, .indexability, .indexabilityReason, .title, .titleLength, .titlePixels,
             .metaDescription, .metaDescriptionLength, .h1, .h1Count, .canonical, .metaRobots, .wordCount,
             .depth, .inlinks, .outlinks, .responseMs, .sizeBytes]
        case .internalAll, .statusClass, .noResponse:
            [.address, .contentType, .statusCode, .status, .indexability, .indexabilityReason, .title,
             .depth, .inlinks, .sizeBytes, .responseMs]
        case .external:
            [.address, .contentType, .statusCode, .status, .inlinks, .responseMs]
        case .images:
            [.address, .contentType, .statusCode, .status, .sizeBytes, .inlinks]
        case .cssAndJavaScript:
            [.address, .contentType, .statusCode, .status, .sizeBytes, .inlinks]
        case .notCrawled:
            [.address, .status, .depth, .inlinks]
        case .redirectChains:
            [.address, .statusCode, .status, .redirectURL, .inlinks]
        case .inSitemap:
            [.address, .statusCode, .status, .indexability, .indexabilityReason, .inlinks, .depth]
        case .extraction, .searchHit:
            [.address, .statusCode, .indexability, .title, .wordCount]
        case .nearDuplicates:
            [.address, .statusCode, .indexability, .title, .wordCount, .inlinks]
        case .issue:
            [.address, .statusCode, .status, .indexability, .title, .inlinks]
        }
    }

    fileprivate var whereClause: (sql: String, arguments: StatementArguments) {
        switch self {
        case .all: ("1", [])
        case .internalAll: ("is_internal = 1 AND state = 1", [])
        case .internalHTML: ("is_internal = 1 AND state = 1 AND resource_type = 0", [])
        case .external: ("is_internal = 0 AND state = 1", [])
        case .images: ("resource_type = 1 AND state = 1", [])
        case .cssAndJavaScript: ("resource_type IN (2, 3) AND state = 1", [])
        case .notCrawled: ("state != 1", [])
        case .statusClass(let hundred): ("state = 1 AND status_code BETWEEN ? AND ?", [hundred * 100, hundred * 100 + 99])
        case .noResponse: ("state = 1 AND status_code IS NULL", [])
        case .issue(let code): ("id IN (SELECT url_id FROM issues WHERE code = ?)", [code])
        case .redirectChains: ("id IN (SELECT start_id FROM redirect_chains)", [])
        case .inSitemap: ("in_sitemap = 1", [])
        case .extraction(let name): ("id IN (SELECT url_id FROM extractions WHERE name = ?)", [name])
        case .searchHit(let name): ("id IN (SELECT url_id FROM search_hits WHERE name = ?)", [name])
        case .nearDuplicates: ("id IN (SELECT url_id FROM near_duplicates)", [])
        }
    }
}

public struct URLListQuery: Sendable, Hashable {
    public var filter: URLFilter
    public var search: String
    public var sortColumn: URLColumn?
    public var ascending: Bool

    public init(filter: URLFilter, search: String = "", sortColumn: URLColumn? = nil, ascending: Bool = true) {
        self.filter = filter
        self.search = search
        self.sortColumn = sortColumn
        self.ascending = ascending
    }
}

public struct LinkRow: Sendable, Hashable, Identifiable, Codable {
    public var otherID: Int64
    public var url: String
    public var statusCode: Int?
    public var type: LinkType
    public var flags: LinkFlags
    public var text: String
    public var id: String { "\(otherID)|\(type.rawValue)|\(text)" }
}

public struct StructuredDataRow: Sendable, Hashable, Codable {
    public var types: String
    public var error: String?
}

public struct HreflangRow: Sendable, Hashable, Codable {
    public var lang: String
    public var url: String
    public var statusCode: Int?
}

public struct RedirectChainRow: Sendable, Hashable, Identifiable, Codable {
    public var startID: Int64
    public var startURL: String
    public var hops: Int
    public var finalURL: String?
    public var finalStatus: Int?
    public var isLoop: Bool
    public var path: [String]
    public var id: Int64 { startID }
}

public struct OverviewStats: Sendable, Hashable, Codable {
    public struct Bucket: Sendable, Hashable, Identifiable, Codable {
        public var label: String
        public var count: Int
        public var id: String { label }
    }

    public var totalURLs = 0
    public var crawled = 0
    public var queued = 0
    public var skipped = 0
    public var internalHTML = 0
    public var internalOther = 0
    public var external = 0
    public var indexable = 0
    public var nonIndexable = 0
    public var statusClasses: [Bucket] = []
    public var depths: [Bucket] = []
    public var responseTimes: [Bucket] = []
    public var averageResponseMs: Double?

    public init() {}
}

extension CrawlStore {
    // MARK: - Tables

    /// Ordered IDs of every URL matching the query. The grid keeps this list (8 bytes per row) and
    /// loads visible rows by ID, which keeps scrolling fast at a million rows.
    public func rowIDs(for query: URLListQuery) throws -> [Int64] {
        let (whereSQL, whereArguments) = query.filter.whereClause
        var sql = "SELECT id FROM urls WHERE \(whereSQL)"
        var arguments = whereArguments
        let search = query.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let pattern = "%" + search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            sql += " AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' OR h1 LIKE ? ESCAPE '\\')"
            arguments += [pattern, pattern, pattern]
        }
        if let column = query.sortColumn {
            sql += " ORDER BY \(column.sortExpression) \(query.ascending ? "ASC" : "DESC"), id"
        } else {
            sql += " ORDER BY id \(query.ascending ? "ASC" : "DESC")"
        }
        return try pool.read { db in try Int64.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// Rows for the given IDs, in the same order. Missing IDs are skipped.
    public func rows(ids: [Int64]) throws -> [URLRow] {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in try Self.rows(ids: ids, db: db) }
    }

    static func rows(ids: [Int64], db: Database) throws -> [URLRow] {
        var byID: [Int64: URLRow] = [:]
        byID.reserveCapacity(ids.count)
        for chunk in stride(from: 0, to: ids.count, by: 900) {
            let slice = Array(ids[chunk..<min(chunk + 900, ids.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let cursor = try Row.fetchCursor(
                db,
                sql: "SELECT \(URLRow.selectColumns) FROM urls WHERE id IN (\(placeholders))",
                arguments: StatementArguments(slice)
            )
            while let row = try cursor.next() {
                let parsed = URLRow(row: row)
                byID[parsed.id] = parsed
            }
        }
        return ids.compactMap { byID[$0] }
    }

    public func row(id: Int64) throws -> URLRow? {
        try rows(ids: [id]).first
    }

    public func rowID(forURL url: String) throws -> Int64? {
        try pool.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url = ?", arguments: [url]) }
    }

    public func headers(id: Int64) throws -> [(name: String, value: String)] {
        let json = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT headers FROM urls WHERE id = ?", arguments: [id])
        }
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] else {
            return []
        }
        return object.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
    }

    public func storedHTML(id: Int64) throws -> Data? {
        try pool.read { db in try Data.fetchOne(db, sql: "SELECT html FROM bodies WHERE url_id = ?", arguments: [id]) }
    }

    public func renderedHTML(id: Int64) throws -> Data? {
        try pool.read { db in try Data.fetchOne(db, sql: "SELECT html FROM rendered_bodies WHERE url_id = ?", arguments: [id]) }
    }

    public func screenshot(id: Int64) throws -> Data? {
        try pool.read { db in try Data.fetchOne(db, sql: "SELECT png FROM screenshots WHERE url_id = ?", arguments: [id]) }
    }

    public func sitemaps() throws -> [SitemapRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT url, kind, entry_count, status_code, error FROM sitemaps ORDER BY url")
                .map { SitemapRecord(url: $0[0], kind: $0[1], entryCount: $0[2], statusCode: $0[3], error: $0[4]) }
        }
    }

    /// Extractor values for the given URLs: `[url id: [extractor name: value]]`.
    public func extractionValues(ids: [Int64]) throws -> [Int64: [String: String]] {
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in
            var result: [Int64: [String: String]] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 900) {
                let slice = Array(ids[chunk..<min(chunk + 900, ids.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                let cursor = try Row.fetchCursor(
                    db,
                    sql: "SELECT url_id, name, value FROM extractions WHERE url_id IN (\(placeholders))",
                    arguments: StatementArguments(slice)
                )
                while let row = try cursor.next() {
                    result[row[0], default: [:]][row[1]] = row[2]
                }
            }
            return result
        }
    }

    /// Extractor names that actually produced values, with how many URLs each matched.
    public func extractionCounts() throws -> [(name: String, count: Int)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT name, COUNT(*) FROM extractions GROUP BY name ORDER BY name")
                .map { (name: $0[0], count: $0[1]) }
        }
    }

    public func searchHitCounts() throws -> [(name: String, count: Int)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT name, COUNT(*) FROM search_hits GROUP BY name ORDER BY name")
                .map { (name: $0[0], count: $0[1]) }
        }
    }

    public func nearDuplicates(for id: Int64, limit: Int = 50) throws -> [(url: String, similarity: Double)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.url, d.similarity FROM near_duplicates d JOIN urls u ON u.id = d.other_id
                WHERE d.url_id = ? ORDER BY d.similarity DESC LIMIT ?
                """, arguments: [id, limit])
                .map { (url: $0[0], similarity: $0[1]) }
        }
    }

    /// True when Lighthouse has run on at least one page.
    public func hasLighthouseData() throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM urls WHERE lh_m_score IS NOT NULL OR lh_d_score IS NOT NULL)
                """) ?? false
        }
    }

    public func sitemapURLCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sitemap_urls") ?? 0 }
    }

    // MARK: - Inspector

    public func inlinks(to id: Int64, limit: Int = 5_000) throws -> [LinkRow] {
        try links(sql: """
            SELECT l.source_id, u.url, u.status_code, l.type, l.flags, l.text FROM links l
            JOIN urls u ON u.id = l.source_id WHERE l.target_id = ? ORDER BY u.url LIMIT ?
            """, arguments: [id, limit])
    }

    public func outlinks(from id: Int64, limit: Int = 5_000) throws -> [LinkRow] {
        try links(sql: """
            SELECT l.target_id, u.url, u.status_code, l.type, l.flags, l.text FROM links l
            JOIN urls u ON u.id = l.target_id WHERE l.source_id = ? ORDER BY l.type, u.url LIMIT ?
            """, arguments: [id, limit])
    }

    private func links(sql: String, arguments: StatementArguments) throws -> [LinkRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                LinkRow(
                    otherID: row[0], url: row[1], statusCode: row[2],
                    type: LinkType(rawValue: row[3]) ?? .anchor,
                    flags: LinkFlags(rawValue: row[4]), text: row[5]
                )
            }
        }
    }

    /// The product a page's structured data describes, when it was read.
    public func product(for id: Int64) throws -> ProductData? {
        try pool.read { db in try Self.loadProduct(id: id, db: db) }
    }

    /// For callers already inside a read: GRDB won't nest one read in another.
    public static func loadProduct(id: Int64, db: Database) throws -> ProductData? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM products WHERE url_id = ?", arguments: [id]) else { return nil }
        var product = ProductData()
        product.name = row["name"]
        product.brand = row["brand"]
        product.entities = row["entities"]
        product.entitiesNoPrice = row["entities_no_price"]
        product.entitiesNoAvailability = row["entities_no_availability"]
        product.variants = row["variants"]
        product.withPrice = row["with_price"]
        product.withAvailability = row["with_availability"]
        product.withIdentifier = row["with_identifier"]
        product.withSKU = row["with_sku"]
        product.lowPrice = row["low_price"]
        product.highPrice = row["high_price"]
        product.currency = row["currency"]
        let availability: String = row["availability"] ?? ""
        product.availabilities = availability.split(separator: ",").map(String.init)
        product.images = row["images"]
        product.reviewCount = row["review_count"]
        product.rating = row["rating"]
        return product
    }

    public func issueCodes(for id: Int64) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT code FROM issues WHERE url_id = ?", arguments: [id])
        }
    }

    public func structuredData(for id: Int64) throws -> [StructuredDataRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT types, error FROM structured_data WHERE url_id = ? ORDER BY idx", arguments: [id])
                .map { StructuredDataRow(types: $0[0], error: $0[1]) }
        }
    }

    public func hreflang(for id: Int64) throws -> [HreflangRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT h.lang, u.url, u.status_code FROM hreflang h JOIN urls u ON u.id = h.target_id
                WHERE h.source_id = ? ORDER BY h.lang
                """, arguments: [id])
                .map { HreflangRow(lang: $0[0], url: $0[1], statusCode: $0[2]) }
        }
    }

    public func redirectChains(limit: Int = 50_000) throws -> [RedirectChainRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.start_id, s.url, r.hops, f.url, r.final_status, r.is_loop, r.path
                FROM redirect_chains r JOIN urls s ON s.id = r.start_id LEFT JOIN urls f ON f.id = r.final_id
                ORDER BY r.hops DESC, s.url LIMIT ?
                """, arguments: [limit])
                .map { row in
                    RedirectChainRow(
                        startID: row[0], startURL: row[1], hops: row[2], finalURL: row[3],
                        finalStatus: row[4], isLoop: row[5],
                        path: (row[6] as String).components(separatedBy: "\n")
                    )
                }
        }
    }

    // MARK: - Counts

    public func issueCounts() throws -> [String: Int] {
        try pool.read { db in
            var counts: [String: Int] = [:]
            let cursor = try Row.fetchCursor(db, sql: "SELECT code, COUNT(*) FROM issues GROUP BY code")
            while let row = try cursor.next() { counts[row[0]] = row[1] }
            return counts
        }
    }

    public func filterCounts() throws -> [URLFilter: Int] {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                  COUNT(*),
                  SUM(is_internal = 1 AND state = 1),
                  SUM(is_internal = 1 AND state = 1 AND resource_type = 0),
                  SUM(is_internal = 0 AND state = 1),
                  SUM(resource_type = 1 AND state = 1),
                  SUM(resource_type IN (2, 3) AND state = 1),
                  SUM(state != 1)
                FROM urls
                """) else { return [:] }
            let chains = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM redirect_chains") ?? 0
            let sitemapURLs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM urls WHERE in_sitemap = 1") ?? 0
            return [
                .all: row[0] ?? 0,
                .internalAll: row[1] ?? 0,
                .internalHTML: row[2] ?? 0,
                .external: row[3] ?? 0,
                .images: row[4] ?? 0,
                .cssAndJavaScript: row[5] ?? 0,
                .notCrawled: row[6] ?? 0,
                .redirectChains: chains,
                .inSitemap: sitemapURLs,
            ]
        }
    }

    public func overview() throws -> OverviewStats {
        try pool.read { db in
            var stats = OverviewStats()
            if let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*), SUM(state = 1), SUM(state = 0), SUM(state = 2),
                  SUM(state = 1 AND is_internal = 1 AND resource_type = 0),
                  SUM(state = 1 AND is_internal = 1 AND resource_type != 0),
                  SUM(state = 1 AND is_internal = 0),
                  SUM(state = 1 AND is_internal = 1 AND resource_type = 0 AND indexability = 1),
                  SUM(state = 1 AND is_internal = 1 AND resource_type = 0 AND indexability = 2),
                  AVG(CASE WHEN state = 1 AND is_internal = 1 THEN response_ms END)
                FROM urls
                """) {
                stats.totalURLs = row[0] ?? 0
                stats.crawled = row[1] ?? 0
                stats.queued = row[2] ?? 0
                stats.skipped = row[3] ?? 0
                stats.internalHTML = row[4] ?? 0
                stats.internalOther = row[5] ?? 0
                stats.external = row[6] ?? 0
                stats.indexable = row[7] ?? 0
                stats.nonIndexable = row[8] ?? 0
                stats.averageResponseMs = row[9]
            }

            if let row = try Row.fetchOne(db, sql: """
                SELECT SUM(status_code BETWEEN 200 AND 299), SUM(status_code BETWEEN 300 AND 399),
                  SUM(status_code BETWEEN 400 AND 499), SUM(status_code >= 500),
                  SUM(status_code IS NULL AND blocked_by_robots = 1),
                  SUM(status_code IS NULL AND blocked_by_robots = 0)
                FROM urls WHERE state = 1 AND is_internal = 1
                """) {
                stats.statusClasses = [
                    .init(label: "2xx", count: row[0] ?? 0),
                    .init(label: "3xx", count: row[1] ?? 0),
                    .init(label: "4xx", count: row[2] ?? 0),
                    .init(label: "5xx", count: row[3] ?? 0),
                    .init(label: "Blocked", count: row[4] ?? 0),
                    .init(label: "No response", count: row[5] ?? 0),
                ]
            }

            stats.depths = try Row.fetchAll(db, sql: """
                SELECT MIN(depth, 10) AS d, COUNT(*) FROM urls
                WHERE state = 1 AND is_internal = 1 AND resource_type = 0 GROUP BY d ORDER BY d
                """).map { row in
                    let depth: Int = row[0]
                    return .init(label: depth >= 10 ? "10+" : String(depth), count: row[1])
                }

            if let row = try Row.fetchOne(db, sql: """
                SELECT SUM(response_ms < 250), SUM(response_ms >= 250 AND response_ms < 500),
                  SUM(response_ms >= 500 AND response_ms < 1000), SUM(response_ms >= 1000 AND response_ms < 2000),
                  SUM(response_ms >= 2000)
                FROM urls WHERE state = 1 AND is_internal = 1 AND resource_type = 0 AND response_ms IS NOT NULL
                """) {
                stats.responseTimes = [
                    .init(label: "< 250 ms", count: row[0] ?? 0),
                    .init(label: "250–500 ms", count: row[1] ?? 0),
                    .init(label: "0.5–1 s", count: row[2] ?? 0),
                    .init(label: "1–2 s", count: row[3] ?? 0),
                    .init(label: "> 2 s", count: row[4] ?? 0),
                ]
            }
            return stats
        }
    }

    /// Queued URLs with IDs above `afterID`, oldest first (used to refill the in-memory frontier).
    public func queuedURLs(afterID: Int64, limit: Int) throws -> [DiscoveredURL] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, url, host, is_internal, depth, found_via, resource_type FROM urls
                WHERE state = 0 AND id > ? ORDER BY id LIMIT ?
                """, arguments: [afterID, limit])
                .map { row in
                    DiscoveredURL(
                        id: row[0], url: row[1], host: row[2], isInternal: row[3], depth: row[4], state: .queued,
                        foundVia: FoundVia(rawValue: row[5]) ?? .link,
                        resourceType: ResourceType(rawValue: row[6]) ?? .page
                    )
                }
        }
    }

    /// Every known URL with its state, for rebuilding the URL index when resuming.
    public func forEachURL(_ body: (Int64, String, URLState) throws -> Void) throws {
        try pool.read { db in
            let cursor = try Row.fetchCursor(db, sql: "SELECT id, url, state FROM urls")
            while let row = try cursor.next() {
                try body(row[0], row[1], URLState(rawValue: row[2]) ?? .queued)
            }
        }
    }

    public func crawledCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM urls WHERE state = 1") ?? 0 }
    }
}
