import Audit
import CrawlCore
import DequeModule
import Foundation
import Storage

public struct CrawlProgress: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Codable {
        case idle, starting, crawling, paused, stopping, analysing, finished, failed
    }

    public var phase: Phase = .idle
    public var crawled = 0
    public var discovered = 0
    public var queued = 0
    public var inFlight = 0
    /// How many connections the crawl is running right now, which can change while it runs.
    public var concurrency = 0
    public var urlsPerSecond: Double = 0
    public var elapsed: Duration = .zero
    /// True when the crawl ended because the user stopped it (it can be resumed later).
    public var wasStopped = false
    public var errorMessage: String?

    public init() {}
}

/// Runs a crawl against a `CrawlStore`: owns the frontier, hands URLs to concurrent workers,
/// records results through a batched writer, and runs post-crawl analysis at the end.
///
/// The frontier keeps up to `memoryQueueLimit` queued URLs in memory. Beyond that, new URLs are
/// written to SQLite only and loaded back in batches, so memory stays bounded on huge sites.
public actor CrawlEngine {
    public nonisolated let progress: AsyncStream<CrawlProgress>
    private let progressContinuation: AsyncStream<CrawlProgress>.Continuation

    private let store: CrawlStore
    private let writer: CrawlWriter
    private let config: CrawlConfig
    private let scope: CrawlScope
    private let processor: PageProcessor
    private let memoryQueueLimit: Int
    private let refillBatch = 20_000

    // Frontier
    private var urlIndex: [UInt64: Int64] = [:]
    private var nextID: Int64 = 1
    private var queue = Deque<DiscoveredURL>()
    private var overflowed = false
    private var watermark: Int64 = 0
    private var databaseOnlyEnqueues = 0
    private var databaseOnlyQueued = 0
    private var refilling = false
    /// URLs skipped only because they were first found via nofollow; a later followed link requeues them.
    private var upgradeableSkips: Set<Int64> = []
    private var queryVariants: [String: Int] = [:]
    private var attempts: [Int64: Int] = [:]

    // Run state
    private var phase: CrawlProgress.Phase = .idle
    private var stopRequested = false
    /// Workers are identified by index: turning the crawl down retires the ones above the new
    /// number, which is what makes the change take effect without restarting the crawl.
    private var targetConcurrency: Int
    private var liveWorkers: Set<Int> = []
    private var controller: ConcurrencyController
    /// Set once the crawl is over, so a retiring worker isn't replaced.
    private var finishing = false
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var inFlight = 0
    private var crawled = 0
    private var discovered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var activeSince: ContinuousClock.Instant?
    private var elapsedBeforeActive: Duration = .zero
    private var recentCompletions = Deque<ContinuousClock.Instant>()
    private var errorMessage: String?

    /// `password` overrides the stored-password lookup for HTTP authentication (used by the CLI and tests).
    public init(store: CrawlStore, config: CrawlConfig? = nil, memoryQueueLimit: Int = 50_000,
                password: String? = nil) throws {
        let config = try config ?? store.loadConfig()
        self.store = store
        self.config = config
        self.memoryQueueLimit = memoryQueueLimit
        writer = CrawlWriter(store: store)
        scope = CrawlScope(config: config)
        let scope = self.scope
        let resolvedPassword = password ?? (config.basicAuthUsername.isEmpty
            ? nil
            : CredentialStore.password(account: CredentialStore.account(host: scope.startHost, username: config.basicAuthUsername)))
        processor = PageProcessor(config: config, scope: scope, password: resolvedPassword)
        targetConcurrency = max(1, config.concurrency)
        controller = ConcurrencyController(maximum: max(1, config.concurrency))
        (progress, progressContinuation) = AsyncStream.makeStream(of: CrawlProgress.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Control

    /// Starts a new crawl or resumes a paused/stopped one, returning when it finishes or is stopped.
    public func run() async {
        guard phase == .idle else { return }
        phase = .starting
        emitProgress()

        do {
            let status = try store.status()
            if status == .completed {
                throw CrawlError.alreadyCompleted
            }
            if status == .new {
                try store.saveConfig(config)
                seed()
                await loadSitemaps()
            } else {
                try loadExistingCrawl()
            }
            try store.setStatus(.running)
            if try store.meta("started_at") == nil {
                try store.setMeta("started_at", ISO8601DateFormatter().string(from: Date()))
            }
        } catch {
            fail(error)
            return
        }

        writer.startAutoFlush()
        phase = .crawling
        activeSince = .now

        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.emitProgress()
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishContinuation = continuation
            spawnWorkers()
            // Nothing to wait for if the crawl was stopped before a worker ever started.
            if liveWorkers.isEmpty {
                finishContinuation = nil
                continuation.resume()
            }
        }
        ticker.cancel()
        writer.stopAutoFlush()
        pauseClock()

        do {
            try await flushWriter()
            if let error = writer.lastError { throw error }
            try await saveRobotsFiles()

            if stopRequested {
                try store.setStatus(.stopped)
            } else {
                phase = .analysing
                emitProgress()
                let store = store
                try await Task.detached(priority: .userInitiated) { try PostCrawlAnalyzer.run(store: store) }.value
                try store.setStatus(.completed)
                try store.setMeta("finished_at", ISO8601DateFormatter().string(from: Date()))
            }
            try store.setMeta("elapsed_seconds", String(elapsedBeforeActive.components.seconds))
            phase = .finished
            emitProgress()
            progressContinuation.finish()
        } catch {
            fail(error)
        }
    }

    public func pause() {
        guard phase == .crawling else { return }
        phase = .paused
        pauseClock()
        try? store.setStatus(.paused)
        emitProgress()
    }

    public func resume() {
        guard phase == .paused else { return }
        phase = .crawling
        activeSince = .now
        try? store.setStatus(.running)
        signalAll()
        emitProgress()
    }

    /// Stops after in-flight requests complete. Queued URLs stay in the store for a later resume.
    public func stop() {
        guard [.starting, .crawling, .paused].contains(phase) else { return }
        stopRequested = true
        phase = .stopping
        signalAll()
        emitProgress()
    }

    public enum CrawlError: LocalizedError {
        case alreadyCompleted
        public var errorDescription: String? { "This crawl has already completed." }
    }

    // MARK: - Workers

    /// Changes how many connections the crawl runs with, while it is running.
    public func setConcurrency(_ count: Int) {
        applyConcurrency(count, automatic: false)
    }

    public func currentConcurrency() -> Int { targetConcurrency }

    private func applyConcurrency(_ count: Int, automatic: Bool) {
        let clamped = max(1, min(count, 100))
        guard clamped != targetConcurrency else { return }
        targetConcurrency = clamped
        // Asking for a number by hand makes that the new ceiling for the automatic side too.
        if !automatic {
            controller = ConcurrencyController(maximum: clamped, start: clamped)
        }
        spawnWorkers()
        // Wakes workers waiting on an empty queue, including any that now have to retire.
        signalAll()
        emitProgress()
    }

    private func spawnWorkers() {
        guard !finishing, ![.stopping, .finished, .failed, .analysing].contains(phase) else { return }
        for index in 0..<targetConcurrency where !liveWorkers.contains(index) {
            liveWorkers.insert(index)
            Task { await self.workerLoop(index: index) }
        }
    }

    private func workerExited(index: Int) {
        liveWorkers.remove(index)
        if finishing {
            if liveWorkers.isEmpty {
                finishContinuation?.resume()
                finishContinuation = nil
            }
        } else if liveWorkers.count < targetConcurrency {
            // A worker that retired while the crawl was being turned back up is replaced.
            spawnWorkers()
        }
    }

    private nonisolated func workerLoop(index: Int) async {
        while let (item, attempt) = await next(worker: index) {
            while writer.pendingCount > 20_000 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let outcome = await processor.process(item, attempt: attempt)
            await complete(item, outcome)
        }
        await workerExited(index: index)
    }

    /// Ends this worker and the crawl with it: every reason to stop other than retiring a surplus
    /// worker means the frontier is done, so the others are not replaced.
    private func endOfWork() -> (DiscoveredURL, Int)? {
        finishing = true
        return nil
    }

    private func next(worker index: Int) async -> (DiscoveredURL, Int)? {
        while true {
            // Turned down: this worker is one of the surplus, so it retires without ending the crawl.
            if index >= targetConcurrency { return nil }
            switch phase {
            case .stopping, .finished, .failed, .analysing:
                return endOfWork()
            case .paused:
                await waitForSignal()
                continue
            case .idle, .starting, .crawling:
                break
            }
            if writer.lastError != nil {
                stopRequested = true
                phase = .stopping
                signalAll()
                return endOfWork()
            }
            if crawled + inFlight >= config.maxURLs {
                if inFlight == 0 { signalAll() }
                return endOfWork()
            }
            if let item = queue.popFirst() {
                inFlight += 1
                return (item, attempts[item.id] ?? 0)
            }
            if overflowed {
                await refill()
                continue
            }
            if inFlight == 0 {
                signalAll()
                return endOfWork()
            }
            await waitForSignal()
        }
    }

    private func complete(_ item: DiscoveredURL, _ outcome: ProcessOutcome) {
        inFlight -= 1
        defer { signalAll() }

        if config.automaticConcurrency {
            controller.record(latencyMs: outcome.result.ttfbMs ?? outcome.result.responseMs,
                              pushedBack: outcome.retryAfterSeconds != nil,
                              failed: outcome.result.error != nil)
            if let adjusted = controller.evaluate() {
                applyConcurrency(adjusted, automatic: true)
            }
        }

        if outcome.retryAfterSeconds != nil {
            attempts[item.id, default: 0] += 1
            queue.append(item)
            return
        }
        attempts[item.id] = nil

        var result = outcome.result
        var links: [LinkRecord] = []
        var hreflang: [HreflangRecord] = []
        for link in outcome.links {
            guard let targetID = register(link, depth: item.depth + 1) else { continue }
            links.append(LinkRecord(sourceID: item.id, targetID: targetID, type: link.type, flags: link.flags, text: link.text))
            switch link.type {
            case .redirect: result.redirectToID = targetID
            case .canonical: result.page?.canonicalID = targetID
            case .hreflang: hreflang.append(HreflangRecord(lang: link.text, targetID: targetID))
            default: break
            }
        }

        writer.submit(.crawled(result, issues: outcome.issues, links: links, hreflang: hreflang,
                               structuredData: outcome.structuredData, html: outcome.html,
                               renderedHTML: outcome.renderedHTML, screenshot: outcome.screenshot))
        crawled += 1
        let now = ContinuousClock.now
        recentCompletions.append(now)
        while let first = recentCompletions.first, first.duration(to: now) > .seconds(5) {
            recentCompletions.removeFirst()
        }
    }

    // MARK: - Frontier

    private func seed() {
        switch config.mode {
        case .spider:
            guard let start = URLNormalizer.normalize(config.startURL, stripParameters: config.stripQueryParameters) else { return }
            _ = addURL(start, isInternal: true, depth: 0, foundVia: .seed, resourceType: .page, decision: .crawl)
        case .list:
            for raw in config.listURLs {
                guard let url = URLNormalizer.normalize(raw, stripParameters: config.stripQueryParameters),
                      urlIndex[StableHash.fnv1a64(url.absoluteString)] == nil else { continue }
                _ = addURL(url, isInternal: true, depth: 0, foundVia: .list, resourceType: .page, decision: .crawl)
            }
        case .sitemap:
            // Seeded by loadSitemaps() once the sitemaps have been read.
            break
        }
    }

    /// Reads the configured sitemaps (and any the site's robots.txt points to), records what they
    /// list, and queues those URLs so orphans and non-200 entries show up in the crawl.
    private func loadSitemaps() async {
        var sources = config.sitemapURLs.compactMap { URLNormalizer.normalize($0) }
        if config.discoverSitemapsFromRobots, config.mode != .list, let start = scope.startURL,
           let origin = RobotsCache.origin(of: start) {
            let entry = await processor.robots.entry(for: origin)
            if case .parsed(let robots) = entry.policy {
                sources += robots.sitemaps.compactMap { URLNormalizer.normalize($0) }
            }
        }
        guard !sources.isEmpty else { return }

        let loader = SitemapLoader(fetcher: processor.fetcher)
        let output = await loader.load(sources, stripParameters: config.stripQueryParameters)
        for record in output.records {
            let listed = output.entries.filter { $0.sitemap == record.url }
            writer.submit(.sitemap(record, urls: listed))
        }
        for url in output.urls {
            let key = StableHash.fnv1a64(url.absoluteString)
            guard urlIndex[key] == nil else { continue }
            let isInternal = config.mode == .sitemap ? true : scope.isInternal(url)
            let decision = config.mode == .sitemap
                ? CrawlScope.Decision.crawl
                : scope.decide(url: url, isInternal: isInternal, depth: 0, linkType: .anchor, followable: true)
            guard decision != .ignore else { continue }
            _ = addURL(url, isInternal: isInternal, depth: 0, foundVia: .sitemap, resourceType: .page, decision: decision)
        }
    }

    private func loadExistingCrawl() throws {
        var maxID: Int64 = 0
        try store.forEachURL { id, url, state in
            urlIndex[StableHash.fnv1a64(url)] = id
            maxID = max(maxID, id)
            discovered += 1
            if state == .crawled { crawled += 1 }
        }
        nextID = maxID + 1
        // Everything still queued is in the database; load it in batches.
        overflowed = true
        watermark = 0
        databaseOnlyQueued = discovered - crawled
        if let seconds = try store.meta("elapsed_seconds").flatMap(Int64.init) {
            elapsedBeforeActive = .seconds(seconds)
        }
    }

    /// Returns the ID for a discovered link's URL, recording (and possibly queueing) it if new.
    private func register(_ link: DiscoveredLink, depth: Int) -> Int64? {
        let key = StableHash.fnv1a64(link.string)
        let followable = !link.flags.contains(.nofollow)
        let isInternal = config.mode == .spider ? scope.isInternal(link.url) : false

        if let existing = urlIndex[key] {
            if followable, upgradeableSkips.contains(existing),
               scope.decide(url: link.url, isInternal: isInternal, depth: depth, linkType: link.type, followable: true) == .crawl {
                upgradeableSkips.remove(existing)
                writer.submit(.requeue(id: existing, depth: depth))
                queue.append(DiscoveredURL(id: existing, url: link.string, host: link.url.host() ?? "", isInternal: isInternal,
                                           depth: depth, state: .queued, foundVia: .link, resourceType: link.type.impliedResourceType))
            }
            return existing
        }

        // List and sitemap crawls audit exactly the URLs they were given; links are recorded but
        // not followed.
        var decision: CrawlScope.Decision
        switch config.mode {
        case .list: decision = .skip("Not in the URL list")
        case .sitemap: decision = .skip("Not in the sitemap")
        case .spider:
            decision = scope.decide(url: link.url, isInternal: isInternal, depth: depth, linkType: link.type, followable: followable)
        }

        if decision == .crawl, isInternal, config.maxQueryVariantsPerPath > 0, link.url.query() != nil {
            let pathKey = (link.url.host() ?? "") + link.url.path(percentEncoded: true)
            let count = queryVariants[pathKey, default: 0] + 1
            queryVariants[pathKey] = count
            if count > config.maxQueryVariantsPerPath {
                decision = .skip("Too many query-string variants of this path (possible crawler trap)")
            }
        }
        if decision == .ignore { return nil }

        let id = addURL(link.url, isInternal: isInternal, depth: depth, foundVia: .link,
                        resourceType: link.type.impliedResourceType, decision: decision)
        if !followable, case .skip = decision,
           scope.decide(url: link.url, isInternal: isInternal, depth: depth, linkType: link.type, followable: true) == .crawl {
            upgradeableSkips.insert(id)
        }
        return id
    }

    private func addURL(_ url: URL, isInternal: Bool, depth: Int, foundVia: FoundVia, resourceType: ResourceType,
                        decision: CrawlScope.Decision) -> Int64 {
        let id = nextID
        nextID += 1
        let string = url.absoluteString
        urlIndex[StableHash.fnv1a64(string)] = id
        discovered += 1

        var skipReason: String?
        if case .skip(let reason) = decision { skipReason = reason }
        let record = DiscoveredURL(
            id: id, url: string, host: url.host() ?? "", isInternal: isInternal, depth: depth,
            state: skipReason == nil ? .queued : .skipped, foundVia: foundVia, resourceType: resourceType, skipReason: skipReason
        )
        writer.submit(.discover(record))

        if skipReason == nil {
            if overflowed || queue.count >= memoryQueueLimit {
                overflowed = true
                databaseOnlyEnqueues += 1
                databaseOnlyQueued += 1
            } else {
                queue.append(record)
                watermark = id
            }
        }
        return id
    }

    private func refill() async {
        if refilling {
            await waitForSignal()
            return
        }
        refilling = true
        defer {
            refilling = false
            signalAll()
        }
        let enqueuesBefore = databaseOnlyEnqueues
        do {
            try await flushWriter()
            let (store, afterID, limit) = (store, watermark, refillBatch)
            let rows = try await Task.detached { try store.queuedURLs(afterID: afterID, limit: limit) }.value
            queue.append(contentsOf: rows)
            databaseOnlyQueued = max(0, databaseOnlyQueued - rows.count)
            if let last = rows.last { watermark = last.id }
            if rows.count < limit && databaseOnlyEnqueues == enqueuesBefore {
                overflowed = false
                databaseOnlyQueued = 0
            }
        } catch {
            errorMessage = error.localizedDescription
            stopRequested = true
            phase = .stopping
        }
    }

    // MARK: - Helpers

    private func waitForSignal() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func signalAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func flushWriter() async throws {
        let writer = writer
        try await Task.detached(priority: .userInitiated) { try writer.flush() }.value
    }

    private func saveRobotsFiles() async throws {
        for entry in await processor.robots.fetchedEntries() {
            guard let url = URL(string: entry.origin), scope.isInternal(url) else { continue }
            let summary = entry.text ?? "(\(entry.statusCode.map { "HTTP \($0)" } ?? entry.failure ?? "unavailable"))"
            try store.setMeta("robots_txt:\(entry.origin)", summary)
        }
    }

    private func pauseClock() {
        if let since = activeSince {
            elapsedBeforeActive += since.duration(to: .now)
            activeSince = nil
        }
    }

    private func fail(_ error: any Error) {
        errorMessage = error.localizedDescription
        phase = .failed
        try? store.setStatus(.stopped)
        emitProgress()
        progressContinuation.finish()
    }

    private func emitProgress() {
        var snapshot = CrawlProgress()
        snapshot.phase = phase
        snapshot.crawled = crawled
        snapshot.discovered = discovered
        snapshot.queued = queue.count + databaseOnlyQueued
        snapshot.inFlight = inFlight
        snapshot.concurrency = targetConcurrency
        snapshot.elapsed = elapsedBeforeActive + (activeSince.map { $0.duration(to: .now) } ?? .zero)
        if let first = recentCompletions.first, recentCompletions.count > 1 {
            let window = max(first.duration(to: .now).milliseconds / 1_000, 1)
            snapshot.urlsPerSecond = Double(recentCompletions.count) / window
        }
        snapshot.wasStopped = stopRequested
        snapshot.errorMessage = errorMessage ?? writer.lastError?.localizedDescription
        progressContinuation.yield(snapshot)
    }
}
