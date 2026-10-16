import CrawlCore
import Foundation
import GRDB
import Storage

/// What a page that can't be indexed lists: only why it can't be — its status, a noindex or
/// nofollow, a mistake in its canonical — and what the sitemap says of it.
///
/// A page that's canonicalised elsewhere, redirects, errors or is noindexed doesn't appear in
/// search results, so its titles, descriptions, headings, images and links don't matter there.
/// On a Shopify store that's most pages: every product's /collections/…/products/… copies, which
/// point their canonical at the product's own page and would otherwise repeat each of its issues.
/// Their issues are set aside — kept in the crawl, but out of every list, count, report and export —
/// and the Overview says how many.
public enum IssueVisibility {
    /// Bumped when the rule changes, so crawls opened again are sorted by the new one.
    static let version = "1"

    /// The issues a page that can't be indexed still lists. Not being canonicalised, which is the
    /// reason itself and by design on a store's collection pages, nor slowness, which isn't why.
    public static let shownWhenNonIndexable: Set<String> = Set(IssueCatalogue.all.filter { definition in
        [.responseCodes, .canonicals, .directives, .sitemaps].contains(definition.category)
            && !["response_slow", "canonical_canonicalised"].contains(definition.code)
    }.map(\.code))

    /// Whether an issue found on a URL is set aside: on one of the site's pages that can't be
    /// indexed, and not about why.
    @Sendable public static func setsAside(_ url: CrawledURL, _ code: String) -> Bool {
        url.discovery.isInternal && url.discovery.state == .crawled && url.discovery.resourceType == .page
            && url.indexability == .nonIndexable && !shownWhenNonIndexable.contains(code)
    }

    /// Where an issue found on a URL goes as it's written: ignored by one of the site's rules, set
    /// aside because the page can't be indexed, or listed.
    public static func place(ignoring rules: [IgnoreRule]) -> @Sendable (CrawledURL, String) -> IssuePlace {
        let everywhere = Set(rules.filter { $0.url == nil }.map(\.code))
        let onPages = Set(rules.compactMap { rule in rule.url.map { "\(rule.code) \($0)" } })
        return { url, code in
            if everywhere.contains(code) || onPages.contains("\(code) \(url.discovery.url)") { return .ignored }
            return setsAside(url, code) ? .setAside : .listed
        }
    }

    /// Sorts the crawl's issues by the rules: those ignored that no rule covers now go back, and
    /// those a rule covers are ignored; then those set aside that should show now — the page can
    /// be indexed after all — go back, and those that shouldn't show are set aside.
    public static func apply(_ db: Database) throws {
        let covered = { (alias: String) in
            "EXISTS (SELECT 1 FROM ignore_rules r WHERE r.code = \(alias).code AND (r.url = '' OR r.url = u.url))"
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT g.code, g.url_id FROM issues_ignored g JOIN urls u ON u.id = g.url_id WHERE NOT \(covered("g"))
            """)
        try db.execute(sql: "DELETE FROM issues_ignored WHERE (code, url_id) IN (SELECT code, url_id FROM issues)")
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues_ignored (code, url_id)
            SELECT i.code, i.url_id FROM issues i JOIN urls u ON u.id = i.url_id WHERE \(covered("i"))
            """)
        try db.execute(sql: "DELETE FROM issues WHERE (code, url_id) IN (SELECT code, url_id FROM issues_ignored)")

        let shown = shownWhenNonIndexable.sorted().map { "'\($0)'" }.joined(separator: ",")
        let hidden = """
            u.is_internal = 1 AND u.state = \(URLState.crawled.rawValue) AND u.resource_type = \(ResourceType.page.rawValue) \
            AND u.indexability = \(Indexability.nonIndexable.rawValue)
            """
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues (code, url_id)
            SELECT s.code, s.url_id FROM issues_set_aside s JOIN urls u ON u.id = s.url_id
            WHERE NOT (\(hidden) AND s.code NOT IN (\(shown)))
            """)
        try db.execute(sql: "DELETE FROM issues_set_aside WHERE (code, url_id) IN (SELECT code, url_id FROM issues)")
        try db.execute(sql: """
            INSERT OR IGNORE INTO issues_set_aside (code, url_id)
            SELECT i.code, i.url_id FROM issues i JOIN urls u ON u.id = i.url_id
            WHERE \(hidden) AND i.code NOT IN (\(shown))
            """)
        try db.execute(sql: "DELETE FROM issues WHERE (code, url_id) IN (SELECT code, url_id FROM issues_set_aside)")
        try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('issues_set_aside', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [version])
    }

    /// Sorts a crawl saved before the rule, or under an earlier one; nothing to do otherwise.
    public static func apply(store: CrawlStore) throws {
        guard try store.meta("issues_set_aside") != version else { return }
        try store.pool.write { db in try apply(db) }
    }

    /// Takes the site's ignore rules into the crawl and sorts its issues by them; nothing to do
    /// when the crawl already has these rules.
    public static func ignore(_ rules: [IgnoreRule], store: CrawlStore) throws {
        guard Set(try store.ignoreRules()) != Set(rules) else { return }
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM ignore_rules")
            for rule in Set(rules) {
                try db.execute(sql: "INSERT OR IGNORE INTO ignore_rules (code, url) VALUES (?, ?)", arguments: [rule.code, rule.url ?? ""])
            }
            try apply(db)
        }
    }
}
