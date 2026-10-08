import Audit
import Foundation
import GRDB
import Storage

/// What changed between two crawls of the same site.
public struct CrawlComparison: Sendable, Codable {
    public struct Counts: Sendable, Hashable, Codable {
        public var baselineURLs = 0
        public var currentURLs = 0
        public var added = 0
        public var removed = 0
        public var statusChanged = 0
        public var indexabilityChanged = 0
        public var titleChanged = 0
        public var canonicalChanged = 0
        public var newIssues = 0
        public var fixedIssues = 0
    }

    public struct IssueDelta: Sendable, Hashable, Identifiable, Codable {
        public var code: String
        public var title: String
        public var severity: IssueSeverity
        public var before: Int
        public var after: Int
        public var id: String { code }
        public var change: Int { after - before }
    }

    public struct Change: Sendable, Hashable, Identifiable, Codable {
        public var url: String
        public var before: String?
        public var after: String?
        /// The issue code, when this change is about an issue.
        public var code: String?
        public var id: String { "\(url)|\(code ?? "")|\(before ?? "")|\(after ?? "")" }
    }

    public var baselineName: String
    public var currentName: String
    public var counts = Counts()
    public var issueDeltas: [IssueDelta] = []
    public var added: [Change] = []
    public var removed: [Change] = []
    public var statusChanges: [Change] = []
    public var indexabilityChanges: [Change] = []
    public var titleChanges: [Change] = []
    public var canonicalChanges: [Change] = []
    public var newIssues: [Change] = []
    public var fixedIssues: [Change] = []

    /// A short, readable summary for reports and notifications.
    public var headline: String {
        var parts: [String] = []
        if counts.added > 0 { parts.append("\(counts.added.formatted()) new \(counts.added == 1 ? "URL" : "URLs")") }
        if counts.removed > 0 { parts.append("\(counts.removed.formatted()) gone") }
        if counts.newIssues > 0 { parts.append("\(counts.newIssues.formatted()) new \(counts.newIssues == 1 ? "issue" : "issues")") }
        if counts.fixedIssues > 0 { parts.append("\(counts.fixedIssues.formatted()) fixed") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

/// Compares two crawl packages of the same site.
///
/// The baseline is attached to the current database so SQLite can do the matching; lists are
/// capped so a big change set can't blow up memory, while the counts stay exact.
public enum CrawlComparer {
    public static let listLimit = 10_000

    public static func compare(baseline: URL, current: CrawlStore, limit: Int = listLimit) throws -> CrawlComparison {
        let baselineDatabase = baseline.appending(path: "crawl.sqlite")
        guard FileManager.default.fileExists(atPath: baselineDatabase.path) else {
            throw CompareError.notACrawl(baseline.lastPathComponent)
        }

        var comparison = CrawlComparison(
            baselineName: baseline.deletingPathExtension().lastPathComponent,
            currentName: current.packageURL.deletingPathExtension().lastPathComponent
        )

        try current.pool.write { db in
            try db.execute(sql: "ATTACH DATABASE ? AS baseline", arguments: [baselineDatabase.path])
            defer { try? db.execute(sql: "DETACH DATABASE baseline") }

            // Crawled HTML pages on both sides, matched by URL. Every column needs the alias,
            // since both databases have a urls table.
            func crawled(_ alias: String) -> String {
                ["state = 1", "is_internal = 1", "resource_type = 0"].map { "\(alias).\($0)" }.joined(separator: " AND ")
            }
            comparison.counts.baselineURLs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM baseline.urls b WHERE \(crawled("b"))") ?? 0
            comparison.counts.currentURLs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM main.urls c WHERE \(crawled("c"))") ?? 0

            comparison.added = try changes(db, limit: limit, sql: """
                SELECT c.url, NULL, NULL FROM main.urls c
                LEFT JOIN baseline.urls b ON b.url = c.url AND b.state = 1
                WHERE \(crawled("c")) AND b.url IS NULL
                """)
            comparison.counts.added = try count(db, sql: """
                SELECT COUNT(*) FROM main.urls c LEFT JOIN baseline.urls b ON b.url = c.url AND b.state = 1
                WHERE \(crawled("c")) AND b.url IS NULL
                """)

            comparison.removed = try changes(db, limit: limit, sql: """
                SELECT b.url, NULL, NULL FROM baseline.urls b
                LEFT JOIN main.urls c ON c.url = b.url AND c.state = 1
                WHERE \(crawled("b")) AND c.url IS NULL
                """)
            comparison.counts.removed = try count(db, sql: """
                SELECT COUNT(*) FROM baseline.urls b LEFT JOIN main.urls c ON c.url = b.url AND c.state = 1
                WHERE \(crawled("b")) AND c.url IS NULL
                """)

            // Field-level changes on URLs present in both crawls.
            func fieldChange(_ column: String, cast: String = "") throws -> ([CrawlComparison.Change], Int) {
                let condition = "IFNULL(b.\(column)\(cast), '') != IFNULL(c.\(column)\(cast), '')"
                let list = try changes(db, limit: limit, sql: """
                    SELECT c.url, b.\(column), c.\(column) FROM main.urls c JOIN baseline.urls b ON b.url = c.url
                    WHERE \(crawled("c")) AND b.state = 1 AND \(condition)
                    """)
                let total = try count(db, sql: """
                    SELECT COUNT(*) FROM main.urls c JOIN baseline.urls b ON b.url = c.url
                    WHERE \(crawled("c")) AND b.state = 1 AND \(condition)
                    """)
                return (list, total)
            }

            (comparison.statusChanges, comparison.counts.statusChanged) = try fieldChange("status_code")
            (comparison.indexabilityChanges, comparison.counts.indexabilityChanged) = try fieldChange("indexability_reason")
            (comparison.titleChanges, comparison.counts.titleChanged) = try fieldChange("title")
            (comparison.canonicalChanges, comparison.counts.canonicalChanged) = try fieldChange("canonical")

            // Issue counts per code, on both sides.
            var before: [String: Int] = [:]
            var after: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT code, COUNT(*) FROM baseline.issues GROUP BY code") {
                before[row[0]] = row[1]
            }
            for row in try Row.fetchAll(db, sql: "SELECT code, COUNT(*) FROM main.issues GROUP BY code") {
                after[row[0]] = row[1]
            }
            comparison.issueDeltas = Set(before.keys).union(after.keys)
                .compactMap { code in
                    guard let definition = IssueCatalogue.definition(for: code) else { return nil }
                    return CrawlComparison.IssueDelta(
                        code: code, title: "\(definition.category.rawValue): \(definition.title)",
                        severity: definition.severity, before: before[code] ?? 0, after: after[code] ?? 0
                    )
                }
                .filter { $0.change != 0 }
                .sorted { ($0.severity, -abs($0.change)) < ($1.severity, -abs($1.change)) }

            // Issues that appeared on a URL, and issues that went away.
            comparison.newIssues = try issueChanges(db, limit: limit, appeared: true)
            comparison.counts.newIssues = try count(db, sql: issueChangeSQL(appeared: true, counting: true))
            comparison.fixedIssues = try issueChanges(db, limit: limit, appeared: false)
            comparison.counts.fixedIssues = try count(db, sql: issueChangeSQL(appeared: false, counting: true))
        }
        return comparison
    }

    // MARK: - Helpers

    private static func issueChangeSQL(appeared: Bool, counting: Bool) -> String {
        let select = counting ? "COUNT(*)" : "u.url, i.code, NULL"
        if appeared {
            return """
            SELECT \(select) FROM main.issues i
            JOIN main.urls u ON u.id = i.url_id
            JOIN baseline.urls bu ON bu.url = u.url
            LEFT JOIN baseline.issues bi ON bi.url_id = bu.id AND bi.code = i.code
            WHERE bi.code IS NULL
            """
        }
        return """
        SELECT \(select) FROM baseline.issues i
        JOIN baseline.urls u ON u.id = i.url_id
        JOIN main.urls cu ON cu.url = u.url
        LEFT JOIN main.issues ci ON ci.url_id = cu.id AND ci.code = i.code
        WHERE ci.code IS NULL
        """
    }

    private static func issueChanges(_ db: Database, limit: Int, appeared: Bool) throws -> [CrawlComparison.Change] {
        try Row.fetchAll(db, sql: issueChangeSQL(appeared: appeared, counting: false) + " LIMIT \(limit)")
            .compactMap { row in
                let code: String = row[1]
                guard let definition = IssueCatalogue.definition(for: code) else { return nil }
                return CrawlComparison.Change(
                    url: row[0], before: nil,
                    after: "\(definition.category.rawValue): \(definition.title)", code: code
                )
            }
    }

    private static func changes(_ db: Database, limit: Int, sql: String) throws -> [CrawlComparison.Change] {
        try Row.fetchAll(db, sql: sql + " LIMIT \(limit)").map { row in
            CrawlComparison.Change(url: row[0], before: text(row[1]), after: text(row[2]), code: nil)
        }
    }

    /// Compared fields have different types (status codes are numbers, titles are text), so the
    /// diff shows them all as text.
    private static func text(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null, .blob: nil
        case .int64(let number): String(number)
        case .double(let number): String(number)
        case .string(let string): string
        }
    }

    private static func count(_ db: Database, sql: String) throws -> Int {
        try Int.fetchOne(db, sql: sql) ?? 0
    }

    public enum CompareError: LocalizedError {
        case notACrawl(String)
        public var errorDescription: String? {
            switch self {
            case .notACrawl(let name): "\(name) doesn't look like a Crawlspace crawl."
            }
        }
    }
}

private func < (lhs: (IssueSeverity, Int), rhs: (IssueSeverity, Int)) -> Bool {
    lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
}
