import Audit
import CrawlCore
import Foundation
import GRDB
import Storage

/// A site's fixes, kept on this Mac across crawls: every thing to fix the crawls found, marked done
/// as it's made and verified by a crawl that looked again.
///
/// The items are the fixes `FixBuilder` works out — a broken URL and the links to it, an image
/// file, a page and its issues — with where each stands. The crawl page shows them, and ClickUp
/// holds only an overview of them (`ClickUpOverview`).
public final class Worklist: Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Found, and not done yet.
        case open
        /// Marked done here, waiting for a check to verify it.
        case done
        /// Gone from a crawl that looked again.
        case verified
        /// Done or verified, then found again.
        case reopened
    }

    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var id: String { key }
        /// "group|name" for a fix, "group|name|issue" for one issue under it.
        public var key: String
        public var parentKey: String?
        public var group: String
        public var name: String
        /// The name shortened, as the fixes list shows it.
        public var label: String
        public var severity: IssueSeverity
        /// The kind of problem it counts as, as the client summary and ClickUp overview count them.
        public var kind: String
        public var status: Status
        public var firstSeen: String
        public var lastSeen: String
        public var doneAt: Date?
        public var verifiedAt: Date?
        /// The crawl that verified it.
        public var verifiedBy: String?
        public var pageCount: Int
        /// What a quick check crawls to see whether it's fixed; empty for what only a full crawl
        /// or a speed check can tell.
        public var checkURLs: [String]
    }

    /// What an update changed.
    public struct Changes: Sendable, Hashable, Codable {
        public var added = 0
        public var verified = 0
        public var reopened = 0
    }

    public let host: String
    private let queue: DatabaseQueue

    // MARK: - Opening

    public static func fileURL(for host: String) -> URL {
        let safe = host.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return CrawlspacePaths.worklists.appending(path: (safe.isEmpty ? "site" : safe) + ".sqlite")
    }

    public static func exists(for host: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: host).path)
    }

    /// A site's worklist, made if it isn't there yet.
    public static func open(host: String) throws -> Worklist {
        try CrawlspacePaths.ensure(CrawlspacePaths.worklists)
        return try Worklist(host: host, url: fileURL(for: host))
    }

    init(host: String, url: URL) throws {
        self.host = host
        queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS items (
                    key TEXT PRIMARY KEY,
                    parent_key TEXT,
                    topic TEXT NOT NULL,
                    name TEXT NOT NULL,
                    severity INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    first_seen TEXT NOT NULL,
                    last_seen TEXT NOT NULL,
                    last_seen_path TEXT NOT NULL,
                    done_at REAL,
                    verified_at REAL,
                    verified_by TEXT,
                    page_count INTEGER NOT NULL,
                    check_urls TEXT NOT NULL,
                    sort INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS items_on_parent ON items(parent_key);
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
                """)
            // Earlier versions called verified fixes "confirmed" and fixes marked done "ticked".
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(items)").map { $0["name"] as String }
            if columns.contains("confirmed_at") {
                try db.execute(sql: """
                    ALTER TABLE items RENAME COLUMN confirmed_at TO verified_at;
                    ALTER TABLE items RENAME COLUMN confirmed_by TO verified_by;
                    UPDATE items SET status = 'verified' WHERE status = 'confirmed';
                    """)
            }
            if columns.contains("ticked_at") {
                try db.execute(sql: """
                    ALTER TABLE items RENAME COLUMN ticked_at TO done_at;
                    UPDATE items SET status = 'done' WHERE status = 'ticked';
                    """)
            }
            // Patterns were once named "Redirect pattern: …" and "Broken pattern: …". Renaming them
            // in place keeps their status: otherwise the next crawl would verify the old names as gone.
            let patterns = try Row.fetchAll(db, sql: """
                SELECT key, topic, name FROM items WHERE name LIKE 'Redirect pattern: %' OR name LIKE 'Broken pattern: %'
                """)
            for row in patterns {
                let (key, group, name): (String, String, String) = (row[0], row[1], row[2])
                guard let renamed = ChangePatterns.renamed(name) else { continue }
                try Self.rename(key, to: "\(group)|\(renamed)", name: renamed, db: db)
            }
            // A Shopify image was once a fix for each of its two addresses, cdn.shopify.com's and the
            // store's own; now it's one, named by the store's.
            let images = try Row.fetchAll(db, sql: """
                SELECT key, topic, name FROM items WHERE topic = 'images' AND name LIKE 'http%://cdn.shopify.com/s/files/%'
                """)
            for row in images {
                let (key, group, name): (String, String, String) = (row[0], row[1], row[2])
                guard let renamed = FixBuilder.shopifyFile(name) else { continue }
                try Self.rename(key, to: "\(group)|\(renamed)", name: renamed, db: db)
            }
            // Tracking copies of pages and Shopify's sign-in were once filed as fixes. They aren't
            // any more, and a fix that's gone would read as verified, so they go.
            for row in try Row.fetchAll(db, sql: """
                SELECT key, name FROM items
                WHERE parent_key IS NULL AND (name LIKE '%?%' OR name LIKE '%/customer_authentication/%')
                """) {
                let (key, name): (String, String) = (row[0], row[1])
                guard FixBuilder.isLeftOut(name: name) else { continue }
                try db.execute(sql: "DELETE FROM items WHERE key = ? OR parent_key = ?", arguments: [key, key])
            }
        }
    }

    /// Gives a fix the key a later version names it by. Where that fix is already there, the two
    /// are one, and the one less far along is kept: a fix still open isn't hidden by its copy being
    /// done.
    private static func rename(_ key: String, to newKey: String, name: String, db: Database) throws {
        guard key != newKey else { return }
        let rank: [String: Int] = ["open": 0, "reopened": 0, "done": 1, "verified": 2]
        let status = { (key: String) in try String.fetchOne(db, sql: "SELECT status FROM items WHERE key = ?", arguments: [key]) }
        if let existing = try status(newKey) {
            guard let old = try status(key), rank[old, default: 0] < rank[existing, default: 0] else {
                try db.execute(sql: "DELETE FROM items WHERE key = ?", arguments: [key])
                return
            }
            try db.execute(sql: "DELETE FROM items WHERE key = ?", arguments: [newKey])
        }
        try db.execute(sql: "UPDATE items SET key = ?, name = ? WHERE key = ?", arguments: [newKey, name, key])
        try db.execute(sql: "UPDATE items SET key = ? || substr(key, ?), parent_key = ? WHERE parent_key = ?",
                       arguments: [newKey, key.count + 1, newKey, key])
    }

    /// The site a crawl is of, as worklists are kept by.
    public static func host(of config: CrawlConfig) -> String {
        CrawlScope(config: config).startHost
    }

    // MARK: - Reading and marking

    public func items() throws -> [Item] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM items ORDER BY sort").map(Self.item)
        }
    }

    /// The crawl a fix was last seen in, for showing its details.
    public func lastSeenPath(for key: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT last_seen_path FROM items WHERE key = ?", arguments: [key])
        }
    }

    /// Marks fixes done, or not: a fix's issues go with it. Only open and reopened ones can be
    /// marked done; marking one not done puts it back to open.
    public func markDone(_ keys: [String], _ done: Bool) throws {
        try queue.write { db in
            for key in keys {
                let family = try String.fetchAll(db, sql: "SELECT key FROM items WHERE key = ? OR parent_key = ?", arguments: [key, key])
                for member in family {
                    if done {
                        try db.execute(sql: """
                            UPDATE items SET status = 'done', done_at = ? WHERE key = ? AND status IN ('open', 'reopened')
                            """, arguments: [Date().timeIntervalSince1970, member])
                    } else {
                        try db.execute(sql: "UPDATE items SET status = 'open', done_at = NULL WHERE key = ? AND status = 'done'",
                                       arguments: [member])
                    }
                }
            }
        }
    }

    /// The fixes a check looks at: the ones asked for, with their issues, or every one marked done.
    /// Verified ones are left out.
    public func checkKeys(_ keys: [String]? = nil) throws -> [String] {
        let all = try items()
        guard let keys else { return all.filter { $0.status == .done }.map(\.key) }
        let asked = Set(keys)
        return all.filter { (asked.contains($0.key) || $0.parentKey.map(asked.contains) == true) && $0.status != .verified }.map(\.key)
    }

    /// Everything a check of those fixes has to crawl.
    public func checkURLs(for keys: [String]) throws -> [String] {
        let wanted = Set(keys)
        var seen: Set<String> = []
        var urls: [String] = []
        for item in try items() where wanted.contains(item.key) {
            for url in item.checkURLs where seen.insert(url).inserted { urls.append(url) }
        }
        return urls
    }

    /// The meta key a check crawl records the fixes it was for under.
    public static let checkKeysMeta = "check_keys"

    // MARK: - Updating from a crawl

    /// Brings the list up to date with a crawl of the site.
    ///
    /// A full crawl adds what's new, and verifies what has gone: a page's issues when the page was
    /// crawled again, anything else only when
    /// the crawl covered the whole site. A check — a crawl of just the pages behind some fixes —
    /// adds nothing and speaks only for the fixes it was for: one it looked at in full and found
    /// gone is verified, and one it found still there is marked so.
    @discardableResult
    public func update(from store: CrawlStore, isCheck: Bool) throws -> Changes {
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let crawl = store.packageURL.deletingPathExtension().lastPathComponent
        let units = try FixBuilder.units(store: store, severities: Set(IssueSeverity.allCases))
        let rows = try Self.rows(for: units, store: store)
        let found = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        let crawled = Set(try store.rows(ids: store.rowIDs(for: URLListQuery(filter: .internalAll))).map(\.url))
        let crawledNames = Set(crawled.map { FixBuilder.pageName(for: $0, site: site) })
        let wholeSite = try store.status() == .completed && store.crawledCount() < config.maxURLs
        let measured = try store.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lighthouse_reports") ?? 0 } > 0
        let now = Date().timeIntervalSince1970
        var changes = Changes()
        // The fixes a check was for; one made before checks said so was for those marked done.
        let checked: Set<String>? = isCheck
            ? Set(try store.meta(Self.checkKeysMeta).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
                  ?? self.items().filter { $0.status == .done }.map(\.key))
            : nil

        try queue.write { db in
            // Fixes found to be one since they were filed: each takes on the one it's part of.
            for row in rows {
                for alias in row.aliases { try Self.rename(alias, to: row.key, name: row.name, db: db) }
            }
            var existing: [String: Item] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM items") {
                let item = Self.item(row)
                existing[item.key] = item
            }

            // What this crawl found.
            for (index, row) in rows.enumerated() {
                if let item = existing[row.key] {
                    if isCheck {
                        // A check only speaks for the fixes it looked at in full.
                        let covered = checked?.contains(item.key) == true
                            && !item.checkURLs.isEmpty && item.checkURLs.allSatisfy(crawled.contains)
                        // Checked and still there, whatever it was marked.
                        if covered, item.status != .reopened {
                            try db.execute(sql: "UPDATE items SET status = 'reopened', verified_at = NULL, verified_by = NULL WHERE key = ?",
                                           arguments: [row.key])
                            changes.reopened += 1
                        }
                        continue
                    }
                    let status: Status = item.status == .verified ? .reopened : item.status
                    if status == .reopened, item.status == .verified { changes.reopened += 1 }
                    try db.execute(sql: """
                        UPDATE items SET parent_key = ?, topic = ?, name = ?, severity = ?, kind = ?, status = ?, last_seen = ?,
                          last_seen_path = ?, page_count = ?, check_urls = ?, sort = ?,
                          verified_at = CASE WHEN ? = 'reopened' THEN NULL ELSE verified_at END,
                          verified_by = CASE WHEN ? = 'reopened' THEN NULL ELSE verified_by END
                        WHERE key = ?
                        """, arguments: [row.parentKey, row.group, row.name, row.severity.rawValue, row.kind, status.rawValue, crawl,
                                         store.packageURL.path, row.pageCount, Self.json(row.checkURLs), index,
                                         status.rawValue, status.rawValue, row.key])
                } else if !isCheck {
                    try db.execute(sql: """
                        INSERT INTO items (key, parent_key, topic, name, severity, kind, status, first_seen, last_seen, last_seen_path,
                          page_count, check_urls, sort) VALUES (?, ?, ?, ?, ?, ?, 'open', ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.key, row.parentKey, row.group, row.name, row.severity.rawValue, row.kind, crawl, crawl,
                                         store.packageURL.path, row.pageCount, Self.json(row.checkURLs), index])
                    changes.added += 1
                }
            }

            // What it didn't find.
            for item in existing.values where found[item.key] == nil && item.status != .verified {
                let speed = item.kind.hasPrefix("lh_")
                let fixed: Bool
                if isCheck {
                    fixed = checked?.contains(item.key) == true && !item.checkURLs.isEmpty && item.checkURLs.allSatisfy(crawled.contains)
                } else if speed {
                    // Speed is measured after the crawl, so it counts only once there are results.
                    fixed = measured && wholeSite
                } else if Self.isPage(item) {
                    fixed = crawledNames.contains(item.parentKey.map(Self.name(of:)) ?? item.name)
                } else {
                    fixed = wholeSite
                }
                guard fixed else { continue }
                try db.execute(sql: "UPDATE items SET status = 'verified', verified_at = ?, verified_by = ? WHERE key = ?",
                               arguments: [now, crawl, item.key])
                changes.verified += 1
            }
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('updated', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [crawl])
        }
        return changes
    }

    /// A fix that's one page, whose page being crawled again is enough to say it's gone.
    private static func isPage(_ item: Item) -> Bool {
        let name = item.parentKey.map(Self.name(of:)) ?? item.name
        return name.hasPrefix("/") && !name.hasSuffix(" template")
    }

    /// The name part of a "group|name" key.
    private static func name(of key: String) -> String {
        key.split(separator: "|", maxSplits: 1).dropFirst().first.map(String.init) ?? key
    }

    // MARK: - Rows from units

    struct Found: Sendable {
        var key: String
        var parentKey: String?
        var group: String
        var name: String
        var severity: IssueSeverity
        var kind: String
        var pageCount: Int
        var checkURLs: [String]
        /// Keys its addresses had as fixes of their own, whose status it takes over.
        var aliases: [String] = []
    }

    /// How many pages a check samples for a fix that's one change everywhere.
    static let samplePages = 10

    static func rows(for units: [Fix], store: CrawlStore) throws -> [Found] {
        var ids: Set<Int64> = []
        for unit in units {
            ids.formUnion(unit.pages.prefix(500))
            ids.formUnion(unit.members)
            switch unit.kind {
            case .target(let id), .image(let id), .page(let id): ids.insert(id)
            case .link(_, let target, _): ids.insert(target)
            default: break
            }
        }
        var address: [Int64: String] = [:]
        for row in try store.rows(ids: Array(ids)) { address[row.id] = row.url }
        func urls(_ ids: some Sequence<Int64>) -> [String] { ids.compactMap { address[$0] } }

        var rows: [Found] = []
        for unit in units where !unit.heldOpen || !unit.issues.isEmpty || !unit.codes.isEmpty {
            let key = "\(unit.group.rawValue)|\(unit.name)"
            let sample = Array(unit.pages.prefix(samplePages))
            let speed = unit.codes.allSatisfy { $0.hasPrefix("lh_") }
            let check: [String] = switch unit.kind {
            case .page: urls(unit.pages.prefix(500))
            case .target(let id): urls([id] + unit.members + sample)
            case .link(_, let target, _): urls([target] + sample)
            case .image(let id): urls((unit.members.isEmpty ? [id] : unit.members) + sample)
            case .cluster: urls(unit.pages.prefix(500))
            case .setting, .productCards: urls(sample)
            case .pattern: urls(unit.members.prefix(200) + sample)
            case .template: speed ? [] : urls(sample)
            }
            rows.append(Found(key: key, parentKey: nil, group: unit.group.rawValue, name: unit.name, severity: unit.severity,
                              kind: ClientSummaryBuilder.kindCode(of: unit), pageCount: unit.pages.count,
                              checkURLs: speed ? [] : check, aliases: unit.aliases.map { "\(unit.group.rawValue)|\($0)" }))
            for issue in unit.issues {
                let speed = issue.code.hasPrefix("lh_")
                let pages: [String] = if case .template = unit.kind { urls(issue.pages.prefix(samplePages)) } else { urls(issue.pages) }
                rows.append(Found(key: "\(key)|\(issue.name)", parentKey: key, group: unit.group.rawValue, name: issue.name,
                                  severity: issue.severity, kind: ClientSummaryBuilder.kindCode(for: issue.code),
                                  pageCount: issue.pages.count, checkURLs: speed ? [] : pages))
            }
        }
        return rows
    }

    // MARK: - Details

    /// A fix's description, from the crawl it was last seen in: what's wrong where and how to fix
    /// it.
    public func details(for key: String) throws -> String {
        guard let path = try lastSeenPath(for: key) else { return "" }
        let units = try Self.cache.units(at: path)
        let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let unit = units.first(where: { $0.group.rawValue == parts[0] && $0.name == parts[1] })
                ?? units.first(where: { $0.group.rawValue == parts[0] && $0.aliases.contains(parts[1]) }) else {
            return "Not in \(URL(filePath: path).deletingPathExtension().lastPathComponent) any more."
        }
        let store = try CrawlStore.open(at: URL(filePath: path))
        if parts.count == 3, let issue = unit.issues.first(where: { $0.name == parts[2] }) {
            return try FixBuilder.markdown(for: issue, in: unit, store: store, rows: 50)
        }
        return try FixBuilder.markdown(for: unit, store: store, rows: 50)
    }

    /// The units of the crawl last asked about, so opening one fix after another doesn't work them
    /// all out again each time.
    private static let cache = UnitCache()

    private final class UnitCache: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?
        private var units: [Fix] = []

        func units(at path: String) throws -> [Fix] {
            lock.lock()
            defer { lock.unlock() }
            if self.path == path { return units }
            let store = try CrawlStore.open(at: URL(filePath: path))
            units = try FixBuilder.units(store: store, severities: Set(IssueSeverity.allCases))
            self.path = path
            return units
        }
    }

    // MARK: - Rows

    private static func item(_ row: Row) -> Item {
        let checks: String = row["check_urls"]
        let done: Double? = row["done_at"]
        let verified: Double? = row["verified_at"]
        return Item(key: row["key"], parentKey: row["parent_key"], group: row["topic"], name: row["name"],
                    label: FixBuilder.label(group: row["topic"], name: row["name"]),
                    severity: IssueSeverity(rawValue: row["severity"]) ?? .notice, kind: row["kind"],
                    status: Status(rawValue: row["status"]) ?? .open, firstSeen: row["first_seen"], lastSeen: row["last_seen"],
                    doneAt: done.map(Date.init(timeIntervalSince1970:)),
                    verifiedAt: verified.map(Date.init(timeIntervalSince1970:)), verifiedBy: row["verified_by"],
                    pageCount: row["page_count"],
                    checkURLs: (try? JSONDecoder().decode([String].self, from: Data(checks.utf8))) ?? [])
    }

    private static func json(_ urls: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(urls), as: UTF8.self)) ?? "[]"
    }
}
