import Audit
import CrawlCore
import Crawler
import Export
import Foundation
import Integrations
import Lighthouse
import Storage

/// One open crawl: owns its store, drives the engine and Lighthouse, and tells every browser tab
/// watching it what's happening.
///
/// It lives in the server, not the browser, so a crawl carries on when the tab is closed and a
/// tab opened later picks up where things are.
actor CrawlSession {
    let id: String
    let packageURL: URL
    nonisolated let store: CrawlStore
    nonisolated let events = EventHub()

    private var config: CrawlConfig
    private var status: CrawlStatus
    private var progress = CrawlProgress()
    private var engine: CrawlEngine?
    private var runTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lighthouseTask: Task<Void, Never>?
    private var lighthouseProgress: LighthouseBatch.Progress?
    private var lighthouseMessage: String?
    private var checkTask: Task<Void, Never>?
    private var checkProgress: PageCheck.Progress?
    private var exporting: String?
    private let sleepGuard = SleepGuard()
    /// Told when a crawl starts or stops, so the crawl list and the menu bar stay current.
    private let onActivityChange: @Sendable () -> Void

    var name: String { packageURL.deletingPathExtension().lastPathComponent }

    init(id: String, packageURL: URL, store: CrawlStore, onActivityChange: @escaping @Sendable () -> Void) throws {
        self.id = id
        self.packageURL = packageURL
        self.store = store
        self.onActivityChange = onActivityChange
        config = try store.loadConfig()
        status = try store.status()
        // A package left "running" by a crash or a quit mid-crawl can be resumed like a stopped one.
        if status == .running { status = .stopped }
    }

    var isRunning: Bool { [.starting, .crawling, .analysing, .stopping].contains(progress.phase) || progress.phase == .paused }
    var isBusy: Bool { isRunning || lighthouseTask != nil || checkTask != nil }

    func state() -> CrawlStateDTO {
        CrawlStateDTO(
            id: id, name: name, site: CrawlScope(config: config).startHost, status: status,
            progress: ProgressDTO(progress),
            isRunning: [.starting, .crawling, .analysing, .stopping].contains(progress.phase),
            isPaused: progress.phase == .paused,
            canStart: engine == nil && [.new, .stopped, .paused].contains(status),
            isConfigurable: engine == nil && status == .new,
            config: config,
            lighthouse: LighthouseStateDTO(running: lighthouseTask != nil, progress: lighthouseProgress,
                                           message: lighthouseMessage),
            check: CheckStateDTO(running: checkTask != nil, progress: checkProgress),
            exporting: exporting,
            ecommerceNote: try? store.meta("ecommerce_note"),
            speedPlan: LighthousePages.describe(config)
        )
    }

    private func publishState() {
        events.publish("state", state())
    }

    // MARK: - Crawl control

    func start() throws {
        guard engine == nil else { return }
        let isNew = try store.status() == .new
        // A crawl under way keeps the scope it started with; only speed can change part way.
        var configToRun = config
        if !isNew {
            var stored = try store.loadConfig()
            stored.concurrency = config.concurrency
            stored.automaticConcurrency = config.automaticConcurrency
            stored.maxURLsPerSecond = config.maxURLsPerSecond
            stored.timeoutSeconds = config.timeoutSeconds
            stored.renderConcurrency = config.renderConcurrency
            configToRun = stored
            config = stored
        }
        try store.saveConfig(configToRun)
        let engine = try CrawlEngine(store: store, config: configToRun)
        self.engine = engine
        status = .running
        sleepGuard.begin(reason: "Crawlspace is crawling \(name)")
        runTask = Task { [weak self] in
            async let run: Void = engine.run()
            for await update in engine.progress {
                await self?.apply(update)
            }
            await run
            await self?.finished()
        }
        startTicking()
        publishState()
        onActivityChange()
    }

    func pause() async {
        await engine?.pause()
    }

    func resume() async {
        await engine?.resume()
    }

    func stop() async {
        await engine?.stop()
    }

    /// Applies edited settings. Before the first start everything can change; after it, only the
    /// speed settings, and the connection count reaches a running crawl straight away.
    func updateConfig(_ edited: CrawlConfig) async throws {
        if engine == nil, try store.status() == .new {
            let errors = edited.validationErrors()
            guard errors.isEmpty else { throw ServerError.badRequest(errors.joined(separator: " ")) }
            config = edited
            try store.saveConfig(config)
        } else {
            var stored = try store.loadConfig()
            stored.concurrency = edited.concurrency
            stored.automaticConcurrency = edited.automaticConcurrency
            stored.maxURLsPerSecond = edited.maxURLsPerSecond
            stored.timeoutSeconds = edited.timeoutSeconds
            stored.renderConcurrency = edited.renderConcurrency
            stored.lighthouseTopPages = edited.lighthouseTopPages
            stored.lighthouseShopifyTemplates = edited.lighthouseShopifyTemplates
            try store.saveConfig(stored)
            config = stored
            if let engine { await engine.setConcurrency(config.concurrency) }
        }
        publishState()
    }

    /// Recomputes duplicates, inlinks, redirect chains and the other cross-page issues.
    func analyse() async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) { try PostCrawlAnalyzer.run(store: store) }.value
        events.publish("changed", ["reason": "analysed"])
    }

    private func apply(_ update: CrawlProgress) {
        progress = update
        if let message = update.errorMessage { events.publish("error", MessageDTO(message: message)) }
        events.publish("progress", ProgressDTO(update))
    }

    private func finished() {
        engine = nil
        runTask = nil
        tickTask?.cancel()
        tickTask = nil
        sleepGuard.end()
        status = (try? store.status()) ?? .stopped
        events.publish("changed", ["reason": "finished"])
        publishState()
        onActivityChange()
        if status == .completed || status == .stopped { updateWorklist() }
        // A crawl that ran to the end gets its speed measured; a stopped one is left for later.
        if status == .completed, config.lighthouseTopPages > 0 {
            try? startLighthouse(top: config.lighthouseTopPages)
        }
    }

    /// While crawling, tells the browser every two seconds that the counts and tables have moved
    /// on, rather than pushing them: it asks for what it's showing.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [events] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                events.publish("changed", ["reason": "tick"])
            }
        }
    }

    // MARK: - Lighthouse

    /// Measures the `top` most-linked pages, or the given rows.
    func startLighthouse(top: Int? = nil, rowIDs: [Int64] = []) throws {
        guard lighthouseTask == nil else { throw ServerError.conflict("Lighthouse is already running on this crawl.") }
        guard case .ready(let toolchain) = LighthouseToolchain.locate() else {
            lighthouseMessage = "Lighthouse is still being set up. It runs once the download finishes."
            publishState()
            throw ServerError.unavailable(lighthouseMessage!)
        }
        var pages: [LighthouseBatch.Page] = []
        if !rowIDs.isEmpty {
            pages = try store.rows(ids: rowIDs)
                .filter { $0.resourceType == .page && $0.state == .crawled }
                .map { .init(id: $0.id, url: $0.url) }
        } else {
            pages = try LighthousePages.choose(store: store, config: config, top: top)
        }
        guard !pages.isEmpty else { throw ServerError.badRequest("There are no crawled pages to measure.") }

        let batch = LighthouseBatch(store: store, runner: LighthouseRunner(toolchain: toolchain), pages: pages,
                                    headers: LighthouseBatch.headers(for: config))
        lighthouseMessage = nil
        lighthouseProgress = LighthouseBatch.Progress(done: 0, total: pages.count * 2, failures: 0)
        sleepGuard.begin(reason: "Crawlspace is measuring \(name) with Lighthouse")
        lighthouseTask = Task { [weak self] in
            let owner = self
            let message: String
            do {
                let result = try await batch.run { update in
                    Task { await owner?.lighthouseUpdated(update) }
                }
                message = result.failures.isEmpty
                    ? "Measured \(pages.count) page\(pages.count == 1 ? "" : "s") on mobile and desktop."
                    : "Measured \(pages.count) pages; \(result.failures.count) of \(pages.count * 2) runs failed."
            } catch is CancellationError {
                message = "Lighthouse was stopped. The pages it finished are kept."
            } catch {
                message = error.localizedDescription
            }
            await owner?.lighthouseFinished(message: message)
        }
        publishState()
        onActivityChange()
    }

    func cancelLighthouse() {
        lighthouseTask?.cancel()
    }

    private func lighthouseUpdated(_ update: LighthouseBatch.Progress) {
        lighthouseProgress = update
        events.publish("lighthouse", update)
        // Each finished run changes the table, so let the browser refresh it.
        if update.done > 0 { events.publish("changed", ["reason": "lighthouse"]) }
    }

    /// Makes this crawl's list of fixes, or, for a check, verifies the fixes of the crawl it checked.
    private func updateWorklist() {
        let store = store
        let events = events
        Task.detached(priority: .utility) {
            guard let config = try? store.loadConfig() else { return }
            // A crawl's fixes are its own; a check's verify the crawl it checked. A list of URLs
            // isn't a site, so has none. ClickUp changes only when it's exported to.
            let checkOf = try? store.meta(Worklist.checkOfMeta)
            guard checkOf != nil || config.mode != .list else { return }
            do {
                let worklist = if let checkOf, let host = try? store.meta("check_for") {
                    try Worklist.open(package: URL(filePath: checkOf), host: host)
                } else {
                    try Worklist.open(for: store)
                }
                let changes = try worklist.update(from: store, isCheck: checkOf != nil)
                events.publish("worklist", changes)
            } catch {
                events.publish("error", MessageDTO(message: "Couldn't update the list of fixes: \(error.localizedDescription)"))
            }
        }
    }

    private func lighthouseFinished(message: String) {
        updateWorklist()
        lighthouseTask = nil
        lighthouseProgress = nil
        lighthouseMessage = message
        if engine == nil { sleepGuard.end() }
        events.publish("changed", ["reason": "lighthouse"])
        publishState()
        onActivityChange()
    }

    // MARK: - Checking pages

    /// Checks some of the crawl's URLs again, in place: what's resolved leaves the crawl.
    func startCheck(rowIDs: [Int64]) throws {
        guard !isRunning else { throw ServerError.conflict("Wait for the crawl to finish before checking pages.") }
        guard checkTask == nil else { throw ServerError.conflict("Pages are already being checked.") }
        guard !rowIDs.isEmpty else { throw ServerError.badRequest("Choose the pages to check.") }
        let store = store
        checkProgress = PageCheck.Progress(done: 0, total: rowIDs.count)
        sleepGuard.begin(reason: "Crawlspace is checking pages of \(name)")
        checkTask = Task { [weak self] in
            let owner = self
            do {
                let result = try await PageCheck.run(store: store, ids: rowIDs) { update in
                    Task { await owner?.checkUpdated(update) }
                }
                await owner?.checkFinished(CheckResultDTO(result))
            } catch {
                await owner?.checkFinished(nil, error: error.localizedDescription)
            }
        }
        publishState()
    }

    private func checkUpdated(_ update: PageCheck.Progress) {
        guard checkTask != nil else { return }
        checkProgress = update
        events.publish("check", update)
    }

    private func checkFinished(_ result: CheckResultDTO?, error: String? = nil) {
        checkTask = nil
        checkProgress = nil
        if engine == nil, lighthouseTask == nil { sleepGuard.end() }
        if let result { events.publish("check-finished", result) }
        if let error { events.publish("error", MessageDTO(message: "Couldn't check the pages: \(error)")) }
        events.publish("changed", ["reason": "checked"])
        publishState()
    }

    // MARK: - Exports

    /// Runs one export at a time per crawl, showing it in the status bar while it runs.
    func runExport<T: Sendable>(_ label: String, _ work: @Sendable () async throws -> T) async throws -> T {
        guard exporting == nil else { throw ServerError.conflict("Already exporting \(exporting!).") }
        exporting = label
        publishState()
        defer {
            exporting = nil
            publishState()
        }
        return try await work()
    }

    func close() {
        runTask?.cancel()
        tickTask?.cancel()
        lighthouseTask?.cancel()
        checkTask?.cancel()
        sleepGuard.end()
        try? store.close()
    }
}
