import Audit
import CrawlCore
import Foundation
import Integrations
import Storage

/// What goes into ClickUp: the crawl's issues as the app lists them — one task per issue, in the
/// Errors, Warnings or Notices list for its severity, or when asked, the Lighthouse or Sitemap
/// list — each saying what's wrong, how to fix it and which URLs have it. An export replaces what an earlier one filed for the site, so ClickUp shows
/// the crawl exported and nothing older.
public enum ClickUpOverview {
    /// One issue, as the app's sidebar lists it.
    public struct Kind: Sendable, Hashable, Codable {
        public var code: String
        /// "Response Codes: Internal Client Error (4xx)".
        public var title: String
        public var severity: IssueSeverity
        /// Errors, Warnings or Notices by severity, or Lighthouse or Sitemap.
        public var group: IssueGroup
        /// URLs with the issue.
        public var total = 0
    }

    /// The crawl's issues, as the app's sidebar lists them: by group, then most URLs.
    public static func kinds(store: CrawlStore) throws -> [Kind] {
        let counts = try store.issueCounts()
        return IssueCatalogue.all.compactMap { definition -> Kind? in
            guard let count = counts[definition.code], count > 0 else { return nil }
            return Kind(code: definition.code, title: "\(definition.category.rawValue): \(definition.title)",
                        severity: definition.severity, group: definition.group, total: count)
        }.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.total != b.total { return a.total > b.total }
            return a.title < b.title
        }
    }

    /// How many URLs a task lists before pointing to the rest in Crawlspace.
    static let listedURLs = 100

    /// Where a crawl is in Crawlspace, as a task links to it.
    struct Crawl: Sendable {
        var name: String
        var host: String
        var appAddress: String

        /// The crawl's list of an issue's URLs.
        func link(for kind: Kind) -> String {
            let id = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            return "\(appAddress)/crawls/\(id)?view=issue:\(kind.code)"
        }
    }

    static func markdown(_ kind: Kind, urls: [String], crawl: Crawl) -> String {
        var parts = ["**\(kind.total.formatted()) \(kind.total == 1 ? "URL" : "URLs")** on \(crawl.host), as *\(crawl.name)* found."]
        if let definition = IssueCatalogue.definition(for: kind.code) {
            parts.append(definition.description)
            parts.append("**How to fix:** \(definition.howToFix)")
        }
        var list = urls.prefix(listedURLs).map { "- \($0)" }
        if kind.total > list.count {
            list.append("- …and \((kind.total - list.count).formatted()) more: [every URL in Crawlspace](\(crawl.link(for: kind)))")
        }
        parts.append((["**URLs**", ""] + list).joined(separator: "\n"))
        parts.append("[Open in Crawlspace](\(crawl.link(for: kind))) on the Mac that runs it, to see what's wrong on each URL "
            + "and check pages once they're fixed.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Exporting

    /// Files the crawl's issues into the severity lists of a destination, or, without one, all into
    /// `options.listID`, replacing every task an earlier export filed for the site there. ClickUp
    /// changes only here, when asked.
    public static func export(store: CrawlStore, destination: ClickUpDestination?, options: ClickUpExportOptions,
                              client: ClickUpClient, appAddress: String = "http://localhost:7777",
                              progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, ClickUpFolderExport.Resolved?) {
        progress?("Reading the issues…", 0)
        let kinds = try kinds(store: store).filter { options.groups.contains($0.group) }
        let crawl = Crawl(name: store.packageURL.deletingPathExtension().lastPathComponent,
                          host: CrawlScope(config: try store.loadConfig()).startHost, appAddress: appAddress)
        var urls: [String: [String]] = [:]
        for kind in kinds {
            let ids = try store.rowIDs(for: URLListQuery(filter: .issue(kind.code), sortColumn: .inlinks, ascending: false))
            urls[kind.code] = try store.rows(ids: Array(ids.prefix(listedURLs))).map(\.url)
        }

        var lists: [String: [Kind]] = [:]
        var resolved: ClickUpFolderExport.Resolved?
        if let destination {
            progress?("Finding the lists in \(destination.spaceName)…", 0)
            let found = try await ClickUpFolderExport.resolve(destination, groups: options.groups, client: client)
            resolved = found
            // Every list, even one with nothing in it this time: what an earlier export put there goes.
            for list in found.lists.values { lists[list] = [] }
            for kind in kinds {
                guard let list = found.lists[kind.group] else { continue }
                lists[list, default: []].append(kind)
            }
        } else {
            lists[options.listID] = kinds
        }

        var total = ClickUpExportResult()
        var done = 0
        for (list, share) in lists.sorted(by: { $0.key < $1.key }) {
            let start = done
            total.add(try await file(share, into: list, urls: urls, crawl: crawl, options: options, client: client) { title, fraction in
                progress?(title, (Double(start) + fraction * Double(share.count)) / Double(max(1, kinds.count)))
            })
            done += share.count
        }
        progress?("Done", 1)
        return (total, resolved)
    }

    /// Replaces what an earlier export filed for the site in one list with the crawl's issues.
    static func file(_ kinds: [Kind], into listID: String, urls: [String: [String]], crawl: Crawl,
                     options: ClickUpExportOptions, client: ClickUpClient,
                     progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> ClickUpExportResult {
        let siteTag = ClickUpOverview.tagSlug(crawl.host)
        var result = ClickUpExportResult()

        // Everything Crawlspace filed for the site here before, whatever the layout, goes: subtasks
        // first, then the tasks they were under.
        progress?("Removing the earlier export…", 0)
        let earlier = try await client.tasks(listID: listID)
            .filter { $0.tagNames.contains("crawlspace") && $0.tagNames.contains(siteTag) }
        for task in earlier.sorted(by: { ($0.parent == nil ? 1 : 0) < ($1.parent == nil ? 1 : 0) }) {
            try await client.deleteTask(id: task.id)
            result.tasksRemoved += 1
        }

        for (index, kind) in kinds.enumerated() {
            progress?(kind.title, Double(index) / Double(max(1, kinds.count)))
            var tags = ["crawlspace", siteTag, ClickUpOverview.tagSlug(kind.group.label)]
            if IssueCatalogue.definition(for: kind.code)?.category == .ecommerce { tags.append("e-commerce") }
            tags.append(contentsOf: options.extraTags)
            try await client.createTask(listID: listID, .init(
                name: kind.title, markdown: markdown(kind, urls: urls[kind.code] ?? [], crawl: crawl), tags: tags,
                priority: ClickUpOverview.priority(for: kind.severity)
            ))
            result.tasks += 1
        }
        return result
    }

    /// How many tasks an export of a crawl would come to, by group: for the export panel to say
    /// before it files anything.
    public static func preview(store: CrawlStore, groups: Set<IssueGroup>) throws -> [IssueGroup: Int] {
        var counts: [IssueGroup: Int] = [:]
        for kind in try kinds(store: store) where groups.contains(kind.group) { counts[kind.group, default: 0] += 1 }
        return counts
    }

    // MARK: - ClickUp

    /// ClickUp's priorities: 1 Urgent, 2 High, 3 Normal, 4 Low. Errors are things that are broken
    /// for whoever visits the page, so they go to the top band.
    static func priority(for severity: IssueSeverity) -> Int {
        switch severity {
        case .error: 1
        case .warning: 2
        case .notice: 4
        }
    }

    static func tagSlug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }
}
