import CrawlCore
import Foundation
import GRDB
import Storage

/// Finds pages whose text is almost the same as another page's.
///
/// Comparing every pair would be quadratic, so pages are bucketed by 16-bit bands of their
/// SimHash fingerprint — near-duplicates always share at least one band — and only pages inside a
/// bucket are compared. Buckets, pages and pairs are all capped so a huge crawl can't stall here.
enum NearDuplicateAnalyzer {
    static let maxDistance = 6  // ≈ 90% similar or better
    static let maxPages = 200_000
    static let maxBucketSize = 500
    static let maxPairs = 200_000

    static func run(_ db: Database, indexableHTML: String) throws {
        try db.execute(sql: "DELETE FROM near_duplicates")

        var pages: [(id: Int64, hash: UInt64, content: Int64)] = []
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT id, simhash, content_hash FROM urls
            WHERE \(indexableHTML) AND word_count >= 50 AND simhash IS NOT NULL AND simhash != 0
            """)
        while let row = try cursor.next() {
            pages.append((row[0], UInt64(bitPattern: row[1]), row[2] ?? 0))
        }
        guard pages.count > 1, pages.count <= maxPages else { return }

        var buckets: [UInt64: [Int]] = [:]
        for (index, page) in pages.enumerated() {
            for (band, value) in SimHash.bands(page.hash).enumerated() {
                buckets[UInt64(band) << 16 | value, default: []].append(index)
            }
        }

        let insertPair = try db.cachedStatement(sql: """
            INSERT OR IGNORE INTO near_duplicates (url_id, other_id, similarity) VALUES (?, ?, ?)
            """)
        let insertIssue = try db.cachedStatement(sql: "INSERT OR IGNORE INTO issues (code, url_id) VALUES (?, ?)")
        var seenPairs = Set<Int64>()
        var pairCount = 0

        for members in buckets.values where members.count > 1 && members.count <= maxBucketSize {
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    guard pairCount < maxPairs else { return }
                    let a = pages[members[i]], b = pages[members[j]]
                    // Identical text is already reported as an exact duplicate.
                    guard a.content != b.content else { continue }
                    guard SimHash.hammingDistance(a.hash, b.hash) <= maxDistance else { continue }

                    let low = min(a.id, b.id), high = max(a.id, b.id)
                    guard seenPairs.insert(low &* 1_000_003 &+ high).inserted else { continue }

                    let similarity = SimHash.similarity(a.hash, b.hash)
                    try insertPair.execute(arguments: [a.id, b.id, similarity])
                    try insertPair.execute(arguments: [b.id, a.id, similarity])
                    try insertIssue.execute(arguments: ["content_near_duplicate", a.id])
                    try insertIssue.execute(arguments: ["content_near_duplicate", b.id])
                    pairCount += 1
                }
            }
        }
    }
}
