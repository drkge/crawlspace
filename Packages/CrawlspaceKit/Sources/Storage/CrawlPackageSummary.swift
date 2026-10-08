import CrawlCore
import Foundation
import GRDB

/// Enough about a crawl on disk to list it: which site, how far it got, how many pages.
public struct CrawlPackageSummary: Sendable, Hashable {
    public var packageURL: URL
    /// The host the crawl started from — what the recent list groups by.
    public var site: String
    public var startURL: String
    public var status: CrawlStatus
    public var crawled: Int
    public var config: CrawlConfig

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.packageURL == rhs.packageURL && lhs.status == rhs.status && lhs.crawled == rhs.crawled
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(packageURL)
    }
}

extension CrawlStore {
    /// Reads a package's summary without migrating it or holding it open, so listing a folder of
    /// crawls stays cheap. Returns nil for anything that isn't a readable crawl.
    public static func summary(of packageURL: URL) -> CrawlPackageSummary? {
        let path = packageURL.appending(path: databaseName).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        guard let queue = try? DatabaseQueue(path: path, configuration: configuration) else { return nil }

        return try? queue.read { db -> CrawlPackageSummary in
            let json = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'config'")
            var config = json.flatMap { try? JSONDecoder().decode(CrawlConfig.self, from: Data($0.utf8)) }
                ?? CrawlConfig()
            if let id = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'secrets_id'") {
                config.restoreHeaders(account: headersAccount(id))
            }
            let status = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'status'")
                .flatMap(CrawlStatus.init(rawValue:)) ?? .new
            let crawled = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM urls WHERE state = 1") ?? 0

            var site = CrawlScope(config: config).startHost
            if site.isEmpty {
                // Fall back to the name the package was given, which starts with the host.
                site = packageURL.deletingPathExtension().lastPathComponent
                    .split(separator: " ").first.map(String.init) ?? "Other"
            }
            return CrawlPackageSummary(packageURL: packageURL, site: site, startURL: config.startURL,
                                       status: status, crawled: crawled, config: config)
        }
    }
}
