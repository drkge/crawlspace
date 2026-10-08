import Audit
import CrawlCore
import Export
import Foundation

/// Preferences that aren't secret, in `settings.json`. Secrets go through `CredentialStore`.
public struct Settings: Codable, Sendable, Equatable {
    /// Where each site's issues go in ClickUp, by the site's host: a space and a folder in it.
    public var clickUpDestinations: [String: ClickUpDestination] = [:]
    public var clickUpSeverities: [String] = ["error", "warning"]
    /// Severities filed as one task with a table rather than a subtask per page.
    public var clickUpTableSeverities: [String] = ["notice"]
    /// 0 files every affected page as a subtask.
    public var clickUpSubtaskLimit = 0
    /// Check GitHub for new versions. Off only for development copies.
    public var automaticUpdates = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        clickUpDestinations = try c.decodeIfPresent([String: ClickUpDestination].self, forKey: .clickUpDestinations) ?? [:]
        clickUpSeverities = try c.decodeIfPresent([String].self, forKey: .clickUpSeverities) ?? d.clickUpSeverities
        clickUpTableSeverities = try c.decodeIfPresent([String].self, forKey: .clickUpTableSeverities) ?? d.clickUpTableSeverities
        clickUpSubtaskLimit = try c.decodeIfPresent(Int.self, forKey: .clickUpSubtaskLimit) ?? d.clickUpSubtaskLimit
        automaticUpdates = try c.decodeIfPresent(Bool.self, forKey: .automaticUpdates) ?? d.automaticUpdates
    }

    static func severities(_ names: [String]) -> Set<IssueSeverity> {
        Set(IssueSeverity.allCases.filter { names.contains($0.name) })
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
