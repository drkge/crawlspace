import Audit
import CrawlCore
import Foundation
import Integrations
import Storage

/// What goes into ClickUp: an overview, one task per kind of problem under its severity — *Errors ›
/// H1: Multiple* — saying how many there are, how many are done, and how to fix them. The detail,
/// every page and image and link, lives in the site's list of fixes in Crawlspace, where it's ticked
/// off and checked; a task here closes by itself once every fix of its kind is confirmed.
public enum ClickUpOverview {
    /// One kind of problem, as the overview counts it from the site's fixes.
    public struct Kind: Sendable, Hashable {
        public var code: String
        public var title: String
        public var severity: IssueSeverity
        public var total = 0
        public var confirmed = 0
        public var ticked = 0
        public var lastConfirmedBy: String?
        public var lastConfirmedAt: Date?

        public var toDo: Int { total - confirmed - ticked }
        public var isDone: Bool { total > 0 && confirmed == total }
    }

    /// The lists an overview is filed into: one per severity.
    public static let topics: [ClickUpTopic] = [.errors, .warnings, .notices]

    /// The site's fixes by kind, worst first. A page or template that holds several issues counts
    /// each of them; it's the issues that are fixed.
    public static func kinds(in worklist: Worklist) throws -> [Kind] {
        let items = try worklist.items()
        let parents = Set(items.compactMap(\.parentKey))
        var byCode: [String: Kind] = [:]
        for item in items where !parents.contains(item.key) {
            var kind = byCode[item.kind] ?? Kind(code: item.kind, title: title(for: item.kind), severity: item.severity)
            kind.severity = min(kind.severity, item.severity)
            kind.total += 1
            switch item.status {
            case .confirmed:
                kind.confirmed += 1
                if let at = item.confirmedAt, kind.lastConfirmedAt.map({ at > $0 }) ?? true {
                    kind.lastConfirmedAt = at
                    kind.lastConfirmedBy = item.confirmedBy
                }
            case .ticked: kind.ticked += 1
            case .open, .reopened: break
            }
            byCode[item.kind] = kind
        }
        return byCode.values.sorted { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            if a.toDo != b.toDo { return a.toDo > b.toDo }
            return a.title < b.title
        }
    }

    /// A kind's task name: the catalogue's title, the shared name of a pair measured two ways, or
    /// the product cards.
    public static func title(for code: String) -> String {
        if code == ClientSummaryBuilder.productCards { return "Product cards: links through collection addresses" }
        if let pair = ClickUpUnitBuilder.pair(of: code) { return pair.name }
        return ClickUpUnitBuilder.title(code)
    }

    static func markdown(_ kind: Kind, host: String, appAddress: String) -> String {
        var progress = "**\(kind.toDo.formatted()) to fix**"
        if kind.ticked > 0 { progress += ", \(kind.ticked.formatted()) done and waiting for a check" }
        progress += ", \(kind.confirmed.formatted()) confirmed fixed — \(kind.total.formatted()) found on \(host) so far."
        if kind.isDone { progress = "**All \(kind.total.formatted()) confirmed fixed** on \(host)." }
        var parts = [progress]
        if kind.code == ClientSummaryBuilder.productCards {
            parts.append("Product cards link to products through a collection's address (/collections/…/products/…) rather than the product's own, so each click takes an extra hop.")
            parts.append("**How to fix:** make the theme's product card link to the product's own address. On Shopify, drop `| within: collection` from `product.url | within: collection`. It's one snippet, so one change fixes every page.")
        } else if let definition = IssueCatalogue.definition(for: kind.code) {
            parts.append(definition.description)
            parts.append("**How to fix:** \(definition.howToFix)")
        }
        parts.append("Every page, image and link involved, with what's wrong where, is in **Crawlspace › Fixes** for \(host): "
            + "[open the list](\(appAddress)/sites/\(host)/fixes) on the Mac that runs Crawlspace. Tick fixes there as they're done "
            + "and check them; this task closes once they're all confirmed.")
        if let by = kind.lastConfirmedBy, let at = kind.lastConfirmedAt {
            parts.append("Last confirmed by *\(by)* on \(at.formatted(date: .long, time: .omitted)).")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Exporting

    /// Brings the site's fixes up to date with a crawl, then files the overview.
    public static func export(store: CrawlStore, destination: ClickUpDestination?, options: ClickUpExportOptions,
                              client: ClickUpClient, appAddress: String = "http://localhost:7777",
                              progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, ClickUpFolderExport.Resolved?) {
        let host = Worklist.host(of: try store.loadConfig())
        let worklist = try Worklist.open(host: host)
        progress?("Updating the list of fixes…", 0)
        try worklist.update(from: store, isCheck: false)
        return try await sync(worklist, destination: destination, options: options, client: client,
                              appAddress: appAddress, progress: progress)
    }

    /// Files the overview from the site's fixes as they stand: after an export, a check, or a crawl.
    /// Into the severity lists of a destination, or, without one, all into `options.listID`.
    public static func sync(_ worklist: Worklist, destination: ClickUpDestination?, options: ClickUpExportOptions,
                            client: ClickUpClient, appAddress: String = "http://localhost:7777",
                            progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, ClickUpFolderExport.Resolved?) {
        let kinds = try kinds(in: worklist).filter { options.severities.contains($0.severity) }
        var lists: [String: [Kind]] = [:]
        var resolved: ClickUpFolderExport.Resolved?
        if let destination {
            let wanted = Set(topics.filter { $0.pageSeverity.map(options.severities.contains) ?? false })
            progress?("Finding the lists in \(destination.spaceName)…", 0)
            let found = try await ClickUpFolderExport.resolve(destination, topics: wanted, client: client)
            resolved = found
            for kind in kinds {
                guard let list = found.lists[ClickUpTopic.pages(kind.severity)] else { continue }
                lists[list, default: []].append(kind)
            }
        } else {
            lists[options.listID] = kinds
        }

        var total = ClickUpExportResult()
        var done = 0
        for (list, share) in lists.sorted(by: { $0.key < $1.key }) {
            let start = done
            total.add(try await file(share, into: list, host: worklist.host, options: options, client: client,
                                     appAddress: appAddress) { title, fraction in
                progress?(title, (Double(start) + fraction * Double(share.count)) / Double(max(1, kinds.count)))
            })
            done += share.count
        }
        progress?("Done", 1)
        return (total, resolved)
    }

    /// Files kinds into one list, reconciling with the overview tasks already there.
    static func file(_ kinds: [Kind], into listID: String, host: String, options: ClickUpExportOptions,
                     client: ClickUpClient, appAddress: String,
                     progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> ClickUpExportResult {
        let siteTag = ClickUpExporter.tagSlug(host)
        let detail = try await client.list(id: listID)
        let existing = try await client.tasks(listID: listID)
        var result = ClickUpExportResult()

        var mine: [String: ClickUpClient.ExistingTask] = [:]
        for task in existing where task.parent == nil && task.tagNames.contains("crawlspace") && task.tagNames.contains(siteTag) {
            guard task.tagNames.contains(overviewTag) else {
                // Filed by an earlier layout: left alone, but worth knowing about.
                if !task.isClosed { result.legacyTasks += 1 }
                continue
            }
            if mine[task.name] != nil { result.duplicatesFound += 1 }
            mine[task.name] = task
        }

        for (index, kind) in kinds.enumerated() {
            progress?(kind.title, Double(index) / Double(max(1, kinds.count)))
            let body = markdown(kind, host: host, appAddress: appAddress)
            let ref = ClickUpExporter.fingerprint(body)
            let markdown = body + "\n\nFound by Crawlspace. Covers \(kind.total.formatted()) \(kind.total == 1 ? "fix" : "fixes") · ref \(ref)"

            if let task = mine[kind.title] {
                let before = ClickUpExporter.footer(of: task.description)
                if kind.isDone, !task.isClosed, let closed = detail.closedStatus {
                    try await client.updateTask(id: task.id, status: closed, markdown: markdown)
                    try await client.comment(taskID: task.id, text: "All \(kind.total.formatted()) confirmed fixed"
                        + (kind.lastConfirmedBy.map { " by \($0)" } ?? "") + ".")
                    result.tasksClosed += 1
                } else if !kind.isDone, task.isClosed, let open = detail.openStatus {
                    try await client.updateTask(id: task.id, status: open, markdown: markdown)
                    try await client.comment(taskID: task.id, text: "Back: \(kind.toDo.formatted()) to fix again.")
                    result.tasksReopened += 1
                } else if before?.ref != ref {
                    try await client.updateTask(id: task.id, markdown: markdown)
                    result.tasksUpdated += 1
                }
            } else if !kind.isDone {
                var tags = ["crawlspace", siteTag, ClickUpExporter.tagSlug(kind.severity.label), overviewTag]
                if IssueCatalogue.definition(for: kind.code)?.category == .ecommerce || kind.code == ClientSummaryBuilder.productCards {
                    tags.append("e-commerce")
                }
                tags.append(contentsOf: options.extraTags)
                try await client.createTask(listID: listID, .init(
                    name: kind.title, markdown: markdown, tags: tags,
                    priority: ClickUpExporter.priority(for: kind.severity)
                ))
                result.tasks += 1
            }
        }
        return result
    }

    /// How many overview tasks an export of a crawl would come to, by severity, without touching
    /// the site's list of fixes: for the export panel to say before it files anything.
    public static func preview(store: CrawlStore, severities: Set<IssueSeverity>) throws -> [IssueSeverity: Int] {
        let units = try ClickUpUnitBuilder.units(store: store, severities: Set(IssueSeverity.allCases))
        let rows = try Worklist.rows(for: units, store: store)
        let parents = Set(rows.compactMap(\.parentKey))
        var worst: [String: IssueSeverity] = [:]
        for row in rows where !parents.contains(row.key) { worst[row.kind] = min(worst[row.kind] ?? .notice, row.severity) }
        var counts: [IssueSeverity: Int] = [:]
        for severity in worst.values where severities.contains(severity) { counts[severity, default: 0] += 1 }
        return counts
    }

    /// A line for the export panel saying what each severity's list holds.
    public static func hint(for topic: ClickUpTopic) -> String {
        let kind = switch topic {
        case .errors: "error"
        case .warnings: "warning"
        default: "notice"
        }
        return "One task per kind of \(kind), with how many are left. The pages themselves are in Crawlspace › Fixes."
    }

    /// The tag that marks an overview task, telling it from tasks earlier layouts filed.
    static let overviewTag = "overview"
}
