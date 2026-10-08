import CrawlCore
import Crawler
import Foundation
import Hummingbird
import Storage

/// Errors that become an HTTP status and a message the browser can show.
enum ServerError: Error, HTTPResponseError {
    case badRequest(String)
    case notFound(String)
    case conflict(String)
    case unavailable(String)
    case forbidden(String)

    var status: HTTPResponse.Status {
        switch self {
        case .badRequest: .badRequest
        case .notFound: .notFound
        case .conflict: .conflict
        case .unavailable: .serviceUnavailable
        case .forbidden: .forbidden
        }
    }

    var message: String {
        switch self {
        case .badRequest(let message), .notFound(let message), .conflict(let message),
             .unavailable(let message), .forbidden(let message): message
        }
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let body = try JSONEncoder().encode(MessageDTO(message: message))
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: body)))
    }
}

/// Every crawl the browser can see: the packages in the Crawls folder, plus any opened from
/// elsewhere (double-clicked in Finder). Opening one keeps its session alive until the server quits.
actor Library {
    let directory: URL
    /// Library-wide news: the crawl list changed, an update is ready, Lighthouse got set up.
    nonisolated let events = EventHub()
    private var sessions: [String: CrawlSession] = [:]
    /// Packages outside the Crawls folder, by the id they were given.
    private var elsewhere: [String: URL] = [:]
    /// Told whether anything is running, for the menu bar and the updater.
    private let onActivityChange: @Sendable (Bool) -> Void

    init(directory: URL = CrawlspacePaths.crawls, onActivityChange: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.directory = directory
        self.onActivityChange = onActivityChange
    }

    // MARK: - Ids

    /// A crawl in the library is known by its package name; one from elsewhere by a generated id.
    nonisolated static func id(forLibraryPackage url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func packageURL(for id: String) throws -> URL {
        if let url = elsewhere[id] { return url }
        // Names only: nothing that could climb out of the folder.
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."), id != ".." else {
            throw ServerError.notFound("No crawl called \(id).")
        }
        let url = directory.appending(path: "\(id).\(CrawlStore.packageExtension)", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ServerError.notFound("No crawl called \(id).") }
        return url
    }

    /// Makes a package outside the library openable, and returns its id.
    func register(externalPackage url: URL) -> String {
        let standardised = url.standardizedFileURL
        if standardised.deletingLastPathComponent() == directory.standardizedFileURL {
            return Self.id(forLibraryPackage: standardised)
        }
        if let existing = elsewhere.first(where: { $0.value == standardised })?.key { return existing }
        let id = "opened-" + UUID().uuidString.prefix(8).lowercased()
        elsewhere[id] = standardised
        return id
    }

    // MARK: - Sessions

    func session(_ id: String) throws -> CrawlSession {
        if let session = sessions[id] { return session }
        let url = try packageURL(for: id)
        let store = try CrawlStore.open(at: url)
        let session = try CrawlSession(id: id, packageURL: url, store: store) { [weak self] in
            Task { await self?.activityChanged() }
        }
        sessions[id] = session
        return session
    }

    /// Checks the site, creates a package and starts crawling it.
    func create(config: CrawlConfig) async throws -> CrawlSession {
        let errors = config.validationErrors()
        guard errors.isEmpty else { throw ServerError.badRequest(errors.joined(separator: " ")) }
        // A second or so looking at the start page, so a Shopify store starts with its profile.
        let tailored = await PlatformDetector.tailor(config)
        try CrawlspacePaths.ensure(directory)
        let url = CrawlStore.suggestedPackageURL(in: directory, for: tailored)
        _ = try CrawlStore.create(at: url, config: tailored).close()
        let session = try session(Self.id(forLibraryPackage: url))
        try await session.start()
        events.publish("crawls", ["reason": "created"])
        return session
    }

    /// Crawls the same site again with the same settings, into a new package, so the two can be
    /// compared afterwards.
    func rescan(_ id: String) async throws -> CrawlSession {
        if let session = sessions[id], await session.isRunning {
            throw ServerError.conflict("That crawl is still running. Stop it before starting another.")
        }
        let url = try packageURL(for: id)
        guard let summary = CrawlStore.summary(of: url) else {
            throw ServerError.badRequest("Couldn't read the settings from \(id).")
        }
        return try await create(config: summary.config)
    }

    /// Moves a crawl to the Trash, as 1.x did, so a mistake can be undone in Finder.
    func trash(_ id: String) async throws {
        let url = try packageURL(for: id)
        if let session = sessions[id] {
            guard await !session.isBusy else { throw ServerError.conflict("Stop the crawl before moving it to the Trash.") }
            await session.close()
            sessions[id] = nil
        }
        CrawlStore.forgetHeaders(of: url)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        elsewhere[id] = nil
        events.publish("crawls", ["reason": "trashed"])
    }

    func revealInFinder(_ id: String) throws {
        let url = try packageURL(for: id)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-R", url.path]
        try process.run()
    }

    func list() async -> [CrawlListItemDTO] {
        let fileManager = FileManager.default
        var urls = ((try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == CrawlStore.packageExtension }
        urls += elsewhere.values

        var items: [CrawlListItemDTO] = []
        for url in urls {
            let id = elsewhere.first { $0.value == url }?.key ?? Self.id(forLibraryPackage: url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let summary = CrawlStore.summary(of: url)
            let running = await sessions[id]?.isBusy ?? false
            items.append(CrawlListItemDTO(
                id: id, name: url.deletingPathExtension().lastPathComponent,
                site: summary?.site ?? "", startURL: summary?.startURL ?? "",
                status: summary?.status ?? .new, crawled: summary?.crawled ?? 0,
                modified: modified, isRunning: running, readable: summary != nil
            ))
        }
        return items.sorted { $0.modified > $1.modified }
    }

    /// True while any crawl or Lighthouse run is in progress: the updater waits, and quitting asks.
    func isBusy() async -> Bool {
        for session in sessions.values where await session.isBusy { return true }
        return false
    }

    private func activityChanged() async {
        events.publish("crawls", ["reason": "activity"])
        onActivityChange(await isBusy())
    }

    func closeAll() async {
        for session in sessions.values { await session.close() }
        sessions.removeAll()
    }
}
