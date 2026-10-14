import Audit
import CrawlCore
import Foundation
import Integrations
import Storage

/// What goes into ClickUp: an overview, one task per kind of problem under its severity — *Errors ›
/// H1: Multiple* — saying how many there are and how to fix them, from the crawl exported. The
/// detail, every page and image and link, is in that crawl in Crawlspace, where pages are checked
/// once they're fixed. Exporting again brings the tasks up to the crawl exported: a kind it didn't
/// find is closed, and one it finds again is opened again.
public enum ClickUpOverview {
    /// One kind of problem, as the overview counts it from a crawl's fixes.
    public struct Kind: Sendable, Hashable, Codable {
        public var code: String
        public var title: String
        public var severity: IssueSeverity
        public var total = 0
    }

    /// A crawl's problems by kind, worst first. A page or template that holds several issues counts
    /// each of them; it's the issues that are fixed.
    public static func kinds(store: CrawlStore) throws -> [Kind] {
        var byCode: [String: Kind] = [:]
        func count(_ code: String, _ severity: IssueSeverity) {
            var kind = byCode[code] ?? Kind(code: code, title: title(for: code), severity: severity)
            kind.severity = min(kind.severity, severity)
            kind.total += 1
            byCode[code] = kind
        }
        for unit in try FixBuilder.units(store: store, severities: Set(IssueSeverity.allCases))
        where !unit.heldOpen || !unit.issues.isEmpty || !unit.codes.isEmpty {
            if unit.issues.isEmpty {
                count(ClientSummaryBuilder.kindCode(of: unit), unit.severity)
            } else {
                for issue in unit.issues { count(ClientSummaryBuilder.kindCode(for: issue.code), issue.severity) }
            }
        }
        return byCode.values.sorted { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            if a.total != b.total { return a.total > b.total }
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

    /// Where a crawl is in Crawlspace, as a task links to it.
    struct Crawl: Sendable {
        var name: String
        var host: String
        var appAddress: String

        /// The crawl's list of a kind's pages, or its overview for the product cards.
        func link(for kind: Kind) -> String {
            let id = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            return IssueCatalogue.definition(for: kind.code) == nil
                ? "\(appAddress)/crawls/\(id)"
                : "\(appAddress)/crawls/\(id)?view=issue:\(kind.code)"
        }
    }

    static func markdown(_ kind: Kind, crawl: Crawl) -> String {
        var parts = ["**\(kind.total.formatted()) to fix** on \(crawl.host), as *\(crawl.name)* found."]
        if kind.code == ClientSummaryBuilder.productCards {
            parts.append("Product cards link to products through a collection's address (/collections/…/products/…) rather than the product's own, so each click takes an extra hop.")
            parts.append("**How to fix:** make the theme's product card link to the product's own address. On Shopify, drop `| within: collection` from `product.url | within: collection`. It's one snippet, so one change fixes every page.")
        } else if let definition = IssueCatalogue.definition(for: kind.code) {
            parts.append(definition.description)
            parts.append("**How to fix:** \(definition.howToFix)")
        }
        parts.append("Every page, image and link involved, with what's wrong where, is in that crawl in Crawlspace: "
            + "[open it](\(crawl.link(for: kind))) on the Mac that runs Crawlspace, and check pages there once they're fixed. "
            + "Exporting again brings this task up to date, and closes it once a crawl no longer finds the problem.")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Exporting

    /// Files the overview of a crawl into the severity lists of a destination, or, without one, all
    /// into `options.listID`. Each kind of problem the crawl found is a task; a task for a kind it
    /// didn't find is closed. ClickUp changes only here, when asked.
    public static func export(store: CrawlStore, destination: ClickUpDestination?, options: ClickUpExportOptions,
                              client: ClickUpClient, appAddress: String = "http://localhost:7777",
                              progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, ClickUpFolderExport.Resolved?) {
        progress?("Counting the problems…", 0)
        let kinds = try kinds(store: store).filter { options.severities.contains($0.severity) }
        let crawl = Crawl(name: store.packageURL.deletingPathExtension().lastPathComponent,
                          host: CrawlScope(config: try store.loadConfig()).startHost, appAddress: appAddress)
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
            total.add(try await file(share, into: list, crawl: crawl, options: options, client: client) { title, fraction in
                progress?(title, (Double(start) + fraction * Double(share.count)) / Double(max(1, kinds.count)))
            })
            done += share.count
        }
        progress?("Done", 1)
        return (total, resolved)
    }

    /// Files kinds into one list, reconciling with the overview tasks already there.
    static func file(_ kinds: [Kind], into listID: String, crawl: Crawl, options: ClickUpExportOptions,
                     client: ClickUpClient, progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> ClickUpExportResult {
        let siteTag = ClickUpOverview.tagSlug(crawl.host)
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
            let body = markdown(kind, crawl: crawl)
            let ref = ClickUpOverview.fingerprint(body)
            let markdown = body + "\n\nFound by Crawlspace. Covers \(kind.total.formatted()) \(kind.total == 1 ? "fix" : "fixes") · ref \(ref)"

            if let task = mine[kind.title] {
                if task.isClosed, let open = detail.openStatus {
                    try await client.updateTask(id: task.id, status: open, markdown: markdown)
                    try await client.comment(taskID: task.id, text: "Found again by \(crawl.name): \(kind.total.formatted()) to fix.")
                    result.tasksReopened += 1
                } else if ClickUpOverview.footer(of: task.description)?.ref != ref {
                    try await client.updateTask(id: task.id, markdown: markdown)
                    result.tasksUpdated += 1
                }
            } else {
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
                try await client.comment(taskID: task.id, text: "Not found by \(crawl.name).")
                result.tasksClosed += 1
            }
        }
        return result
    }

    /// How many overview tasks an export of a crawl would come to, by severity: for the export panel
    /// to say before it files anything.
    public static func preview(store: CrawlStore, severities: Set<IssueSeverity>) throws -> [IssueSeverity: Int] {
        var counts: [IssueSeverity: Int] = [:]
        for kind in try kinds(store: store) where severities.contains(kind.severity) { counts[kind.severity, default: 0] += 1 }
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
