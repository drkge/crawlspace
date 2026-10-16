import Audit
import CrawlCore
import Foundation
import Storage

/// Checks one issue on some URLs of a finished crawl again, in place.
///
/// Each is fetched again, and so is every address its links lead to that's new to the crawl, or —
/// when the issue is about where links lead — that answered badly before: broken, redirecting,
/// unreachable. What's found is written over what was there, and the crawl's cross-page issues
/// (links to broken pages, duplicates, canonicals…) are worked out again. So the issue is gone
/// from the pages it's been fixed on, and stays on the rest.
///
/// Only that issue changes. Every other issue in the crawl is left as it was, even where the
/// pages fetched would now say otherwise: a check answers the one question it was asked. A page
/// the site wouldn't serve — it asked to slow down, or its bot protection challenged the crawler,
/// and still did after waiting — is left as it was too, rather than filed as broken. Speed isn't
/// measured: that's Lighthouse's.
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
        /// The issue checked.
        public var issue: String
        /// URLs fetched again.
        public var checked = 0
        /// Of those, the ones the issue has gone from.
        public var resolved = 0
        /// The ones it's still on.
        public var remaining = 0
        /// URLs the site wouldn't answer, left as they were.
        public var unanswered = 0
        /// When the issue has gone from any URL checked, the other URLs in the crawl that still have
        /// it, most linked-to first: the same fix may have reached them too — a theme's, say — and
        /// checking them would tell.
        public var elsewhere: [Int64] = []
    }

    /// Issues about where a page's links, canonical, hreflang or redirect lead: checking one
    /// means fetching those addresses again too, when they answered badly.
    static let aboutTargets: Set<String> = [
        "redirect_chain", "redirect_loop",
        "links_to_broken_internal", "links_to_redirect_internal", "links_to_broken_external", "links_to_unverified_external",
        "canonical_target_non_200", "canonical_target_non_indexable",
        "hreflang_missing_return_links", "hreflang_non_200_target",
    ]

    public static func run(store: CrawlStore, ids: [Int64], issue: String, password: String? = nil,
                           progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        let config = try store.loadConfig()
        let scope = CrawlScope(config: config)
        let resolvedPassword = password ?? (config.basicAuthUsername.isEmpty
            ? nil
            : CredentialStore.password(account: CredentialStore.account(host: scope.startHost, username: config.basicAuthUsername)))
        let processor = PageProcessor(config: config, scope: scope, password: resolvedPassword)
        let writer = CrawlWriter(store: store, place: IssueVisibility.place(ignoring: try store.ignoreRules()))
        let concurrency = max(1, config.concurrency)

        let pages = try store.discoveredURLs(ids: ids)
        let before = try store.issueCodes(ids: pages.map(\.id))
        // Speed is left out, since Lighthouse can write it while a check runs.
        let untouched = [issue] + PostCrawlAnalyzer.speedCodes
        let others = try store.issueRows(excluding: untouched)

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
        let (checked, unansweredPages) = await process(pages, with: processor, concurrency: concurrency) {
            done += 1
            progress(Progress(done: done, total: total))
        }

        // Then where their links lead, when it's new to the crawl, or answered badly before and
        // the issue is about it.
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
                    if aboutTargets.contains(issue), let row = known[id], row.state == .crawled, targets[id] == nil,
                       !pageIDs.contains(id), !answeredWell(row) {
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
        let (fetched, _) = await process(Array(targets.values), with: processor, concurrency: concurrency) {
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
        try store.restoreIssues(others, excluding: untouched)

        let answered = checked.map(\.0.id)
        let after = try store.issueCodes(ids: answered)
        var summary = Result(issue: issue, checked: answered.count, unanswered: unansweredPages.count)
        for id in answered {
            let had = before[id]?.contains(issue) == true, has = after[id]?.contains(issue) == true
            if had, !has { summary.resolved += 1 }
            if has { summary.remaining += 1 }
        }
        if summary.resolved > 0 {
            let looked = Set(pages.map(\.id))
            summary.elsewhere = try store.rowIDs(for: URLListQuery(filter: .issue(issue), sortColumn: .inlinks, ascending: false))
                .filter { !looked.contains($0) }
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

    /// Fetches and processes URLs a few at a time. A site that asks to slow down is waited for and
    /// asked again; a URL it still won't answer comes back apart, to be left as it was.
    private static func process(_ items: [DiscoveredURL], with processor: PageProcessor, concurrency: Int,
                                onEach: () -> Void) async -> (answered: [(DiscoveredURL, ProcessOutcome)], unanswered: [DiscoveredURL]) {
        var answered: [(DiscoveredURL, ProcessOutcome)] = []
        var unanswered: [DiscoveredURL] = []
        await withTaskGroup(of: (DiscoveredURL, ProcessOutcome).self) { group in
            var pending = items[...]
            func startNext() {
                guard let item = pending.popFirst() else { return }
                group.addTask {
                    // The processor waits as the site asks, and stops asking after a few tries.
                    var outcome = await processor.process(item, attempt: 0)
                    var attempt = 0
                    while outcome.retryAfterSeconds != nil {
                        attempt += 1
                        outcome = await processor.process(item, attempt: attempt)
                    }
                    return (item, outcome)
                }
            }
            for _ in 0..<concurrency { startNext() }
            for await (item, outcome) in group {
                if outcome.refused { unanswered.append(item) } else { answered.append((item, outcome)) }
                onEach()
                startNext()
            }
        }
        return (answered, unanswered)
    }
}
