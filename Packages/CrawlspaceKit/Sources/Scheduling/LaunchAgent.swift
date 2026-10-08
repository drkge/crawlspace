import Foundation

/// Installs schedules as launchd user agents.
///
/// launchd only runs jobs while the Mac is awake and the user is logged in. A job whose time
/// passed while the machine was asleep runs shortly after it wakes, but nothing runs while it's
/// shut down or sleeping — worth saying plainly in the UI.
public enum LaunchAgent {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
    }

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Crawlspace")
    }

    public static func plistURL(for schedule: ScheduledCrawl) -> URL {
        directory.appending(path: "\(schedule.label).plist")
    }

    public static func isInstalled(_ schedule: ScheduledCrawl) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(for: schedule).path)
    }

    /// The launchd job definition. `executable` is the app binary, which runs the crawl headlessly.
    public static func definition(for schedule: ScheduledCrawl, executable: String) -> [String: Any] {
        var intervals: [[String: Int]] = []
        switch schedule.frequency {
        case .hourly:
            intervals = [["Minute": schedule.minute]]
        case .daily:
            intervals = [["Hour": schedule.hour, "Minute": schedule.minute]]
        case .weekly:
            intervals = [["Weekday": schedule.weekday, "Hour": schedule.hour, "Minute": schedule.minute]]
        case .weekdays:
            intervals = (2...6).map { ["Weekday": $0, "Hour": schedule.hour, "Minute": schedule.minute] }
        }

        return [
            "Label": schedule.label,
            "ProgramArguments": [executable, "--run-schedule", schedule.id.uuidString],
            "StartCalendarInterval": intervals,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "StandardOutPath": logDirectory.appending(path: "\(schedule.id.uuidString).log").path,
            "StandardErrorPath": logDirectory.appending(path: "\(schedule.id.uuidString).log").path,
        ]
    }

    /// The binary an installed job would run, or nil when there is no job for this schedule.
    static func installedExecutable(for schedule: ScheduledCrawl) -> String? {
        installedExecutable(atPlist: plistURL(for: schedule))
    }

    static func installedExecutable(atPlist url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    /// Points the installed jobs at this copy of the app.
    ///
    /// A job holds the absolute path of the binary that created it, so moving the app — out of a
    /// build folder into /Applications, say — would leave launchd starting something that is no
    /// longer there, and the schedule would quietly stop running. Returns what was repointed.
    @discardableResult
    public static func repairInstalledAgents(executable: String,
                                             schedules: [ScheduledCrawl] = ScheduleStore.load()) -> [ScheduledCrawl] {
        schedules.filter { schedule in
            // Only jobs that already exist: this repairs schedules, it doesn't resurrect them.
            guard let installed = installedExecutable(for: schedule), installed != executable else { return false }
            return (try? install(schedule, executable: executable)) != nil
        }
    }

    public static func install(_ schedule: ScheduledCrawl, executable: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let url = plistURL(for: schedule)
        let data = try PropertyListSerialization.data(
            fromPropertyList: definition(for: schedule, executable: executable), format: .xml, options: 0
        )
        try data.write(to: url)

        // Replace any existing job, then load the new one.
        let target = "gui/\(getuid())"
        run(["bootout", "\(target)/\(schedule.label)"])
        let result = run(["bootstrap", target, url.path])
        guard result.status == 0 else {
            throw ScheduleError.launchctlFailed(result.output.isEmpty ? "exit code \(result.status)" : result.output)
        }
    }

    public static func uninstall(_ schedule: ScheduledCrawl) {
        run(["bootout", "gui/\(getuid())/\(schedule.label)"])
        try? FileManager.default.removeItem(at: plistURL(for: schedule))
    }

    /// Runs the job now, as launchd would.
    public static func runNow(_ schedule: ScheduledCrawl) throws {
        let result = run(["kickstart", "-k", "gui/\(getuid())/\(schedule.label)"])
        guard result.status == 0 else {
            throw ScheduleError.launchctlFailed(result.output.isEmpty ? "exit code \(result.status)" : result.output)
        }
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public enum ScheduleError: LocalizedError {
        case launchctlFailed(String)
        public var errorDescription: String? {
            switch self {
            case .launchctlFailed(let detail): "launchd wouldn't take the schedule: \(detail)"
            }
        }
    }
}
