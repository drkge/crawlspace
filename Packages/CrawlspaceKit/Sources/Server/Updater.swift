import CrawlCore
import CryptoKit
import Foundation
import Lighthouse

/// Keeps this copy of Crawlspace, and the Lighthouse runtime beside it, up to date with the newest
/// GitHub release.
///
/// Every push to main publishes a release with:
/// - `Crawlspace.app.tar.gz`, the app;
/// - `lighthouse-runtime-<version>-<arm64|x64>.tar.gz`, Node and Lighthouse.
///
/// Downloads are made here with URLSession, which doesn't quarantine files, so Gatekeeper never
/// gets involved and the app needs no Developer ID signature. Each download is checked against the
/// SHA-256 GitHub publishes for it before anything is replaced.
///
/// The repository is public, so none of this needs a GitHub account or token.
public actor Updater {
    static let repository = AppIdentity.repository
    static let appAsset = AppIdentity.releaseAsset

    struct State: Codable, Sendable {
        enum Phase: String, Codable, Sendable {
            case idle, checking, downloading, ready, installing, failed, disabled
        }
        var current: String = AppVersion.current
        var latest: String?
        var phase: Phase = .idle
        var message: String?
        var lastChecked: Date?
    }

    private(set) var state = State()
    /// Where the running app lives, or nil when running a development build outside an app bundle.
    private let installedApp: URL?
    private let session: URLSession
    private var staged: URL?
    private var isBusy: @Sendable () async -> Bool = { false }
    private var onStateChange: @Sendable (State) -> Void = { _ in }
    private var restart: @Sendable () async -> Void = {}
    private var loop: Task<Void, Never>?

    init(installedApp: URL?) {
        self.installedApp = installedApp
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        session = URLSession(configuration: configuration)
        if installedApp == nil {
            state.phase = .disabled
            state.message = "This is a development build, so it doesn't update itself."
        }
    }

    func configure(isBusy: @escaping @Sendable () async -> Bool,
                   onStateChange: @escaping @Sendable (State) -> Void,
                   restart: @escaping @Sendable () async -> Void) {
        self.isBusy = isBusy
        self.onStateChange = onStateChange
        self.restart = restart
    }

    private func set(_ phase: State.Phase, _ message: String? = nil) {
        state.phase = phase
        state.message = message
        onStateChange(state)
    }

    /// Checks on launch, then every half hour.
    func start() {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                await check(userInitiated: false)
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    // MARK: - Checking

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            /// The public download link, which doesn't count against GitHub's API rate limit.
            var browser_download_url: URL
            var digest: String?
            var size: Int
        }
        var tag_name: String
        /// The commit the release was built from.
        var target_commitish: String?
        var assets: [Asset]
    }

    func check(userInitiated: Bool) async {
        guard SettingsStore.load().automaticUpdates || userInitiated else { return }
        guard state.phase != .downloading, state.phase != .installing else { return }
        if state.phase != .ready { set(.checking) }
        do {
            let release = try await latestRelease()
            state.lastChecked = .now
            let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            state.latest = version

            // Lighthouse's runtime first: a fresh install has none. A failure here mustn't hold up
            // the app itself; the next check tries again.
            do {
                try await updateLighthouseRuntime(release: release)
            } catch {
                state.message = "Lighthouse couldn't be set up yet: \(error.localizedDescription)"
            }

            guard installedApp != nil else { set(.disabled, state.message); return }
            let newerCode = await Self.isNewerCode(release.target_commitish, session: session)
            guard newerCode ?? Self.isNewer(version, than: AppVersion.current) else {
                if state.phase != .ready { set(.idle, userInitiated ? "Crawlspace is up to date." : nil) }
                return
            }
            guard staged == nil || state.phase != .ready else {
                try await applyIfIdle(force: false)
                return
            }
            guard let asset = release.assets.first(where: { $0.name == Self.appAsset }) else {
                set(.idle, "Version \(version) has no app download yet.")
                return
            }
            set(.downloading, "Downloading \(version)…")
            staged = try await stage(asset: asset, version: version)
            set(.ready, "Version \(version) is ready. It installs when no crawl is running.")
            try await applyIfIdle(force: false)
        } catch {
            set(.failed, "Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    private func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Crawlspace/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return try JSONDecoder().decode(Release.self, from: data)
        case 404: throw UpdateError.message("There are no releases yet.")
        case 403, 429: throw UpdateError.message("GitHub is limiting how often this network can check. Crawlspace tries again later.")
        default: throw UpdateError.message("GitHub answered \(status).")
        }
    }

    /// Whether a release was built from later code than this copy, asking GitHub to compare the two
    /// commits. Version numbers only say which build ran last: a release of older code can carry a
    /// higher number than a copy built on this Mac, or than a release still waiting to build. Nil
    /// when it can't tell (a development build, or GitHub didn't answer), and versions decide.
    static func isNewerCode(_ releaseCommit: String?, session: URLSession) async -> Bool? {
        guard let releaseCommit, AppVersion.commit != "dev", !AppVersion.commit.isEmpty else { return nil }
        let url = URL(string: "https://api.github.com/repos/\(repository)/compare/\(AppVersion.commit)...\(releaseCommit)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Crawlspace/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let comparison = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = comparison["status"] as? String else { return nil }
        return isNewerCode(comparisonStatus: status)
    }

    /// GitHub's word for the release's commit relative to ours: "ahead" means it has changes this
    /// copy lacks. "diverged" (both have changes the other lacks) only happens with branches, and
    /// installing it would lose ours, so it counts as not newer.
    static func isNewerCode(comparisonStatus: String) -> Bool {
        comparisonStatus == "ahead"
    }

    /// Compares dotted version numbers, so 2.0.10 is newer than 2.0.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let numbers = version.split(separator: ".").map { Int($0) }
            return numbers.contains(nil) || numbers.isEmpty ? nil : numbers.compactMap { $0 }
        }
        guard let a = parts(candidate) else { return false }
        // A development build ("2.0.0-dev") is older than any real release.
        guard let b = parts(current) else { return true }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Downloading

    private func download(_ asset: Release.Asset) async throws -> URL {
        var request = URLRequest(url: asset.browser_download_url)
        request.setValue("Crawlspace/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.message("The download of \(asset.name) failed.")
        }
        do {
            try Self.verify(temporary, digest: asset.digest)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return temporary
    }

    /// Checks a download against GitHub's published SHA-256.
    static func verify(_ file: URL, digest: String?) throws {
        guard let digest, digest.hasPrefix("sha256:") else {
            throw UpdateError.message("GitHub gave no checksum for the download, so it wasn't used.")
        }
        let expected = digest.dropFirst("sha256:".count).lowercased()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw UpdateError.message("The download didn't match its checksum, so it wasn't used.")
        }
    }

    static var updatesFolder: URL { CrawlspacePaths.support.appending(path: "Updates", directoryHint: .isDirectory) }

    /// Unpacks the new app beside the old one and checks its signature is intact.
    private func stage(asset: Release.Asset, version: String) async throws -> URL {
        let archive = try await download(asset)
        defer { try? FileManager.default.removeItem(at: archive) }
        let folder = Self.updatesFolder.appending(path: version, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try CrawlspacePaths.ensure(folder)
        try Self.run("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path])
        let app = folder.appending(path: AppIdentity.bundleName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: app.appending(path: "Contents/MacOS/Crawlspace").path) else {
            throw UpdateError.message("The download didn't contain the app.")
        }
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func updateLighthouseRuntime(release: Release) async throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let prefix = "lighthouse-runtime-"
        let suffix = "-\(architecture).tar.gz"
        guard let asset = release.assets.first(where: { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(suffix) }) else { return }
        let version = String(asset.name.dropFirst(prefix.count).dropLast(suffix.count))
        let needsChrome = LighthouseToolchain.locate() == .missingChrome

        if LighthouseToolchain.installedVersion != version {
            let archive = try await download(asset)
            defer { try? FileManager.default.removeItem(at: archive) }
            try LighthouseToolchain.installRuntime(archive: archive, version: version)
        }
        if needsChrome || LighthouseToolchain.locate() == .missingChrome {
            try await LighthouseToolchain.installHeadlessShell()
        }
    }

    // MARK: - Installing

    /// Swaps the staged app in and restarts, unless a crawl or Lighthouse run would be cut short.
    /// `force` is the user choosing to restart now from the update banner, after a warning.
    func applyIfIdle(force: Bool) async throws {
        guard let staged, let installedApp, state.phase == .ready else {
            if force { throw ServerError.conflict("There's no update ready to install.") }
            return
        }
        if !force, await isBusy() { return }
        set(.installing, "Installing \(state.latest ?? "the update")…")
        do {
            try Self.swap(installed: installedApp, with: staged)
            self.staged = nil
            await restart()
        } catch {
            set(.failed, "Couldn't install the update: \(error.localizedDescription)")
        }
    }

    /// Called whenever crawls start or stop; installs a waiting update once everything is idle.
    func activityChanged(busy: Bool) async {
        guard !busy, state.phase == .ready else { return }
        try? await applyIfIdle(force: false)
    }

    static var previousFolder: URL { CrawlspacePaths.support.appending(path: "Previous", directoryHint: .isDirectory) }

    /// Moves the running app aside, kept for rollback, and the new one into its place. Both moves
    /// are renames within the home folder, so neither leaves a half-copied app behind.
    static func swap(installed: URL, with staged: URL) throws {
        let fileManager = FileManager.default
        try CrawlspacePaths.ensure(previousFolder)
        let previous = previousFolder.appending(path: AppIdentity.bundleName, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: previous)
        try fileManager.moveItem(at: installed, to: previous)
        do {
            try fileManager.moveItem(at: staged, to: installed)
        } catch {
            try? fileManager.moveItem(at: previous, to: installed)
            throw error
        }
        try? fileManager.removeItem(at: staged.deletingLastPathComponent())
    }

    /// Puts the previous version back, for when the new one doesn't start.
    static func rollback(installed: URL) throws {
        let previous = previousFolder.appending(path: AppIdentity.bundleName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: previous, to: installed)
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
            throw UpdateError.message("\(URL(filePath: tool).lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
