import Audit
import CrawlCore
import Foundation
import Storage

/// Checks some URLs of a finished crawl again, in place.
///
/// Each is fetched again, and so is every address its links lead to that answered badly — broken,
/// redirecting, unreachable — or that's new to the crawl. What's found is written over what was
/// there, and the crawl's cross-page issues (links to broken pages, duplicates, canonicals…) are
/// worked out again. So an issue that's been fixed is gone from the crawl, and one that hasn't
/// stays. Speed isn't measured: that's Lighthouse's.
public enum PageCheck {
    public struct Progress: Sendable, Codable, Hashable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    public struct Result: Sendable, Codable, Hashable {
        public var checked = 0
        /// Issue codes gone from the URLs checked, with how many URLs each left.
        public var resolved: [String: Int] = [:]
        /// Issue codes on the URLs checked that weren't there before.
        public var found: [String: Int] = [:]
        /// Issues still on the URLs checked.
        public var remaining = 0
        /// For each issue resolved, the other URLs in the crawl that still have it, most linked-to
        /// first: the same fix may have reached them too — a theme's, say — and checking them would
        /// tell. URLs this check just looked at are left out, and so is speed, which it doesn't measure.
        public var elsewhere: [String: [Int64]] = [:]
    }

    public static func run(store: CrawlStore, ids: [Int64], password: String? = nil,
                           progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        let config = try store.loadConfig()
        let scope = CrawlScope(config: config)
        let resolvedPassword = password ?? (config.basicAuthUsername.isEmpty
            ? nil
            : CredentialStore.password(account: CredentialStore.account(host: scope.startHost, username: config.basicAuthUsername)))
        let processor = PageProcessor(config: config, scope: scope, password: resolvedPassword)
        let writer = CrawlWriter(store: store)
        let concurrency = max(1, config.concurrency)

        let pages = try store.discoveredURLs(ids: ids)
        let before = try store.issueCodes(ids: pages.map(\.id))

        var index: [UInt64: Int64] = [:]
        var nextID: Int64 = 0
        try store.forEachURL { id, url, _ in
            index[StableHash.fnv1a64(url)] = id
            nextID = max(nextID, id)
        }
        nextID += 1

        // The pages first.
        var total = pages.count
        var done = 0
        let checked = await process(pages, with: processor, concurrency: concurrency) {
            done += 1
            progress(Progress(done: done, total: total))
        }

        // Then where their links lead, when it answered badly before or is new to the crawl.
        var targets: [Int64: DiscoveredURL] = [:]
        var added: Set<Int64> = []
        let pageIDs = Set(pages.map(\.id))
        let known = Dictionary(uniqueKeysWithValues: try store.rows(ids: Array(Set(checked.flatMap { page, outcome in
            outcome.links.compactMap { index[StableHash.fnv1a64($0.string)] }
        }))).map { ($0.id, $0) })
        for (page, outcome) in checked {
            for link in outcome.links {
                let key = StableHash.fnv1a64(link.string)
                if let id = index[key] {
                    if let row = known[id], row.state == .crawled, targets[id] == nil, !pageIDs.contains(id), !answeredWell(row) {
                        targets[id] = DiscoveredURL(id: id, url: row.url, host: link.url.host() ?? "", isInternal: row.isInternal,
                                                    depth: row.depth, state: .queued, foundVia: .link, resourceType: row.resourceType)
                    }
                    continue
                }
                let isInternal = config.mode == .spider ? scope.isInternal(link.url) : false
                let decision = scope.decide(url: link.url, isInternal: isInternal, depth: page.depth + 1, linkType: link.type,
                                            followable: !link.flags.contains(.nofollow))
                if decision == .ignore { continue }
                let record = DiscoveredURL(id: nextID, url: link.string, host: link.url.host() ?? "", isInternal: isInternal,
                                           depth: page.depth + 1, state: decision == .crawl ? .queued : .skipped, foundVia: .link,
                                           resourceType: link.type.impliedResourceType,
                                           skipReason: { if case .skip(let reason) = decision { reason } else { nil } }())
                index[key] = nextID
                writer.submit(.discover(record))
                added.insert(nextID)
                if decision == .crawl { targets[nextID] = record }
                nextID += 1
            }
        }
        total += targets.count
        progress(Progress(done: done, total: total))
        let fetched = await process(Array(targets.values), with: processor, concurrency: concurrency) {
            done += 1
            progress(Progress(done: done, total: total))
        }

        // Written over what was there. A link on a page checked always has its address in the
        // crawl now; one found on a target only if the crawl already knew it, since a check
        // doesn't go on to crawl the site.
        for (page, outcome) in checked {
            let (result, links, hreflang) = outcome.records(of: page.id) { index[StableHash.fnv1a64($0.string)] }
            write(result, outcome, links, hreflang, to: writer)
        }
        for (target, outcome) in fetched {
            let (result, links, hreflang) = outcome.records(of: target.id) { link in
                index[StableHash.fnv1a64(link.string)].flatMap { added.contains($0) ? nil : $0 }
            }
            write(result, outcome, links, hreflang, to: writer)
        }
        try writer.flush()
        try PostCrawlAnalyzer.run(store: store)

        let after = try store.issueCodes(ids: pages.map(\.id))
        var summary = Result(checked: pages.count)
        for page in pages {
            let then = before[page.id] ?? [], now = after[page.id] ?? []
            for code in then.subtracting(now) { summary.resolved[code, default: 0] += 1 }
            for code in now.subtracting(then) { summary.found[code, default: 0] += 1 }
            summary.remaining += now.count
        }
        let looked = Set(pages.map(\.id))
        for code in summary.resolved.keys where !code.hasPrefix("lh_") {
            let others = try store.rowIDs(for: URLListQuery(filter: .issue(code), sortColumn: .inlinks, ascending: false))
                .filter { !looked.contains($0) }
            if !others.isEmpty { summary.elsewhere[code] = others }
        }
        return summary
    }

    /// Whether a URL answered as it should, so there's nothing to look at again: a page or file
    /// that came back 2xx.
    static func answeredWell(_ row: URLRow) -> Bool {
        row.error == nil && row.statusCode.map { (200...299).contains($0) } == true
    }

    private static func write(_ result: CrawledURL, _ outcome: ProcessOutcome, _ links: [LinkRecord], _ hreflang: [HreflangRecord],
                              to writer: CrawlWriter) {
        writer.submit(.crawled(result, issues: outcome.issues, links: links, hreflang: hreflang,
                               structuredData: outcome.structuredData, html: outcome.html,
                               renderedHTML: outcome.renderedHTML, screenshot: outcome.screenshot))
    }

    /// Fetches and processes URLs a few at a time, waiting and trying once more when a server
    /// asks to slow down.
    private static func process(_ items: [DiscoveredURL], with processor: PageProcessor, concurrency: Int,
                                onEach: () -> Void) async -> [(DiscoveredURL, ProcessOutcome)] {
        var results: [(DiscoveredURL, ProcessOutcome)] = []
        await withTaskGroup(of: (DiscoveredURL, ProcessOutcome).self) { group in
            var pending = items[...]
            func startNext() {
                guard let item = pending.popFirst() else { return }
                group.addTask {
                    var outcome = await processor.process(item, attempt: 0)
                    if let seconds = outcome.retryAfterSeconds {
                        try? await Task.sleep(for: .seconds(min(seconds, 30)))
                        outcome = await processor.process(item, attempt: 1)
                    }
                    return (item, outcome)
                }
            }
            for _ in 0..<concurrency { startNext() }
            for await finished in group {
                results.append(finished)
                onEach()
                startNext()
            }
        }
        return results
    }
}
