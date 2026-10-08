import CrawlCore
import Foundation
import GRDB
import Synchronization

/// Buffers write operations and commits them in batched transactions.
///
/// `submit` never suspends, so operations submitted from one actor are committed in exactly the
/// order they were submitted. Commits run on a background task every few hundred milliseconds
/// or whenever `flush()` is called.
public final class CrawlWriter: Sendable {
    private let pool: DatabasePool
    private let buffer = Mutex<[WriteOperation]>([])
    private let commitLock = NSLock()
    private let failure = Mutex<(any Error)?>(nil)
    private let autoFlush = Mutex<Task<Void, Never>?>(nil)

    public init(store: CrawlStore) {
        pool = store.pool
    }

    deinit {
        autoFlush.withLock { $0?.cancel() }
    }

    public var pendingCount: Int { buffer.withLock { $0.count } }

    /// The first commit error (e.g. disk full), if any. Once set, the crawl should stop.
    public var lastError: (any Error)? { failure.withLock { $0 } }

    public func submit(_ operation: WriteOperation) {
        buffer.withLock { $0.append(operation) }
    }

    public func submit(contentsOf operations: [WriteOperation]) {
        buffer.withLock { $0.append(contentsOf: operations) }
    }

    public func startAutoFlush(every interval: Duration = .milliseconds(300)) {
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.flushIgnoringErrors()
            }
        }
        autoFlush.withLock { $0?.cancel(); $0 = task }
    }

    public func stopAutoFlush() {
        autoFlush.withLock { $0?.cancel(); $0 = nil }
    }

    /// Commits everything submitted so far. Blocks the calling thread for the duration of the commit.
    public func flush() throws {
        commitLock.lock()
        defer { commitLock.unlock() }
        let operations = buffer.withLock { ops -> [WriteOperation] in
            let taken = ops
            ops.removeAll(keepingCapacity: true)
            return taken
        }
        guard !operations.isEmpty else { return }
        do {
            try pool.write { db in try Self.apply(operations, in: db) }
        } catch {
            failure.withLock { if $0 == nil { $0 = error } }
            throw error
        }
    }

    private func flushIgnoringErrors() {
        try? flush()
    }

    // MARK: - SQL

    private static let crawledColumns = [
        "id", "url", "host", "is_internal", "depth", "state", "found_via", "resource_type", "skip_reason",
        "status_code", "status_text", "error", "blocked_by_robots", "content_type", "size_bytes",
        "response_ms", "ttfb_ms", "redirect_url", "redirect_to_id", "headers", "crawled_at",
        "indexability", "indexability_reason",
        "title", "title_length", "title_pixels", "title_count",
        "meta_description", "meta_description_length", "meta_description_pixels", "meta_description_count",
        "h1", "h1_length", "h1_count", "h1_second", "h2", "h2_count",
        "canonical", "canonical_id", "canonical_count", "meta_robots", "x_robots_tag", "lang",
        "word_count", "content_hash", "outlinks", "external_outlinks", "hreflang_count", "structured_data_count",
        "js_rendered", "raw_word_count", "raw_link_count", "rendered_link_count", "render_ms", "simhash",
    ]

    private static let upsertCrawledSQL: String = {
        let placeholders = Array(repeating: "?", count: crawledColumns.count).joined(separator: ", ")
        // Keep the depth/found_via recorded at discovery; everything else comes from the crawl.
        let updates = crawledColumns
            .filter { !["id", "url", "host", "depth", "found_via"].contains($0) }
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        return "INSERT INTO urls (\(crawledColumns.joined(separator: ", "))) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(updates)"
    }()

    static func apply(_ operations: [WriteOperation], in db: Database) throws {
        let discover = try db.cachedStatement(sql: """
            INSERT INTO urls (id, url, host, is_internal, depth, state, found_via, resource_type, skip_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
            """)
        let requeue = try db.cachedStatement(sql: "UPDATE urls SET state = 0, skip_reason = NULL, depth = MIN(depth, ?) WHERE id = ?")
        let upsert = try db.cachedStatement(sql: upsertCrawledSQL)
        let deleteIssues = try db.cachedStatement(sql: "DELETE FROM issues WHERE url_id = ?")
        let insertIssue = try db.cachedStatement(sql: "INSERT OR IGNORE INTO issues (code, url_id) VALUES (?, ?)")
        let insertLink = try db.cachedStatement(sql: "INSERT OR IGNORE INTO links (source_id, target_id, type, flags, text) VALUES (?, ?, ?, ?, ?)")
        let insertHreflang = try db.cachedStatement(sql: "INSERT OR IGNORE INTO hreflang (source_id, lang, target_id) VALUES (?, ?, ?)")
        let deleteProduct = try db.cachedStatement(sql: "DELETE FROM products WHERE url_id = ?")
        let insertProduct = try db.cachedStatement(sql: """
            INSERT INTO products (url_id, name, brand, entities, entities_no_price, entities_no_availability,
                                  variants, with_price, with_availability, with_identifier, with_sku,
                                  low_price, high_price, currency, availability, images, review_count, rating)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let insertStructured = try db.cachedStatement(sql: "INSERT OR REPLACE INTO structured_data (url_id, idx, types, error) VALUES (?, ?, ?, ?)")
        let insertBody = try db.cachedStatement(sql: "INSERT OR REPLACE INTO bodies (url_id, html) VALUES (?, ?)")
        let insertRendered = try db.cachedStatement(sql: "INSERT OR REPLACE INTO rendered_bodies (url_id, html) VALUES (?, ?)")
        let insertScreenshot = try db.cachedStatement(sql: "INSERT OR REPLACE INTO screenshots (url_id, png) VALUES (?, ?)")
        let insertSitemap = try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO sitemaps (url, kind, entry_count, status_code, error) VALUES (?, ?, ?, ?, ?)
            """)
        let insertSitemapURL = try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO sitemap_urls (url, sitemap, last_modified) VALUES (?, ?, ?)
            """)
        let deleteExtractions = try db.cachedStatement(sql: "DELETE FROM extractions WHERE url_id = ?")
        let insertExtraction = try db.cachedStatement(sql: "INSERT OR REPLACE INTO extractions (url_id, name, value) VALUES (?, ?, ?)")
        let deleteSearchHits = try db.cachedStatement(sql: "DELETE FROM search_hits WHERE url_id = ?")
        let insertSearchHit = try db.cachedStatement(sql: "INSERT OR REPLACE INTO search_hits (url_id, name) VALUES (?, ?)")

        for operation in operations {
            switch operation {
            case .discover(let d):
                try discover.execute(arguments: [
                    d.id, d.url, d.host, d.isInternal, d.depth, d.state.rawValue, d.foundVia.rawValue,
                    d.resourceType.rawValue, d.skipReason,
                ])

            case .requeue(let id, let depth):
                try requeue.execute(arguments: [depth, id])

            case .sitemap(let sitemap, let urls):
                try insertSitemap.execute(arguments: [
                    sitemap.url, sitemap.kind, sitemap.entryCount, sitemap.statusCode, sitemap.error,
                ])
                for entry in urls {
                    try insertSitemapURL.execute(arguments: [entry.url, entry.sitemap, entry.lastModified])
                }

            case .crawled(let c, let issues, let links, let hreflang, let structuredData, let html, let renderedHTML, let screenshot):
                let d = c.discovery
                let p = c.page
                let headersJSON = c.headers.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: c.headers, options: [.sortedKeys]))
                    .map { String(decoding: $0, as: UTF8.self) }
                let values: [(any DatabaseValueConvertible)?] = [
                    d.id, d.url, d.host, d.isInternal, d.depth, d.state.rawValue, d.foundVia.rawValue,
                    d.resourceType.rawValue, d.skipReason,
                    c.statusCode, c.statusText, c.error, c.blockedByRobots, c.contentType, c.sizeBytes,
                    c.responseMs, c.ttfbMs, c.redirectURL, c.redirectToID, headersJSON,
                    c.crawledAt.timeIntervalSince1970, c.indexability.rawValue, c.indexabilityReason,
                    p?.title, p?.titleLength, p?.titlePixels, p?.titleCount,
                    p?.metaDescription, p?.metaDescriptionLength, p?.metaDescriptionPixels, p?.metaDescriptionCount,
                    p?.h1, p?.h1Length, p?.h1Count, p?.h1Second, p?.h2, p?.h2Count,
                    p?.canonical, p?.canonicalID, p?.canonicalCount, p?.metaRobots, c.xRobotsTag, p?.lang,
                    p?.wordCount, p.map { Int64(bitPattern: $0.contentHash) }, p?.outlinks, p?.externalOutlinks,
                    p?.hreflangCount, p?.structuredDataCount,
                    p?.javaScriptRendered ?? false, p?.rawWordCount, p?.rawLinkCount, p?.renderedLinkCount, p?.renderMs,
                    p.map { Int64(bitPattern: $0.simhash) },
                ]
                try upsert.execute(arguments: StatementArguments(values))

                if let page = c.page {
                    try deleteExtractions.execute(arguments: [d.id])
                    for (name, value) in page.extractions {
                        try insertExtraction.execute(arguments: [d.id, name, value])
                    }
                    try deleteSearchHits.execute(arguments: [d.id])
                    for name in page.searchHits {
                        try insertSearchHit.execute(arguments: [d.id, name])
                    }
                }
                try deleteIssues.execute(arguments: [d.id])
                for code in issues {
                    try insertIssue.execute(arguments: [code, d.id])
                }
                for link in links {
                    try insertLink.execute(arguments: [link.sourceID, link.targetID, link.type.rawValue, link.flags.rawValue, link.text])
                }
                for entry in hreflang {
                    try insertHreflang.execute(arguments: [d.id, entry.lang, entry.targetID])
                }
                // Replaced on every crawl of the URL, so a product that lost its structured data
                // doesn't keep the old copy.
                try deleteProduct.execute(arguments: [d.id])
                if let product = c.product {
                    try insertProduct.execute(arguments: [
                        d.id, product.name, product.brand, product.entities, product.entitiesNoPrice,
                        product.entitiesNoAvailability, product.variants, product.withPrice, product.withAvailability,
                        product.withIdentifier, product.withSKU, product.lowPrice, product.highPrice, product.currency,
                        product.availabilities.joined(separator: ","), product.images, product.reviewCount, product.rating,
                    ])
                }
                for (index, block) in structuredData.enumerated() {
                    try insertStructured.execute(arguments: [d.id, index, block.types.joined(separator: ", "), block.error])
                }
                if let html {
                    try insertBody.execute(arguments: [d.id, html])
                }
                if let renderedHTML {
                    try insertRendered.execute(arguments: [d.id, renderedHTML])
                }
                if let screenshot {
                    try insertScreenshot.execute(arguments: [d.id, screenshot])
                }
            }
        }
    }
}
