import Audit
import CrawlCore
import Foundation
import Integrations
import Storage

/// Where a site's issues go in ClickUp, what an export did, and the formatting both the overview and
/// the fixes' descriptions share. The overview itself is `ClickUpOverview`; the detail it leaves out
/// lives in the site's `Worklist`.
public struct ClickUpExportOptions: Sendable {
    /// Where everything goes without a destination: one list for all three severities.
    public var listID: String
    public var severities: Set<IssueSeverity>
    public var extraTags: [String]

    public init(listID: String, severities: Set<IssueSeverity> = [.error, .warning], extraTags: [String] = []) {
        self.listID = listID
        self.severities = severities
        self.extraTags = extraTags
    }
}

public struct ClickUpExportResult: Sendable, Hashable {
    public var tasks = 0
    /// Issues filed under a page or template task, and ones closed because they've gone.
    public var subtasks = 0
    public var subtasksClosed = 0
    public var attachments = 0
    public var urlsInAttachments = 0
    /// What reconciling with a list that already has these tasks in it did.
    public var tasksUpdated = 0
    public var tasksClosed = 0
    public var tasksReopened = 0
    /// Copies already in ClickUp from an earlier export — reported, never filed again.
    public var duplicatesFound = 0
    /// Open tasks from the earlier one-task-per-issue layout, which this export leaves alone.
    public var legacyTasks = 0
    /// True when the crawl didn't cover the whole site, so not every task was closed on its word.
    public var closingHeldBack = false

    public var summary: String {
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks.formatted()) new \(tasks == 1 ? "task" : "tasks")") }
        if subtasks > 0 { parts.append("\(subtasks.formatted()) new \(subtasks == 1 ? "subtask" : "subtasks")") }
        if tasksUpdated > 0 { parts.append("\(tasksUpdated.formatted()) updated") }
        if tasksReopened > 0 { parts.append("\(tasksReopened.formatted()) reopened") }
        if tasksClosed > 0 { parts.append("\(tasksClosed.formatted()) closed") }
        if subtasksClosed > 0 { parts.append("\(subtasksClosed.formatted()) \(subtasksClosed == 1 ? "issue" : "issues") done") }
        if attachments > 0 { parts.append("\(attachments.formatted()) CSV \(attachments == 1 ? "attachment" : "attachments")") }
        var summary = parts.isEmpty ? "nothing to change" : parts.joined(separator: ", ")
        if closingHeldBack {
            summary += ". Some tasks were left open: this crawl didn't cover the whole site, so an issue missing from it "
            summary += "may just not have been reached"
        }
        if duplicatesFound > 0 {
            summary += ". \(duplicatesFound.formatted()) duplicate \(duplicatesFound == 1 ? "task" : "tasks") "
            summary += "from an earlier export are in the list and worth removing"
        }
        if legacyTasks > 0 {
            summary += ". \(legacyTasks.formatted()) open \(legacyTasks == 1 ? "task" : "tasks") from an earlier "
            summary += "layout \(legacyTasks == 1 ? "is" : "are") still in the list and no longer updated: worth archiving"
        }
        return summary
    }
}

extension ClickUpExportResult {
    /// Adds up the exports into each list.
    mutating func add(_ other: ClickUpExportResult) {
        tasks += other.tasks
        subtasks += other.subtasks
        subtasksClosed += other.subtasksClosed
        attachments += other.attachments
        urlsInAttachments += other.urlsInAttachments
        tasksUpdated += other.tasksUpdated
        tasksClosed += other.tasksClosed
        tasksReopened += other.tasksReopened
        duplicatesFound += other.duplicatesFound
        legacyTasks += other.legacyTasks
        closingHeldBack = closingHeldBack || other.closingHeldBack
    }
}

/// The list one topic's tasks go into: a list that's there (by id), or one to find or make by
/// name, in a folder or directly in the space.
public struct ClickUpListTarget: Codable, Sendable, Hashable {
    /// Set when it's a list that exists; nil to find or make it by name.
    public var listID: String?
    /// Nil for a list that sits directly in the space rather than in a folder.
    public var folderName: String?
    public var listName: String

    public init(listID: String? = nil, folderName: String?, listName: String) {
        self.listID = listID
        self.folderName = folderName
        self.listName = listName
    }

    /// "Crawlspace › Links", as the export window and messages show it.
    public var path: String { [folderName, listName].compactMap { $0 }.joined(separator: " › ") }

    /// The usual place for a topic: Crawlspace › Links, Images, … Errors, Warnings or Notices.
    public static func standard(for topic: ClickUpTopic) -> ClickUpListTarget {
        ClickUpListTarget(folderName: "Crawlspace", listName: topic.label)
    }
}

/// Where a site's issues go: a ClickUp space, and a list in it for each topic.
public struct ClickUpDestination: Codable, Sendable, Hashable {
    public var spaceID: String
    public var spaceName: String
    /// By topic ("links", "errors", …).
    public var targets: [String: ClickUpListTarget]

    public init(spaceID: String, spaceName: String, targets: [ClickUpTopic: ClickUpListTarget] = [:]) {
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.key.rawValue, $0.value) })
    }

    private enum CodingKeys: String, CodingKey { case spaceID, spaceName, targets, folderName }

    /// Earlier exports went by severity ("error", "warning", "notice"), which are now the lists of
    /// pages; before that, a single folder for all three.
    private static let severityKeys = ["error": ClickUpTopic.errors, "warning": .warnings, "notice": .notices]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceID = try c.decode(String.self, forKey: .spaceID)
        spaceName = try c.decodeIfPresent(String.self, forKey: .spaceName) ?? ""
        if let saved = try c.decodeIfPresent([String: ClickUpListTarget].self, forKey: .targets) {
            var targets: [String: ClickUpListTarget] = [:]
            for (key, target) in saved { targets[Self.severityKeys[key]?.rawValue ?? key] = target }
            self.targets = targets
        } else {
            let folder = try c.decodeIfPresent(String.self, forKey: .folderName) ?? "Crawlspace"
            targets = Dictionary(uniqueKeysWithValues: Self.severityKeys.values.map {
                ($0.rawValue, ClickUpListTarget(folderName: folder, listName: $0.label))
            })
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(spaceID, forKey: .spaceID)
        try c.encode(spaceName, forKey: .spaceName)
        try c.encode(targets, forKey: .targets)
    }

    public func target(for topic: ClickUpTopic) -> ClickUpListTarget {
        targets[topic.rawValue] ?? .standard(for: topic)
    }
}

/// Files a crawl's issues into the list chosen for each topic, finding lists by id or name and
/// making any folder or list that isn't there yet. Each list keeps its own tasks, so a later
/// export reconciles each one just as a single-list export does.
public enum ClickUpFolderExport {
    public struct Resolved: Sendable {
        public var lists: [ClickUpTopic: String]
        /// Where each topic went, for the result message.
        public var paths: [ClickUpTopic: String]
        /// What had to be made: "the Crawlspace folder", "the Crawlspace › Links list".
        public var created: [String]
    }

    /// The list for each topic, made where it doesn't exist. Names match regardless of case, so a
    /// list someone made as "links" is used rather than doubled.
    public static func resolve(_ destination: ClickUpDestination, topics: Set<ClickUpTopic>,
                               client: ClickUpClient) async throws -> Resolved {
        var created: [String] = []
        var folders = try await client.folders(space: destination.spaceID)
        var folderLists: [String: [ClickUpClient.TaskList]] = [:]
        var spaceLists: [ClickUpClient.TaskList]?
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame }

        func lists(in folder: ClickUpClient.Folder) async throws -> [ClickUpClient.TaskList] {
            if let known = folderLists[folder.id] { return known }
            var found = folder.lists ?? []
            if found.isEmpty { found = try await client.lists(folder: folder.id) }
            folderLists[folder.id] = found
            return found
        }

        var ids: [ClickUpTopic: String] = [:]
        var paths: [ClickUpTopic: String] = [:]
        for topic in ClickUpTopic.allCases where topics.contains(topic) {
            let target = destination.target(for: topic)
            paths[topic] = target.path

            // A list chosen by id that's still there.
            if let id = target.listID {
                if spaceLists == nil { spaceLists = try await client.lists(space: destination.spaceID) }
                let all = try await folders.asyncFlatMap { try await lists(in: $0) } + (spaceLists ?? [])
                if all.contains(where: { $0.id == id }) {
                    ids[topic] = id
                    continue
                }
            }

            if let folderName = target.folderName?.trimmingCharacters(in: .whitespaces), !folderName.isEmpty {
                let folder: ClickUpClient.Folder
                if let existing = folders.first(where: { same($0.name, folderName) }) {
                    folder = existing
                } else {
                    folder = try await client.createFolder(space: destination.spaceID, name: folderName)
                    folders.append(folder)
                    folderLists[folder.id] = []
                    created.append("the \(folderName) folder")
                }
                if let list = try await lists(in: folder).first(where: { same($0.name, target.listName) }) {
                    ids[topic] = list.id
                } else {
                    let list = try await client.createList(folder: folder.id, name: target.listName)
                    folderLists[folder.id, default: []].append(list)
                    ids[topic] = list.id
                    created.append("the \(target.path) list")
                }
            } else {
                if spaceLists == nil { spaceLists = try await client.lists(space: destination.spaceID) }
                if let list = spaceLists?.first(where: { same($0.name, target.listName) }) {
                    ids[topic] = list.id
                } else {
                    let list = try await client.createList(space: destination.spaceID, name: target.listName)
                    spaceLists?.append(list)
                    ids[topic] = list.id
                    created.append("the \(target.listName) list")
                }
            }
        }
        return Resolved(lists: ids, paths: paths, created: created)
    }

}

extension Array {
    func asyncFlatMap<T>(_ transform: (Element) async throws -> [T]) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result += try await transform(element) }
        return result
    }
}

public enum ClickUpExporter {
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

    static func severity(of task: ClickUpClient.ExistingTask) -> IssueSeverity? {
        IssueSeverity.allCases.first { task.tagNames.contains(tagSlug($0.label)) }
    }

    /// The count and ref a task was last written with, read back from its footer. ClickUp hands
    /// the description back as plain text, so this reads either.
    static func footer(of description: String?) -> (count: Int, ref: String)? {
        guard let description,
              let match = description.firstMatch(of: /Covers ([0-9][0-9,]*) (?:issues?|pages?|fix(?:es)?) · ref ([0-9a-f]{8})/),
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
        return String(String(hash, radix: 16).suffix(8)).leftPadded(to: 8)
    }

    /// The whole URL is unreadable as a task title, so the path leads and the host follows.
    static func pageName(for address: String, site: String) -> String {
        guard let url = URL(string: address) else { return address }
        let path = url.path().isEmpty ? "/" : url.path()
        let query = url.query().map { "?\($0)" } ?? ""
        let host = url.host() ?? site
        return host == site ? "\(path)\(query)" : "\(host)\(path)\(query)"
    }

    /// Affected URLs as a Markdown table: the page (a link), what on it is wrong, and where. When no
    /// page has anything more specific to say — an uppercase URL is just its URL — it's one column.
    static func urlTable(code: String, ids: [Int64], site: String, store: CrawlStore, rows limit: Int) throws -> String {
        let shown = Array(ids.prefix(max(1, limit)))
        var entries: [(page: String, wrong: String, place: String)] = []
        for row in try store.rows(ids: shown) {
            let evidence = try IssueEvidenceBuilder.evidence(for: code, urlID: row.id, store: store)
            var wrong = evidence.items.first?.text ?? ""
            let others = evidence.items.count + evidence.more - 1
            if others > 0 { wrong += " (and \(others) more)" }
            let link = "[\(cell(pageName(for: row.url, site: site)))](\(linkTarget(row.url)))"
            entries.append((link, cell(wrong), evidence.items.first?.position?.label ?? ""))
        }
        var lines = ["**Affected URLs**" + (ids.count > shown.count
            ? " — the first \(shown.count.formatted()) of \(ids.count.formatted()), most linked-to first" : ""), ""]
        if entries.allSatisfy({ $0.wrong.isEmpty && $0.place.isEmpty }) {
            lines += ["| URL |", "|---|"] + entries.map { "| \($0.page) |" }
        } else {
            lines += ["| URL | What's wrong | Where |", "|---|---|---|"]
                + entries.map { "| \($0.page) | \($0.wrong) | \($0.place) |" }
        }
        return lines.joined(separator: "\n")
    }

    /// Text safe inside a table cell: a pipe would start a new column and a newline a new row.
    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// A URL safe as a Markdown link target. Brackets and spaces end the link early — and one
    /// client's broken Liquid template put both into its URLs.
    static func linkTarget(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
