import AppKit
import CrawlCore
import Foundation
import Scheduling
import Storage
import UserNotifications

/// The menu-bar icon: the one sign that Crawlspace is running, and the way to open it, update it
/// and quit it.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static var shared: StatusMenu?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
    private let server: CrawlspaceServer
    private let port: Int
    private var isBusy = false
    private var updateReady = false

    init(server: CrawlspaceServer, port: Int) {
        self.server = server
        self.port = port
        super.init()
        item.button?.image = NSImage(systemSymbolName: "ant", accessibilityDescription: AppIdentity.name)
        item.button?.toolTip = "\(AppIdentity.name) \(AppVersion.current)"

        let open = NSMenuItem(title: "Open \(AppIdentity.name)", action: #selector(openBrowser), keyEquivalent: "o")
        open.target = self
        statusLine.isEnabled = false
        updateItem.target = self
        let version = NSMenuItem(title: "Version \(AppVersion.current)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        let quit = NSMenuItem(title: "Quit \(AppIdentity.name)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        for entry in [open, .separator(), statusLine, .separator(), version, updateItem, .separator(), quit] {
            menu.addItem(entry)
        }
        item.menu = menu
    }

    @objc func openBrowser() {
        open(path: "/")
    }

    func open(path: String) {
        NSWorkspace.shared.open(server.browserURL(port: port, path: path))
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        statusLine.title = busy ? "Crawling…" : (updateReady ? "Update ready" : "Ready")
        item.button?.image = NSImage(systemSymbolName: busy ? "ant.fill" : "ant", accessibilityDescription: AppIdentity.name)
    }

    func updateChanged(_ state: Updater.State) {
        updateReady = state.phase == .ready
        switch state.phase {
        case .ready: updateItem.title = "Restart to Update to \(state.latest ?? "the New Version")"
        case .downloading: updateItem.title = "Downloading Update…"
        case .checking: updateItem.title = "Checking for Updates…"
        case .disabled: updateItem.title = "Updates Off (Development Build)"
        default: updateItem.title = "Check for Updates"
        }
        updateItem.isEnabled = state.phase != .disabled && state.phase != .downloading && state.phase != .installing
        setBusy(isBusy)
    }

    @objc func checkForUpdates() {
        let updater = server.updater
        Task {
            if await updater.state.phase == .ready {
                if isBusy, !confirm("A crawl is running", "Restarting now stops it. It can be resumed afterwards.", "Restart Anyway") {
                    return
                }
                try? await updater.applyIfIdle(force: true)
            } else {
                await updater.check(userInitiated: true)
            }
        }
    }

    @objc func quit() {
        if isBusy, !confirm("A crawl is still running", "Quitting stops it. It can be resumed later from Recent Crawls.", "Quit Anyway") {
            return
        }
        Self.quitImmediately()
    }

    private func confirm(_ title: String, _ message: String, _ button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func quitImmediately() {
        try? FileManager.default.removeItem(at: CrawlspacePaths.server)
        exit(0)
    }
}

/// Receives `.crawlspace` packages double-clicked in Finder.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server: CrawlspaceServer
    /// Packages opened before the server was listening, handed over once it is.
    var pending: [URL] = []
    var isReady = false

    init(server: CrawlspaceServer) {
        self.server = server
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let packages = urls.filter { $0.pathExtension == CrawlStore.packageExtension }
        guard isReady else {
            pending += packages
            return
        }
        for package in packages { openPackage(package) }
    }

    func openPackage(_ url: URL) {
        let library = server.library
        Task {
            let id = await library.register(externalPackage: url)
            let path = "/crawls/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
            StatusMenu.shared?.open(path: path)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Dock, Spotlight, Finder) means "show me Crawlspace".
        StatusMenu.shared?.openBrowser()
        return false
    }
}

/// How the executable runs when it isn't a command-line subcommand.
public enum AppShell {
    /// Starts the server as a menu-bar app, or hands over to the one already running. Call it on
    /// the main thread, outside any async context; it never returns.
    @MainActor
    public static func serve(_ options: ServerOptions) -> Never {
        if options.afterPID == nil, let running = ServerInfo.read(), running.isAliveNow() {
            // Already running: just open the browser at it.
            let server = CrawlspaceServer(options: options)
            NSWorkspace.shared.open(server.browserURL(port: running.port))
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let server = CrawlspaceServer(options: options)
        let delegate = AppDelegate(server: server)
        app.delegate = delegate

        Task.detached {
            do {
                try await server.run { port in
                    Task { @MainActor in
                        StatusMenu.shared = StatusMenu(server: server, port: port)
                        delegate.isReady = true
                        if !delegate.pending.isEmpty {
                            for package in delegate.pending { delegate.openPackage(package) }
                        } else if options.openBrowser {
                            StatusMenu.shared?.openBrowser()
                        }
                        print("\(AppIdentity.name) \(AppVersion.current) is running at http://127.0.0.1:\(port)")
                        if options.developmentUI {
                            print("With `npm run dev` running in Web/, open \(server.browserURL(port: port)) to sign this browser in.")
                        }
                        fflush(stdout)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("\(AppIdentity.name) couldn't start: \(error.localizedDescription)\n".utf8))
            }
            await MainActor.run { StatusMenu.quitImmediately() }
        }
        app.run()
        exit(0)
    }

    /// Runs one scheduled crawl with no UI, as launchd asks, then posts a notification and quits.
    /// WebKit (JavaScript rendering, PDF reports) needs an application run loop even here.
    @MainActor
    public static func runSchedule(_ id: UUID) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task.detached {
            let name = ScheduleStore.load(id: id)?.name ?? "Scheduled crawl"
            do {
                let result = try await ScheduleRunner.run(scheduleID: id)
                log("\(name): \(result.summary)")
                await notify(title: name, body: result.summary)
            } catch {
                log("\(name) failed: \(error.localizedDescription)")
                await notify(title: "\(name) failed", body: error.localizedDescription)
            }
            exit(0)
        }
        app.run()
        exit(0)
    }

    /// launchd sends this to ~/Library/Logs/Crawlspace, the place to look when a run misbehaves.
    private static func log(_ message: String) {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        FileHandle.standardOutput.write(Data("[\(stamp)] \(message)\n".utf8))
    }

    private static func notify(title: String, body: String) async {
        // Notifications need an app bundle; a bare development binary just logs.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let centre = UNUserNotificationCenter.current()
        guard let granted = try? await centre.requestAuthorization(options: [.alert, .sound]), granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await centre.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
