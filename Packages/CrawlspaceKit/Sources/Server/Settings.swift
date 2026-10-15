import Audit
import CrawlCore
import Export
import Foundation
import Storage

/// Preferences that aren't secret, in `settings.json`. Secrets go through `CredentialStore`.
public struct Settings: Codable, Sendable, Equatable {
    /// Where each site's overview goes in ClickUp, by the site's host: a space and a list per group.
    public var clickUpDestinations: [String: ClickUpDestination] = [:]
    /// What the export files: "error", "warning", "notice", "lighthouse", "sitemap".
    public var clickUpGroups: [String] = ["error", "warning"]
    /// Check GitHub for new versions. Off only for development copies.
    public var automaticUpdates = true
    /// Who client summaries say they were prepared by, and the logo they carry: the same on every one.
    public var reportPreparedBy = ""
    /// A PNG or JPEG, base64-encoded.
    public var reportLogo: String?

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        clickUpDestinations = try c.decodeIfPresent([String: ClickUpDestination].self, forKey: .clickUpDestinations) ?? [:]
        clickUpGroups = try c.decodeIfPresent([String].self, forKey: .clickUpGroups)
            ?? decoder.container(keyedBy: Earlier.self).decodeIfPresent([String].self, forKey: .clickUpSeverities)
            ?? d.clickUpGroups
        automaticUpdates = try c.decodeIfPresent(Bool.self, forKey: .automaticUpdates) ?? d.automaticUpdates
        reportPreparedBy = try c.decodeIfPresent(String.self, forKey: .reportPreparedBy) ?? d.reportPreparedBy
        reportLogo = try c.decodeIfPresent(String.self, forKey: .reportLogo)
    }

    /// Who a crawl's site belongs to, for its client summary: the name its home page gives it, the
    /// name its ClickUp space was given, or failing those its domain.
    public static func clientName(store: CrawlStore, settings: Settings = SettingsStore.load()) -> String {
        if let name = try? ClientSummaryBuilder.clientName(store: store) { return name }
        guard let config = try? store.loadConfig() else { return "" }
        let host = CrawlScope(config: config).startHost
        if let space = settings.clickUpDestinations[host]?.spaceName, !space.isEmpty { return space }
        let label = host.replacing(/^www\./, with: "").split(separator: ".").first.map(String.init) ?? host
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Names saved before Lighthouse and Sitemap were groups of their own.
    private enum Earlier: String, CodingKey { case clickUpSeverities }

    static func groups(_ names: [String]) -> Set<IssueGroup> {
        Set(IssueGroup.allCases.filter { names.contains($0.rawValue) })
    }
}

/// Reads and writes `settings.json`.
public enum SettingsStore {
    nonisolated(unsafe) public static var fileURL: URL = CrawlspacePaths.settings
    private static let lock = NSLock()

    public static func load() -> Settings {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL),
                  let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
            return settings
        }
    }

    public static func save(_ settings: Settings) throws {
        try lock.withLock { try write(settings) }
    }

    public static func update(_ change: (inout Settings) -> Void) throws -> Settings {
        var settings = load()
        change(&settings)
        try save(settings)
        return settings
    }

    private static func write(_ settings: Settings) throws {
        try CrawlspacePaths.ensure(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}
