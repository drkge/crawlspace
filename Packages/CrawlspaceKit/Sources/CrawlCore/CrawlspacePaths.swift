import Foundation

/// Where the app keeps its files: `~/Library/Application Support/Crawlspace`.
///
/// `CRAWLSPACE_HOME` moves the whole lot elsewhere, which keeps development runs out of the real
/// one. Tests always get a throwaway folder of their own.
///
/// Only this account can open the folder (0700), and the app creates everything in it readable by
/// this account alone: see `makePrivate()`.
public enum CrawlspacePaths {
    /// True when `CRAWLSPACE_HOME` points somewhere else, or this is a test run: a copy that leaves
    /// the real install's launchd jobs alone.
    public static var isCustomHome: Bool {
        !(ProcessInfo.processInfo.environment["CRAWLSPACE_HOME"] ?? "").isEmpty || isTestRun
    }

    /// `swift test` runs the tests from an `.xctest` bundle, named in the test runner's arguments.
    static let isTestRun = ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest/") || $0.hasSuffix(".xctest") }

    public static let support: URL = {
        if let home = ProcessInfo.processInfo.environment["CRAWLSPACE_HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory)
        }
        if isTestRun {
            return FileManager.default.temporaryDirectory.appending(path: "crawlspace-tests-\(getpid())", directoryHint: .isDirectory)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: AppIdentity.name, directoryHint: .isDirectory)
    }()

    public static var crawls: URL { support.appending(path: "Crawls", directoryHint: .isDirectory) }
    public static var schedules: URL { support.appending(path: "Schedules", directoryHint: .isDirectory) }
    public static var toolchain: URL { support.appending(path: "Toolchain", directoryHint: .isDirectory) }
    public static var secrets: URL { support.appending(path: "secrets.json") }
    public static var settings: URL { support.appending(path: "settings.json") }
    public static var server: URL { support.appending(path: "server.json") }

    /// For the app and scheduled runs: from here on every file and folder the process creates is
    /// readable by this account only (umask 077), and the support folder is closed to everyone
    /// else, including copies made before this was done.
    public static func makePrivate() {
        umask(0o077)
        _ = try? ensure(support)
        chmod(support.path, 0o700)
    }

    /// Creates the folder if needed and returns it.
    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
