import CrawlCore
import Foundation
import GRDB

extension CrawlStore {
    /// Records one Lighthouse run. A failed run clears that device's numbers, so a page that has
    /// started failing doesn't keep showing a score from before.
    public func saveLighthouse(urlID: Int64, device: LighthouseDevice, metrics: LighthouseMetrics,
                               opportunities: [LighthouseOpportunity], reportHTML: Data?,
                               error: String?, template: String? = nil, ranAt: Date = .now) throws {
        let prefix = device.columnPrefix
        let opportunitiesJSON = try String(decoding: JSONEncoder().encode(opportunities), as: UTF8.self)
        let compressed = try reportHTML.map { try ($0 as NSData).compressed(using: .zlib) as Data }
        try pool.write { db in
            try db.execute(sql: """
                UPDATE urls SET \(prefix)score = ?, \(prefix)lcp_ms = ?, \(prefix)cls = ?, \(prefix)tbt_ms = ?,
                                \(prefix)fcp_ms = ?, \(prefix)si_ms = ?
                WHERE id = ?
                """, arguments: [metrics.score, metrics.lcpMs, metrics.cls, metrics.tbtMs,
                                 metrics.fcpMs, metrics.speedIndexMs, urlID])
            try db.execute(sql: """
                INSERT INTO lighthouse_reports (url_id, device, opportunities, report_html, error, ran_at, template)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(url_id, device) DO UPDATE SET
                    opportunities = excluded.opportunities, report_html = excluded.report_html,
                    error = excluded.error, ran_at = excluded.ran_at, template = excluded.template
                """, arguments: [urlID, device.rawValue, opportunitiesJSON, compressed, error,
                                 ranAt.timeIntervalSince1970, template])
        }
    }

    /// Both devices' runs for a page, mobile first. Empty until Lighthouse has run on it.
    public func lighthouseRuns(urlID: Int64) throws -> [LighthouseRun] {
        guard let row = try row(id: urlID) else { return [] }
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT device, opportunities, error, ran_at, report_html IS NOT NULL, template
                FROM lighthouse_reports WHERE url_id = ?
                """, arguments: [urlID])
                .compactMap { record -> LighthouseRun? in
                    guard let device = LighthouseDevice(rawValue: record[0]) else { return nil }
                    let json: String? = record[1]
                    let opportunities = json.flatMap {
                        try? JSONDecoder().decode([LighthouseOpportunity].self, from: Data($0.utf8))
                    } ?? []
                    return LighthouseRun(device: device, metrics: row.lighthouse(device),
                                         opportunities: opportunities, error: record[2],
                                         ranAt: Date(timeIntervalSince1970: record[3]), hasReport: record[4],
                                         template: record[5])
                }
                .sorted { $0.device == .mobile && $1.device == .desktop }
        }
    }

    /// The full Lighthouse HTML report for one page and device.
    public func lighthouseReportHTML(urlID: Int64, device: LighthouseDevice) throws -> Data? {
        let blob = try pool.read { db in
            try Data.fetchOne(db, sql: "SELECT report_html FROM lighthouse_reports WHERE url_id = ? AND device = ?",
                              arguments: [urlID, device.rawValue])
        }
        return try blob.map { try ($0 as NSData).decompressed(using: .zlib) as Data }
    }

    /// Every page Lighthouse has measured: Shopify templates in the order they were measured, then the
    /// rest most-linked first.
    public func lighthouseMeasuredPages() throws -> [LighthouseMeasuredPage] {
        let ids = try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.url_id, MAX(r.template) FROM lighthouse_reports r JOIN urls u ON u.id = r.url_id
                GROUP BY r.url_id ORDER BY MAX(r.template) IS NULL, MIN(r.ran_at), u.unique_inlinks DESC
                """).map { (id: $0[0] as Int64, template: $0[1] as String?) }
        }
        let rows = Dictionary(uniqueKeysWithValues: try rows(ids: ids.map(\.id)).map { ($0.id, $0) })
        return ids.compactMap { entry in
            rows[entry.id].map {
                LighthouseMeasuredPage(id: $0.id, url: $0.url, template: entry.template,
                                       mobile: $0.lighthouseMobile, desktop: $0.lighthouseDesktop)
            }
        }
    }

    /// The row for a page to measure that the crawl didn't fetch, such as a Shopify store's cart or
    /// search, which robots.txt keeps crawlers out of. It's listed under Not Crawled, saying why.
    public func lighthouseRowID(forURL url: String, host: String) throws -> Int64 {
        if let id = try rowID(forURL: url) { return id }
        return try pool.write { db in
            let id = (try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM urls") ?? 0) + 1
            try db.execute(sql: """
                INSERT INTO urls (id, url, host, is_internal, depth, state, found_via, resource_type, skip_reason)
                VALUES (?, ?, ?, 1, 1, ?, ?, ?, 'Not crawled; measured by Lighthouse only')
                """, arguments: [id, url, host, URLState.skipped.rawValue, FoundVia.link.rawValue, ResourceType.page.rawValue])
            return id
        }
    }

    /// Crawled internal HTML pages that answered 200, most linked-to first: what the Shopify
    /// template picker chooses from.
    public func measurablePages(limit: Int = 20_000) throws -> [(id: Int64, url: String, depth: Int)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, url, depth FROM urls
                WHERE is_internal = 1 AND state = 1 AND resource_type = 0 AND status_code = 200
                ORDER BY depth = 0 DESC, unique_inlinks DESC, inlinks DESC, depth, id
                LIMIT ?
                """, arguments: [limit])
                .map { (id: $0[0], url: $0[1], depth: $0[2]) }
        }
    }

    /// Product names from the store's structured data, for a search that returns something.
    public func productNames(limit: Int = 500) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM products WHERE name IS NOT NULL AND name != '' LIMIT ?",
                                arguments: [limit])
        }
    }

    /// The pages worth measuring first: internal, indexable HTML that answered 200, most linked-to
    /// first, with the start page always included.
    public func lighthouseCandidates(limit: Int) throws -> [(id: Int64, url: String)] {
        guard limit > 0 else { return [] }
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, url FROM urls
                WHERE is_internal = 1 AND state = 1 AND resource_type = 0 AND indexability = 1
                  AND status_code = 200
                ORDER BY depth = 0 DESC, unique_inlinks DESC, inlinks DESC, depth, id
                LIMIT ?
                """, arguments: [limit])
                .map { (id: $0[0], url: $0[1]) }
        }
    }
}
