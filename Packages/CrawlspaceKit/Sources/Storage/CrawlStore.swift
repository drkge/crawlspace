import CrawlCore
import Foundation
import GRDB

public enum CrawlStatus: String, Sendable, Codable {
    case new
    case running
    case paused
    /// Stopped by the user before the queue was exhausted; can be resumed.
    case stopped
    case completed
}

/// A crawl on disk: a `.crawlspace` package directory holding a SQLite database in WAL mode.
public final class CrawlStore: Sendable {
    public static let packageExtension = "crawlspace"
    static let databaseName = "crawl.sqlite"

    public let packageURL: URL
    public let pool: DatabasePool

    private init(packageURL: URL, pool: DatabasePool) {
        self.packageURL = packageURL
        self.pool = pool
    }

    public static func create(at packageURL: URL, config: CrawlConfig) throws -> CrawlStore {
        let fm = FileManager.default
        if fm.fileExists(atPath: packageURL.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: packageURL.path])
        }
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let store = try open(at: packageURL)
        try store.saveConfig(config)
        try store.setMeta("status", CrawlStatus.new.rawValue)
        try store.setMeta("created_at", ISO8601DateFormatter().string(from: Date()))
        return store
    }

    public static func open(at packageURL: URL) throws -> CrawlStore {
        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        configuration.prepareDatabase { db in
            try db.execute(sql: """
            PRAGMA synchronous = NORMAL;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -65536;
            PRAGMA mmap_size = 268435456;
            """)
        }
        let path = packageURL.appending(path: databaseName).path
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Schema.migrator().migrate(pool)
        return CrawlStore(packageURL: packageURL, pool: pool)
    }

    /// A fresh package path in `directory`, e.g. `example.com 2026-09-14 15.42.crawlspace`.
    public static func suggestedPackageURL(in directory: URL, for config: CrawlConfig) -> URL {
        let host = CrawlScope(config: config).startHost
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(host.isEmpty ? "crawl" : host) \(formatter.string(from: Date()))"
        return directory.appending(path: name).appendingPathExtension(packageExtension)
    }

    public func close() throws {
        try pool.close()
    }

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    public func loadConfig() throws -> CrawlConfig {
        guard let json = try meta("config") else { return CrawlConfig() }
        var config = try JSONDecoder().decode(CrawlConfig.self, from: Data(json.utf8))
        if let id = try meta("secrets_id") { config.restoreHeaders(account: Self.headersAccount(id)) }
        return config
    }

    /// Saves the config, keeping its cookie and custom headers in the secrets file instead (see
    /// `CrawlConfig.separatingHeaders`), under an ID the package keeps.
    public func saveConfig(_ config: CrawlConfig) throws {
        let id: String
        if let existing = try meta("secrets_id") {
            id = existing
        } else {
            id = UUID().uuidString
            try setMeta("secrets_id", id)
        }
        let stored = try config.separatingHeaders(account: Self.headersAccount(id))
        try setMeta("config", String(decoding: try stored.encodedJSON(), as: UTF8.self))
    }

    static func headersAccount(_ id: String) -> String { "crawl-headers.\(id)" }

    /// Deletes the cookie and headers a package's crawl kept in the secrets file, for when the
    /// package itself is going.
    public static func forgetHeaders(of packageURL: URL) {
        guard let queue = try? DatabaseQueue(path: packageURL.appending(path: databaseName).path),
              let id = try? queue.read({ try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'secrets_id'") })
        else { return }
        try? queue.close()
        CredentialStore.delete(account: headersAccount(id))
    }

    public func status() throws -> CrawlStatus {
        try meta("status").flatMap(CrawlStatus.init(rawValue:)) ?? .new
    }

    public func setStatus(_ status: CrawlStatus) throws {
        try setMeta("status", status.rawValue)
    }
}
