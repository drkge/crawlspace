import CrawlCore
import Foundation
import Hummingbird
import Scheduling
import Storage
import WebAssets

/// Where a running server can be found, written for the next launch (and the CLI) to read.
struct ServerInfo: Codable {
    var port: Int
    var pid: Int32
    var version: String

    static func read() -> ServerInfo? {
        guard let data = try? Data(contentsOf: CrawlspacePaths.server) else { return nil }
        return try? JSONDecoder().decode(ServerInfo.self, from: data)
    }

    func write() throws {
        try CrawlspacePaths.ensure(CrawlspacePaths.support)
        try JSONEncoder().encode(self).write(to: CrawlspacePaths.server, options: .atomic)
    }

    /// The same, for the moment before the app's run loop starts.
    func isAliveNow() -> Bool {
        let result = Locked(false)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.value = await isAlive()
            done.signal()
        }
        done.wait()
        return result.value
    }

    /// True when a Crawlspace server answers on this port.
    func isAlive() async -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// A value shared with a detached task, behind a lock.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// The install's browser token: random, made once, and kept with the other secrets so that tabs
/// stay signed in across restarts and updates.
enum BrowserToken {
    static let account = "server.token"

    static func current() -> String {
        if let token = CredentialStore.password(account: account) { return token }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? CredentialStore.save(password: token, account: account)
        return token
    }
}

public struct ServerOptions: Sendable {
    public var port: Int
    public var openBrowser: Bool
    /// Serve the API only, for the Vite dev server in `Web/` to proxy to.
    public var developmentUI: Bool
    /// A previous copy to wait for before taking the port, when restarting after an update.
    public var afterPID: Int32?

    public init(port: Int = 7777, openBrowser: Bool = true, developmentUI: Bool = false, afterPID: Int32? = nil) {
        self.port = port
        self.openBrowser = openBrowser
        self.developmentUI = developmentUI
        self.afterPID = afterPID
    }
}

/// The server: the library of crawls, the updater, and the HTTP application in front of them.
public final class CrawlspaceServer: Sendable {
    static let devUIOrigin = "http://localhost:5173"

    let options: ServerOptions
    let library: Library
    let updater: Updater
    let token = BrowserToken.current()
    /// The installed app this is running from, or nil for a development build.
    let installedApp: URL?

    public init(options: ServerOptions) {
        self.options = options
        let bundle = Bundle.main.bundleURL
        installedApp = bundle.pathExtension == "app" ? bundle : nil
        // A copy run with CRAWLSPACE_HOME is for development or testing: updating would swap out
        // the app it was started from, and the restart wouldn't keep its folder or port.
        updater = Updater(installedApp: CrawlspacePaths.isCustomHome ? nil : installedApp)
        let updater = updater
        library = Library(onActivityChange: { busy in
            Task { await updater.activityChanged(busy: busy) }
            Task { @MainActor in StatusMenu.shared?.setBusy(busy) }
        })
    }

    /// The address to open: it carries the token once, which the server swaps for a cookie.
    func browserURL(port: Int, path: String = "/") -> URL {
        let base = options.developmentUI ? Self.devUIOrigin : "http://127.0.0.1:\(port)"
        var components = URLComponents(string: "\(base)/auth")!
        components.queryItems = [.init(name: "t", value: token), .init(name: "next", value: path)]
        return components.url!
    }

    /// Runs until the process is told to stop. Picks the port, writes `server.json`, and starts
    /// the background work: the 1.x migration, repairing schedules, and the updater.
    public func run(onReady: @escaping @Sendable (Int) -> Void) async throws {
        if let pid = options.afterPID {
            // The copy being replaced is closing; wait for it to let go of the port.
            for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        let port = Self.freePort(startingAt: options.port)
        try ServerInfo(port: port, pid: getpid(), version: AppVersion.current).write()

        // Scheduled crawls hold the path of the app that made them; if the app has moved, repoint
        // them here. A development copy leaves the real install's jobs alone.
        if !CrawlspacePaths.isCustomHome, let executable = scheduleExecutable {
            Task.detached(priority: .utility) { LaunchAgent.repairInstalledAgents(executable: executable) }
        }
        let library = library
        await updater.configure(
            isBusy: { await library.isBusy() },
            onStateChange: { state in
                library.events.publish("update", state)
                Task { @MainActor in StatusMenu.shared?.updateChanged(state) }
            },
            restart: { [self] in await restartIntoUpdate(port: port) }
        )
        await updater.start()

        let app = Application(
            router: makeRouter(port: port),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: AppIdentity.name),
            onServerRunning: { _ in onReady(port) }
        )
        try await app.runService(gracefulShutdownSignals: [.sigterm, .sigint])
        await library.closeAll()
    }

    /// The binary scheduled crawls run: inside the installed app, whose path survives updates.
    var scheduleExecutable: String? {
        installedApp.map { $0.appending(path: "Contents/MacOS/Crawlspace").path }
            ?? Bundle.main.executableURL?.path
    }

    func makeRouter(port: Int) -> Router<AppContext> {
        let router = Router(context: AppContext.self)
        router.add(middleware: SecurityMiddleware(
            port: port, token: token,
            extraOrigins: options.developmentUI ? [Self.devUIOrigin, "http://127.0.0.1:5173"] : []
        ))
        router.add(middleware: StaticAssetsMiddleware(enabled: !options.developmentUI))

        router.get("auth") { request, _ in
            // Reaching here means the token didn't match; the middleware handles the good case.
            Response(status: .seeOther, headers: [.location: "/"])
        }
        router.post("api/open") { [library] request, context in
            struct Body: Decodable { var path: String }
            let body = try await request.decodeJSON(Body.self, context: context)
            let id = await library.register(externalPackage: URL(filePath: body.path))
            return JSON(["id": id])
        }

        CrawlRoutes(library: library).register(on: router)
        MiscRoutes(library: library, updater: updater, scheduleExecutable: scheduleExecutable ?? "").register(on: router)
        return router
    }

    // MARK: - Ports

    /// The first port from `start` that nothing else is listening on.
    static func freePort(startingAt start: Int) -> Int {
        for port in start..<(start + 20) where canBind(port) { return port }
        return start
    }

    private static func canBind(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        // As the server itself binds: a port left in TIME_WAIT by the copy that just quit (after
        // an update, say) is free to reuse, and the browser's tabs expect the same port.
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // MARK: - Restarting into an update

    /// Starts the newly installed app, which waits for this one to exit, then quits. A watchdog
    /// puts the previous version back if the new one isn't answering within half a minute.
    func restartIntoUpdate(port: Int) async {
        guard let installedApp else { return }
        let previous = Updater.previousFolder.appending(path: AppIdentity.bundleName).path
        let quote = { (path: String) in "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let watchdog = """
            sleep 30
            if ! /usr/bin/curl -fsS --max-time 5 http://127.0.0.1:\(port)/api/health >/dev/null 2>&1; then
              [ -d \(quote(previous)) ] || exit 0
              /bin/rm -rf \(quote(installedApp.path)) && /bin/mv \(quote(previous)) \(quote(installedApp.path))
              /usr/bin/open -n \(quote(installedApp.path)) --args serve --no-open
            fi
            """
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", watchdog]
        try? shell.run()

        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = ["-n", installedApp.path, "--args", "serve", "--no-open", "--after", String(getpid())]
        try? open.run()
        open.waitUntilExit()

        await library.closeAll()
        await MainActor.run { StatusMenu.quitImmediately() }
    }
}

/// Serves the embedded UI. Any path that isn't a file gets `index.html`, so the browser's own
/// routes (`/crawls/…`, `/schedules`) survive a reload.
struct StaticAssetsMiddleware: RouterMiddleware {
    typealias Context = AppContext
    let enabled: Bool

    func handle(_ request: Request, context: AppContext,
                next: (Request, AppContext) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        guard enabled, request.method == .get || request.method == .head,
              !path.hasPrefix("/api/"), path != "/auth" else {
            return try await next(request, context)
        }
        let key = String(path.dropFirst())
        if let file = WebAssets.files[key] {
            // Built assets have content hashes in their names, so they can be cached for good.
            let cache = key.hasPrefix("assets/") ? "public, max-age=31536000, immutable" : "no-cache"
            return Response(status: .ok, headers: [.contentType: file.contentType, .cacheControl: cache],
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: file.data)))
        }
        guard !key.contains("."), let index = WebAssets.files["index.html"] else {
            return Response(status: .notFound)
        }
        return Response(status: .ok, headers: [.contentType: index.contentType, .cacheControl: "no-cache"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: index.data)))
    }
}
