import Audit
import CrawlCore
import Foundation
import Integrations
import Storage

/// What goes into ClickUp: an overview, one task per kind of problem under its severity — *Errors ›
/// H1: Multiple* — saying how many there are, how many are done, and how to fix them. The detail,
/// every page and image and link, lives in the crawl's list of fixes in Crawlspace, where it's marked
/// done and checked. It's filed when exported, from the crawl exported: a task closes once every fix
/// of its kind is verified, or when that crawl didn't find its kind.
public enum ClickUpOverview {
    /// One kind of problem, as the overview counts it from a crawl's fixes.
    public struct Kind: Sendable, Hashable, Codable {
        public var code: String
        public var title: String
        public var severity: IssueSeverity
        public var total = 0
        public var verified = 0
        public var done = 0
        public var lastVerifiedBy: String?
        public var lastVerifiedAt: Date?

        public var toDo: Int { total - verified - done }
        public var isDone: Bool { total > 0 && verified == total }
    }


    /// A crawl's fixes by kind, worst first. A page or template that holds several issues counts
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
            case .verified:
                kind.verified += 1
                if let at = item.verifiedAt, kind.lastVerifiedAt.map({ at > $0 }) ?? true {
                    kind.lastVerifiedAt = at
                    kind.lastVerifiedBy = item.verifiedBy
                }
            case .done: kind.done += 1
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
        if let pair = FixBuilder.pair(of: code) { return pair.name }
        return FixBuilder.title(code)
    }

    static func markdown(_ kind: Kind, host: String, appAddress: String) -> String {
        var progress = "**\(kind.toDo.formatted()) to fix**"
        if kind.done > 0 { progress += ", \(kind.done.formatted()) done and waiting for a check" }
        progress += ", \(kind.verified.formatted()) verified fixed — \(kind.total.formatted()) found on \(host) so far."
        if kind.isDone { progress = "**All \(kind.total.formatted()) verified fixed** on \(host)." }
        var parts = [progress]
        if kind.code == ClientSummaryBuilder.productCards {
            parts.append("Product cards link to products through a collection's address (/collections/…/products/…) rather than the product's own, so each click takes an extra hop.")
            parts.append("**How to fix:** make the theme's product card link to the product's own address. On Shopify, drop `| within: collection` from `product.url | within: collection`. It's one snippet, so one change fixes every page.")
        } else if let definition = IssueCatalogue.definition(for: kind.code) {
            parts.append(definition.description)
            parts.append("**How to fix:** \(definition.howToFix)")
        }
        parts.append("Every page, image and link involved, with what's wrong where, is in **Crawlspace › Fixes** for \(host): "
            + "[open the list](\(appAddress)/sites/\(host)/fixes) on the Mac that runs Crawlspace. Mark fixes done there as they're made "
            + "and check them; this task closes once they're all verified.")
        if let by = kind.lastVerifiedBy, let at = kind.lastVerifiedAt {
            parts.append("Last verified by *\(by)* on \(at.formatted(date: .long, time: .omitted)).")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Exporting

    /// Files the overview of a crawl's fixes, as they stand: what it found, and what checks of it
    /// have verified. ClickUp changes only here, when asked.
    public static func export(store: CrawlStore, destination: ClickUpDestination?, options: ClickUpExportOptions,
                              client: ClickUpClient, appAddress: String = "http://localhost:7777",
                              progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, ClickUpFolderExport.Resolved?) {
        let worklist = try Worklist.open(for: store)
        progress?("Updating the list of fixes…", 0)
        try worklist.update(from: store, isCheck: false)
        return try await sync(worklist, crawl: store.packageURL.deletingPathExtension().lastPathComponent,
                              destination: destination, options: options, client: client, appAddress: appAddress, progress: progress)
    }

    /// Files the overview from a crawl's fixes, into the severity lists of a destination, or,
    /// without one, all into `options.listID`. Each kind of problem the crawl found is a task; a
    /// task for a kind it didn't find is closed.
    public static func sync(_ worklist: Worklist, crawl: String, destination: ClickUpDestination?, options: ClickUpExportOptions,
                            client: ClickUpClient, appAddress: String = "http://localhost:7777",
                            progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, ClickUpFolderExport.Resolved?) {
        let kinds = try kinds(in: worklist).filter { options.severities.contains($0.severity) }
        var lists: [String: [Kind]] = [:]
        var resolved: ClickUpFolderExport.Resolved?
        if let destination {
            progress?("Finding the lists in \(destination.spaceName)…", 0)
            let found = try await ClickUpFolderExport.resolve(destination, severities: options.severities, client: client)
            resolved = found
            // Every list, even one with nothing in it this time: its tasks may need closing.
            for list in found.lists.values { lists[list] = [] }
            for kind in kinds {
                guard let list = found.lists[kind.severity] else { continue }
                lists[list, default: []].append(kind)
            }
        } else {
            lists[options.listID] = kinds
        }

        var total = ClickUpExportResult()
        var done = 0
        for (list, share) in lists.sorted(by: { $0.key < $1.key }) {
            let start = done
            total.add(try await file(share, into: list, host: worklist.host, crawl: crawl, options: options, client: client,
                                     appAddress: appAddress) { title, fraction in
                progress?(title, (Double(start) + fraction * Double(share.count)) / Double(max(1, kinds.count)))
            })
            done += share.count
        }
        progress?("Done", 1)
        return (total, resolved)
    }

    /// Files kinds into one list, reconciling with the overview tasks already there.
    static func file(_ kinds: [Kind], into listID: String, host: String, crawl: String, options: ClickUpExportOptions,
                     client: ClickUpClient, appAddress: String,
                     progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> ClickUpExportResult {
        let siteTag = ClickUpOverview.tagSlug(host)
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
            let ref = ClickUpOverview.fingerprint(body)
            let markdown = body + "\n\nFound by Crawlspace. Covers \(kind.total.formatted()) \(kind.total == 1 ? "fix" : "fixes") · ref \(ref)"

            if let task = mine[kind.title] {
                let before = ClickUpOverview.footer(of: task.description)
                if kind.isDone, !task.isClosed, let closed = detail.closedStatus {
                    try await client.updateTask(id: task.id, status: closed, markdown: markdown)
                    try await client.comment(taskID: task.id, text: "All \(kind.total.formatted()) verified fixed"
                        + (kind.lastVerifiedBy.map { " by \($0)" } ?? "") + ".")
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
                var tags = ["crawlspace", siteTag, ClickUpOverview.tagSlug(kind.severity.label), overviewTag]
                if IssueCatalogue.definition(for: kind.code)?.category == .ecommerce || kind.code == ClientSummaryBuilder.productCards {
                    tags.append("e-commerce")
                }
                tags.append(contentsOf: options.extraTags)
                try await client.createTask(listID: listID, .init(
                    name: kind.title, markdown: markdown, tags: tags,
                    priority: ClickUpOverview.priority(for: kind.severity)
                ))
                result.tasks += 1
            }
        }
        // A kind the crawl didn't find is gone.
        let filed = Set(kinds.map(\.title))
        if let closed = detail.closedStatus {
            for (name, task) in mine where !filed.contains(name) && !task.isClosed {
                try await client.updateTask(id: task.id, status: closed)
                try await client.comment(taskID: task.id, text: "Not found by \(crawl).")
                result.tasksClosed += 1
            }
        }
        return result
    }

    /// How many overview tasks an export of a crawl would come to, by severity, without touching
    /// its list of fixes: for the export panel to say before it files anything.
    public static func preview(store: CrawlStore, severities: Set<IssueSeverity>) throws -> [IssueSeverity: Int] {
        let units = try FixBuilder.units(store: store, severities: Set(IssueSeverity.allCases))
        let rows = try Worklist.rows(for: units, store: store)
        let parents = Set(rows.compactMap(\.parentKey))
        var worst: [String: IssueSeverity] = [:]
        for row in rows where !parents.contains(row.key) { worst[row.kind] = min(worst[row.kind] ?? .notice, row.severity) }
        var counts: [IssueSeverity: Int] = [:]
        for severity in worst.values where severities.contains(severity) { counts[severity, default: 0] += 1 }
        return counts
    }

    /// The tag that marks an overview task, telling it from tasks earlier layouts filed.
    static let overviewTag = "overview"

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

    /// The count and ref a task was last written with, read back from its footer. ClickUp hands
    /// the description back as plain text, so this reads either.
    static func footer(of description: String?) -> (count: Int, ref: String)? {
        guard let description,
              let match = description.firstMatch(of: /Covers ([0-9][0-9,]*) fix(?:es)? · ref ([0-9a-f]{8})/),
              let count = Int(match.1.replacingOccurrences(of: ",", with: "")) else { return nil }
        return (count, String(match.2))
    }

    /// A short, stable digest of a description, so an unchanged task isn't rewritten. FNV-1a:
    /// Swift's own hashing is seeded afresh on every run.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        let digits = String(String(hash, radix: 16).suffix(8))
        return String(repeating: "0", count: 8 - digits.count) + digits
    }
}
