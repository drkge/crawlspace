import CrawlCore
import Foundation

/// A crawl that runs on its own, on a schedule.
public struct ScheduledCrawl: Codable, Sendable, Hashable, Identifiable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily
        case weekly
        case weekdays
        case hourly

        public var label: String {
            switch self {
            case .daily: "Every day"
            case .weekly: "Every week"
            case .weekdays: "Weekdays"
            case .hourly: "Every hour"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var config: CrawlConfig
    public var frequency: Frequency
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday, as launchd counts weekdays.
    public var weekday: Int
    public var isEnabled: Bool
    /// Compare the finished crawl with the previous run of this schedule.
    public var compareWithPrevious: Bool
    public var exportCSV: Bool
    public var exportReport: Bool
    public var lastRun: Date?
    public var lastSummary: String?

    public init(id: UUID = UUID(), name: String = "", config: CrawlConfig = CrawlConfig(),
                frequency: Frequency = .weekly, hour: Int = 3, minute: Int = 0, weekday: Int = 2,
                isEnabled: Bool = true, compareWithPrevious: Bool = true,
                exportCSV: Bool = false, exportReport: Bool = false) {
        self.id = id
        self.name = name
        self.config = config
        self.frequency = frequency
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.isEnabled = isEnabled
        self.compareWithPrevious = compareWithPrevious
        self.exportCSV = exportCSV
        self.exportReport = exportReport
    }

    public var label: String { "\(AppIdentity.bundleID).schedule.\(id.uuidString)" }

    /// Plain-English description of when it runs.
    public var scheduleDescription: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .hourly: return "Every hour, at \(String(format: "%02d", minute)) minutes past"
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly:
            let days = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let name = days.indices.contains(weekday) ? days[weekday] : "Monday"
            return "Every \(name) at \(time)"
        }
    }

    public func validationErrors() -> [String] {
        var errors = config.validationErrors()
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Give the schedule a name.") }
        if !(0...23).contains(hour) || !(0...59).contains(minute) { errors.append("Choose a valid time.") }
        return errors
    }
}

/// Schedules on disk, one JSON file each.
public enum ScheduleStore {
    /// Where schedules live. Overridable so tests don't write into the real one — they did, and
    /// left a schedule of their own behind when a run crashed.
    nonisolated(unsafe) public static var directory: URL = CrawlspacePaths.schedules

    public static func load() -> [ScheduledCrawl] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return decode(data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func load(id: UUID) -> ScheduledCrawl? {
        guard let data = try? Data(contentsOf: file(for: id)) else { return nil }
        return decode(data)
    }

    /// Saves the schedule, its crawl's cookie and custom headers going to the secrets file rather
    /// than the schedule's own (see `CrawlConfig.separatingHeaders`).
    public static func save(_ schedule: ScheduledCrawl) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored = schedule
        stored.config = try schedule.config.separatingHeaders(account: headersAccount(schedule.id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: file(for: schedule.id))
    }

    public static func delete(id: UUID) throws {
        try? FileManager.default.removeItem(at: file(for: id))
        CredentialStore.delete(account: headersAccount(id))
    }

    private static func decode(_ data: Data) -> ScheduledCrawl? {
        guard var schedule = try? JSONDecoder().decode(ScheduledCrawl.self, from: data) else { return nil }
        schedule.config.restoreHeaders(account: headersAccount(schedule.id))
        return schedule
    }

    static func headersAccount(_ id: UUID) -> String { "schedule-headers.\(id.uuidString)" }

    static func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
