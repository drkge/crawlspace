import CrawlCore
import Foundation

/// Finds, and where needed fetches, what Lighthouse runs on: Node, the Lighthouse package and a
/// Chrome.
///
/// Node and Lighthouse arrive as a tarball attached to each GitHub release, unpacked under
/// `Toolchain/<version>` with `Toolchain/current` pointing at the one in use; the updater installs
/// it. Chrome is whatever Chromium browser the Mac already has, or else Chrome for Testing's headless
/// shell, downloaded here. Nothing is installed system-wide and nobody has to set anything up.
///
/// For development, `CRAWLSPACE_NODE`, `CRAWLSPACE_LIGHTHOUSE_CLI` and `CHROME_PATH` point at
/// copies installed elsewhere.
public struct LighthouseToolchain: Sendable, Equatable {
    public var node: URL
    public var cli: URL
    public var chrome: URL
    /// The headless shell needs no `--headless` flag; a full browser does.
    public var chromeIsHeadlessShell: Bool

    public enum Status: Sendable, Equatable {
        case ready(LighthouseToolchain)
        /// Node and Lighthouse haven't been installed yet; the updater fetches them.
        case missingRuntime
        /// No Chromium browser on this Mac and the headless shell isn't downloaded yet.
        case missingChrome

        public var isReady: Bool { if case .ready = self { true } else { false } }
    }

    /// Overridable so each test starts with an empty one.
    nonisolated(unsafe) public static var root: URL = CrawlspacePaths.toolchain
    static var current: URL { root.appending(path: "current", directoryHint: .isDirectory) }
    static var chromeRoot: URL { root.appending(path: "chrome", directoryHint: .isDirectory) }

    /// The version of the runtime in `Toolchain/current`, if any.
    public static var installedVersion: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
    }

    public static func locate() -> Status {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        let node = environment["CRAWLSPACE_NODE"].map { URL(filePath: $0) }
            ?? current.appending(path: "node/bin/node")
        let cli = environment["CRAWLSPACE_LIGHTHOUSE_CLI"].map { URL(filePath: $0) }
            ?? current.appending(path: "lighthouse/node_modules/lighthouse/cli/index.js")
        guard fileManager.isExecutableFile(atPath: node.path), fileManager.fileExists(atPath: cli.path) else {
            return .missingRuntime
        }
        guard let (chrome, isShell) = findChrome(environment: environment) else { return .missingChrome }
        return .ready(LighthouseToolchain(node: node, cli: cli, chrome: chrome, chromeIsHeadlessShell: isShell))
    }

    private static func findChrome(environment: [String: String]) -> (URL, Bool)? {
        let fileManager = FileManager.default
        if let path = environment["CHROME_PATH"], fileManager.isExecutableFile(atPath: path) {
            return (URL(filePath: path), path.hasSuffix("chrome-headless-shell"))
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let browsers = [
            "Google Chrome.app/Contents/MacOS/Google Chrome",
            "Chromium.app/Contents/MacOS/Chromium",
            "Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "Brave Browser.app/Contents/MacOS/Brave Browser",
        ]
        for folder in ["/Applications", "\(home)/Applications"] {
            for browser in browsers where fileManager.isExecutableFile(atPath: "\(folder)/\(browser)") {
                return (URL(filePath: "\(folder)/\(browser)"), false)
            }
        }
        let shell = chromeRoot.appending(path: "current/chrome-headless-shell-\(platform)/chrome-headless-shell")
        if fileManager.isExecutableFile(atPath: shell.path) { return (shell, true) }
        return nil
    }

    static var platform: String {
        #if arch(arm64)
        "mac-arm64"
        #else
        "mac-x64"
        #endif
    }

    // MARK: - Installing

    /// Unpacks a Node + Lighthouse tarball as `version` and makes it current. The previous version
    /// is removed once the new one is in place.
    public static func installRuntime(archive: URL, version: String) throws {
        let fileManager = FileManager.default
        try CrawlspacePaths.ensure(root)
        let destination = root.appending(path: version, directoryHint: .isDirectory)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        guard fileManager.fileExists(atPath: staging.appending(path: "node/bin/node").path),
              fileManager.fileExists(atPath: staging.appending(path: "lighthouse/node_modules/lighthouse/cli/index.js").path)
        else { throw LighthouseError.notInstalled("the downloaded runtime is incomplete") }

        let previous = installedVersion
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        try repoint(current, to: version)
        if let previous, previous != version {
            try? fileManager.removeItem(at: root.appending(path: previous, directoryHint: .isDirectory))
        }
    }

    /// Downloads Chrome for Testing's headless shell, for Macs with no Chromium browser.
    public static func installHeadlessShell() async throws {
        let index = URL(string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json")!
        let (data, _) = try await URLSession.shared.data(from: index)
        let versions = try JSONDecoder().decode(ChromeForTesting.self, from: data)
        guard let stable = versions.channels["Stable"],
              let download = stable.downloads["chrome-headless-shell"]?.first(where: { $0.platform == platform })
        else { throw LighthouseError.notInstalled("Chrome for Testing has no headless shell for \(platform)") }

        let fileManager = FileManager.default
        try CrawlspacePaths.ensure(chromeRoot)
        let (zip, _) = try await URLSession.shared.download(from: download.url)
        defer { try? fileManager.removeItem(at: zip) }
        let destination = chromeRoot.appending(path: stable.version, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: destination)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, destination.path])
        try repoint(chromeRoot.appending(path: "current"), to: stable.version)
    }

    private struct ChromeForTesting: Decodable {
        struct Channel: Decodable {
            var version: String
            var downloads: [String: [Download]]
        }
        struct Download: Decodable {
            var platform: String
            var url: URL
        }
        var channels: [String: Channel]
    }

    /// Points a symlink somewhere new without a moment where it's missing.
    private static func repoint(_ link: URL, to target: String) throws {
        let temporary = link.deletingLastPathComponent().appending(path: ".link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
        guard rename(temporary.path, link.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw LighthouseError.notInstalled("couldn't update \(link.lastPathComponent)")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LighthouseError.notInstalled("\(URL(filePath: tool).lastPathComponent) exited with \(process.terminationStatus)")
        }
    }
}
