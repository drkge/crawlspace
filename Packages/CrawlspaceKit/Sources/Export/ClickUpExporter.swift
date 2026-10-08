import Audit
import CrawlCore
import Foundation
import Integrations
import Storage

/// Files what a crawl found as ClickUp tasks: one task per issue, a subtask for each page it
/// affects, and the rest of the pages attached as a CSV.
///
/// The cap matters. A real site produces thousands of affected URLs — one client shop had 41 issue
/// types across 5,081 of them — and ClickUp allows 100 requests a minute on most plans, so filing
/// every page as a subtask would take the best part of an hour and leave a list nobody can work
/// in. The pages that do become subtasks are the ones with the most internal links pointing at
/// them, which is the closest thing the crawl knows to "this page matters".
public struct ClickUpExportOptions: Sendable {
    public var listID: String
    public var severities: Set<IssueSeverity>
    /// Most subtasks per issue, or 0 for every affected page — the same "0 means no limit" the
    /// crawl settings use. Everything above the cap still goes in the CSV, but a CSV is a document
    /// rather than work, so a team that actions tasks one by one wants no cap at all.
    public var subtaskLimit: Int
    public var attachFullList: Bool
    public var extraTags: [String]
    /// ClickUp refuses more than 1,000 subtasks under one task (ITEM_327). An issue on more pages
    /// than that is filed as a table instead.
    public var maxSubtasksPerTask = 1_000
    /// Severities filed as one task holding a table of affected URLs, rather than a subtask per
    /// page. Notices by default: reference material fixed in bulk, where 3,500 subtasks would take
    /// ClickUp the best part of an hour to accept and nobody would tick them off one by one.
    public var tableSeverities: Set<IssueSeverity>
    /// Rows written into a task's table; the attached CSV holds every one.
    public var tableRows = 200

    public init(listID: String, severities: Set<IssueSeverity> = [.error, .warning],
                subtaskLimit: Int = 0, attachFullList: Bool = true, extraTags: [String] = [],
                tableSeverities: Set<IssueSeverity> = [.notice]) {
        self.tableSeverities = tableSeverities
        self.listID = listID
        self.severities = severities
        self.subtaskLimit = subtaskLimit
        self.attachFullList = attachFullList
        self.extraTags = extraTags
    }
}

public struct ClickUpExportResult: Sendable, Hashable {
    public var tasks = 0
    public var subtasks = 0
    public var attachments = 0
    public var urlsCovered = 0
    public var urlsInAttachments = 0
    /// What reconciling with a list that already has these tasks in it did.
    public var tasksUpdated = 0
    public var tasksClosed = 0
    public var tasksReopened = 0
    public var subtasksClosed = 0
    /// Copies already in ClickUp from an earlier export — reported, never filed again.
    public var duplicatesFound = 0
    /// Issues with more affected pages than ClickUp allows under one task, filed as tables.
    public var issuesOverCeiling = 0
    /// Issues filed as a single task with a table of URLs.
    public var tables = 0
    /// True when the crawl didn't cover the whole site, so no task was closed on its word.
    public var closingHeldBack = false

    public var summary: String {
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks.formatted()) new \(tasks == 1 ? "task" : "tasks")") }
        if subtasks > 0 { parts.append("\(subtasks.formatted()) new \(subtasks == 1 ? "subtask" : "subtasks")") }
        if tables > 0 { parts.append("\(tables.formatted()) filed as \(tables == 1 ? "a table" : "tables")") }
        if tasksUpdated > 0 { parts.append("\(tasksUpdated.formatted()) updated") }
        if tasksReopened > 0 { parts.append("\(tasksReopened.formatted()) reopened") }
        if tasksClosed > 0 { parts.append("\(tasksClosed.formatted()) closed") }
        if subtasksClosed > 0 { parts.append("\(subtasksClosed.formatted()) \(subtasksClosed == 1 ? "page" : "pages") done") }
        if attachments > 0 { parts.append("\(attachments.formatted()) CSV \(attachments == 1 ? "attachment" : "attachments")") }
        var summary = parts.isEmpty ? "nothing to change" : parts.joined(separator: ", ")
        if issuesOverCeiling > 0 {
            summary += ". \(issuesOverCeiling) \(issuesOverCeiling == 1 ? "issue has" : "issues have") more pages "
            summary += "than ClickUp's 1,000-subtask limit, so \(issuesOverCeiling == 1 ? "it was" : "they were") filed as a table"
        }
        if closingHeldBack {
            summary += ". No tasks were closed: this crawl didn't cover the whole site, so an issue missing from it "
            summary += "may just not have been reached"
        }
        if duplicatesFound > 0 {
            summary += ". \(duplicatesFound.formatted()) duplicate \(duplicatesFound == 1 ? "task" : "tasks") "
            summary += "from an earlier export are in the list and worth removing"
        }
        return summary
    }
}

extension ClickUpExportResult {
    /// Adds up the exports into each severity's list.
    mutating func add(_ other: ClickUpExportResult) {
        tasks += other.tasks
        subtasks += other.subtasks
        attachments += other.attachments
        urlsCovered += other.urlsCovered
        urlsInAttachments += other.urlsInAttachments
        tasksUpdated += other.tasksUpdated
        tasksClosed += other.tasksClosed
        tasksReopened += other.tasksReopened
        subtasksClosed += other.subtasksClosed
        duplicatesFound += other.duplicatesFound
        issuesOverCeiling += other.issuesOverCeiling
        tables += other.tables
        closingHeldBack = closingHeldBack || other.closingHeldBack
    }
}

/// The list one severity's issues go into: a list that's there (by id), or one to find or make by
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

    /// "Crawlspace › Errors", as the export window and messages show it.
    public var path: String { [folderName, listName].compactMap { $0 }.joined(separator: " › ") }

    /// The usual place for a severity: Crawlspace › Errors, Warnings or Notices.
    public static func standard(for severity: IssueSeverity) -> ClickUpListTarget {
        ClickUpListTarget(folderName: "Crawlspace", listName: severity.label)
    }
}

/// Where a site's issues go: a ClickUp space, and a list in it for each severity.
public struct ClickUpDestination: Codable, Sendable, Hashable {
    public var spaceID: String
    public var spaceName: String
    /// By severity name ("error", "warning", "notice").
    public var targets: [String: ClickUpListTarget]

    public init(spaceID: String, spaceName: String, targets: [IssueSeverity: ClickUpListTarget] = [:]) {
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.key.name, $0.value) })
    }

    private enum CodingKeys: String, CodingKey { case spaceID, spaceName, targets, folderName }

    /// Also reads the earlier shape, a single folder for all three, as that folder's lists.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceID = try c.decode(String.self, forKey: .spaceID)
        spaceName = try c.decodeIfPresent(String.self, forKey: .spaceName) ?? ""
        if let targets = try c.decodeIfPresent([String: ClickUpListTarget].self, forKey: .targets) {
            self.targets = targets
        } else {
            let folder = try c.decodeIfPresent(String.self, forKey: .folderName) ?? "Crawlspace"
            targets = Dictionary(uniqueKeysWithValues: IssueSeverity.allCases.map {
                ($0.name, ClickUpListTarget(folderName: folder, listName: $0.label))
            })
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(spaceID, forKey: .spaceID)
        try c.encode(spaceName, forKey: .spaceName)
        try c.encode(targets, forKey: .targets)
    }

    public func target(for severity: IssueSeverity) -> ClickUpListTarget {
        targets[severity.name] ?? .standard(for: severity)
    }
}

/// Files a crawl's issues into the list chosen for each severity, finding lists by id or name and
/// making any folder or list that isn't there yet. Each list keeps its own tasks, so a later
/// export reconciles each one just as a single-list export does.
public enum ClickUpFolderExport {
    public struct Resolved: Sendable {
        public var lists: [IssueSeverity: String]
        /// Where each severity went, for the result message.
        public var paths: [IssueSeverity: String]
        /// What had to be made: "the Crawlspace folder", "the Crawlspace › Notices list".
        public var created: [String]
    }

    /// The list for each severity, made where it doesn't exist. Names match regardless of case, so
    /// a list someone made as "errors" is used rather than doubled.
    public static func resolve(_ destination: ClickUpDestination, severities: Set<IssueSeverity>,
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

        var ids: [IssueSeverity: String] = [:]
        var paths: [IssueSeverity: String] = [:]
        for severity in IssueSeverity.allCases where severities.contains(severity) {
            let target = destination.target(for: severity)
            paths[severity] = target.path

            // A list chosen by id that's still there.
            if let id = target.listID {
                if spaceLists == nil { spaceLists = try await client.lists(space: destination.spaceID) }
                let all = try await folders.asyncFlatMap { try await lists(in: $0) } + (spaceLists ?? [])
                if all.contains(where: { $0.id == id }) {
                    ids[severity] = id
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
                    ids[severity] = list.id
                } else {
                    let list = try await client.createList(folder: folder.id, name: target.listName)
                    folderLists[folder.id, default: []].append(list)
                    ids[severity] = list.id
                    created.append("the \(target.path) list")
                }
            } else {
                if spaceLists == nil { spaceLists = try await client.lists(space: destination.spaceID) }
                if let list = spaceLists?.first(where: { same($0.name, target.listName) }) {
                    ids[severity] = list.id
                } else {
                    let list = try await client.createList(space: destination.spaceID, name: target.listName)
                    spaceLists?.append(list)
                    ids[severity] = list.id
                    created.append("the \(target.listName) list")
                }
            }
        }
        return Resolved(lists: ids, paths: paths, created: created)
    }

    /// Exports one severity at a time into its list, with progress across the whole export.
    public static func export(store: CrawlStore, destination: ClickUpDestination, options: ClickUpExportOptions,
                              client: ClickUpClient,
                              progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, Resolved) {
        progress?("Finding the lists in \(destination.spaceName)…", 0)
        let resolved = try await resolve(destination, severities: options.severities, client: client)
        let severities = IssueSeverity.allCases.filter { resolved.lists[$0] != nil }
        var total = ClickUpExportResult()
        for (index, severity) in severities.enumerated() {
            var single = options
            single.listID = resolved.lists[severity]!
            single.severities = [severity]
            let share = 1.0 / Double(severities.count)
            let path = resolved.paths[severity] ?? severity.label
            let result = try await ClickUpExporter.export(store: store, options: single, client: client) { title, fraction in
                progress?("\(path): \(title)", (Double(index) + fraction) * share)
            }
            total.add(result)
        }
        return (total, resolved)
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

    static func tags(site: String, severity: IssueSeverity, category: IssueCategory? = nil, extra: [String]) -> [String] {
        var tags = ["crawlspace", tagSlug(site), tagSlug(severity.label)]
        // So whoever looks after the catalogue can filter to their own tasks.
        if category == .ecommerce { tags.append("e-commerce") }
        tags.append(contentsOf: extra)
        return tags
    }

    static func tagSlug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    public static func export(
        store: CrawlStore,
        options: ClickUpExportOptions,
        client: ClickUpClient,
        progress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> ClickUpExportResult {
        let counts = try store.issueCounts()
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let siteTag = tagSlug(site)
        let crawlName = store.packageURL.deletingPathExtension().lastPathComponent

        // Errors first, and within a severity the issue affecting the most pages.
        let present = IssueCatalogue.all.filter { definition in
            let count: Int = counts[definition.code] ?? 0
            return count > 0 && options.severities.contains(definition.severity)
        }
        let definitions = present.sorted { left, right in
            if left.severity != right.severity { return left.severity < right.severity }
            let leftCount: Int = counts[left.code] ?? 0
            let rightCount: Int = counts[right.code] ?? 0
            return leftCount > rightCount
        }

        // What is already in the list, so a second export updates its own tasks rather than
        // filing a second copy of everything. Tasks are matched by name among those tagged for
        // this site, which survives a rebuilt Mac and doesn't need a custom field.
        let detail = try await client.list(id: options.listID)
        let existing = try await client.tasks(listID: options.listID)
        var result = ClickUpExportResult()

        // Closing is only as trustworthy as the crawl. A task closes when its issue is gone from a
        // crawl that covered the whole site; a subtask when its page was crawled again and came
        // back clean. Anything the crawl didn't reach — stopped early, capped by a URL limit, or
        // outside its settings — stays open rather than being marked fixed.
        let coveredWholeSite = try store.status() == .completed
            && store.crawledCount() < config.maxURLs
        let recrawled = Set(try store.rows(ids: store.rowIDs(for: URLListQuery(filter: .internalAll)))
            .map { subtaskName(for: $0.url, site: site) })
        let titleToCode = Dictionary(IssueCatalogue.all.map { ("\($0.category.rawValue): \($0.title)", $0.code) },
                                     uniquingKeysWith: { first, _ in first })

        var mine: [String: ClickUpClient.ExistingTask] = [:]
        var children: [String: [ClickUpClient.ExistingTask]] = [:]
        for task in existing {
            if let parent = task.parent {
                children[parent, default: []].append(task)
            } else if task.tagNames.contains("crawlspace"), task.tagNames.contains(siteTag) {
                if mine[task.name] != nil { result.duplicatesFound += 1 }
                mine[task.name] = task
            }
        }

        var handled: Set<String> = []

        for (index, definition) in definitions.enumerated() {
            let title = "\(definition.category.rawValue): \(definition.title)"
            handled.insert(title)
            let count = counts[definition.code] ?? 0
            progress?(title, Double(index) / Double(max(1, definitions.count)))

            let ids = try store.rowIDs(for: URLListQuery(filter: .issue(definition.code),
                                                        sortColumn: .inlinks, ascending: false))
            // Every affected page, so a page that merely fell outside the cap isn't mistaken for
            // one that has been fixed.
            let affected = Set(try store.rows(ids: ids).map { subtaskName(for: $0.url, site: site) })
            // Whether one change in the theme clears most of these — worth saying at the top of the
            // task, before anyone opens 500 subtasks. Judged across several pages, not the first
            // alone: the first can easily be one that lacks the shared link.
            let lead = try templateLead(code: definition.code, ids: Array(ids.prefix(10)), store: store)

            // A table rather than subtasks: for the severities chosen, and for anything with more
            // pages than ClickUp will take as subtasks under one task.
            let tooBig = ids.count > options.maxSubtasksPerTask
            let asTable = options.tableSeverities.contains(definition.severity) || tooBig
            if tooBig, !options.tableSeverities.contains(definition.severity) { result.issuesOverCeiling += 1 }
            let table = asTable
                ? try urlTable(code: definition.code, ids: ids, site: site, store: store, rows: options.tableRows)
                : nil
            let markdown = description(definition, count: count, site: site, crawl: crawlName,
                                       showing: asTable || options.subtaskLimit <= 0
                                           ? ids.count : min(options.subtaskLimit, ids.count),
                                       lead: lead, table: table)

            let parentID: String
            var isNew = false
            var countChanged = true
            if let already = mine[title] {
                parentID = already.id
                let before = previousCount(in: already.description)
                countChanged = before != count
                try await reconcileParent(already, count: count, before: before, crawl: crawlName,
                                          markdown: markdown, refresh: asTable, detail: detail,
                                          client: client, result: &result)
            } else {
                let created = try await client.createTask(listID: options.listID, .init(
                    name: title, markdown: markdown,
                    tags: tags(site: site, severity: definition.severity, category: definition.category, extra: options.extraTags),
                    priority: priority(for: definition.severity)
                ))
                parentID = created.id
                isNew = true
                result.tasks += 1
            }
            if asTable { result.tables += 1 }

            let existingChildren = children[parentID] ?? []
            var byName: [String: ClickUpClient.ExistingTask] = [:]
            for child in existingChildren { byName[child.name] = child }
            // Two subtasks with one name means an earlier export filed that page twice. Say so; never
            // add a third.
            result.duplicatesFound += existingChildren.count - byName.count

            // ClickUp counts every subtask under the task, open or closed, against its limit.
            var room = max(0, options.maxSubtasksPerTask - existingChildren.count)
            // http:// and https:// copies of a page share a subtask name; file it once.
            var filedThisRun: Set<String> = []
            var overflowed = false
            let shown = asTable ? [] : (options.subtaskLimit <= 0 ? ids : Array(ids.prefix(options.subtaskLimit)))
            for row in try store.rows(ids: shown) {
                let name = subtaskName(for: row.url, site: site)
                if filedThisRun.contains(name) { continue }
                if let child = byName[name] {
                    // The page is affected again after being marked done.
                    if child.isClosed, let open = detail.openStatus {
                        try await client.updateTask(id: child.id, status: open)
                        result.tasksReopened += 1
                    }
                    continue
                }
                guard room > 0 else {
                    overflowed = true
                    continue
                }
                try await client.createTask(listID: options.listID, .init(
                    name: name,
                    markdown: subtaskMarkdown(url: row.url, crawl: crawlName,
                                              evidence: try IssueEvidenceBuilder.evidence(
                                                  for: definition.code, urlID: row.id, store: store)),
                    parent: parentID
                ))
                filedThisRun.insert(name)
                room -= 1
                result.subtasks += 1
            }
            if overflowed { result.issuesOverCeiling += 1 }
            result.urlsCovered += asTable ? min(ids.count, options.tableRows) : shown.count

            // Pages that are no longer affected at all get closed, with a note saying why.
            if let closed = detail.closedStatus {
                for child in existingChildren
                where !child.isClosed && !affected.contains(child.name) && recrawled.contains(child.name) {
                    try await client.updateTask(id: child.id, status: closed)
                    try await client.comment(taskID: child.id, text: "Fixed: not found in \(crawlName).")
                    result.subtasksClosed += 1
                }
            }

            // The CSV is re-attached only when it would say something new — and always when the
            // ceiling kept pages out of the subtasks, since otherwise they'd be nowhere.
            let leftOut = asTable ? ids.count > options.tableRows : (ids.count > shown.count || overflowed)
            if leftOut, options.attachFullList || overflowed || asTable, isNew || countChanged || overflowed {
                let csv = try csvData(store: store, ids: ids, code: definition.code)
                try await client.attach(taskID: parentID,
                                        filename: "\(definition.code)-\(ids.count)-urls.csv", data: csv)
                result.attachments += 1
                result.urlsInAttachments += ids.count
            }
        }

        // Issues that have gone entirely: close the task rather than leave it looking outstanding.
        if let closed = detail.closedStatus {
            for (title, task) in mine where !handled.contains(title) && !task.isClosed {
                // Left out of this export by the severities chosen, but still on the site.
                guard let code = titleToCode[title], (counts[code] ?? 0) == 0 else { continue }
                guard coveredWholeSite else {
                    result.closingHeldBack = true
                    continue
                }
                try await client.updateTask(id: task.id, status: closed)
                try await client.comment(taskID: task.id, text: "Fixed: not found in \(crawlName).")
                result.tasksClosed += 1
            }
        }

        progress?("Done", 1)
        return result
    }

    /// An existing task for an issue that is still present: note what changed, and bring it back
    /// if somebody had closed it.
    private static func reconcileParent(_ task: ClickUpClient.ExistingTask, count: Int, before: Int?,
                                        crawl: String, markdown: String, refresh: Bool = false,
                                        detail: ClickUpClient.ListDetail, client: ClickUpClient,
                                        result: inout ClickUpExportResult) async throws {
        if task.isClosed, let open = detail.openStatus {
            try await client.updateTask(id: task.id, status: open, markdown: markdown)
            try await client.comment(taskID: task.id, text: "Back: \(count.formatted()) affected in \(crawl).")
            result.tasksReopened += 1
            return
        }
        guard before != count else {
            // A table task's rows can change while the count stays put; one request keeps it current.
            if refresh { try await client.updateTask(id: task.id, markdown: markdown) }
            return
        }
        try await client.updateTask(id: task.id, markdown: markdown)
        let change = before.map { "\($0.formatted()) → \(count.formatted())" } ?? "\(count.formatted())"
        try await client.comment(taskID: task.id, text: "Crawlspace: \(change) affected in \(crawl).")
        result.tasksUpdated += 1
    }

    /// The count the description was last written with, so a re-export can say what moved.
    static func previousCount(in description: String?) -> Int? {
        guard let description else { return nil }
        guard let match = description.firstMatch(of: /([0-9][0-9,]*) URLs? affected/) else { return nil }
        return Int(match.1.replacingOccurrences(of: ",", with: ""))
    }

    /// The whole URL is unreadable as a task title, so the path leads and the host follows.
    static func subtaskName(for address: String, site: String) -> String {
        guard let url = URL(string: address) else { return address }
        let path = url.path().isEmpty ? "/" : url.path()
        let query = url.query().map { "?\($0)" } ?? ""
        let host = url.host() ?? site
        return host == site ? "\(path)\(query)" : "\(host)\(path)\(query)"
    }

    static func description(_ definition: IssueDefinition, count: Int, site: String,
                            crawl: String, showing: Int, lead: IssueEvidence? = nil,
                            table: String? = nil) -> String {
        var text = """
        **\(count.formatted()) \(count == 1 ? "URL" : "URLs") affected on \(site).**

        \(definition.description)

        **How to fix:** \(definition.howToFix)
        """
        if let lead, lead.isTemplateWide, let first = lead.items.first, let shared = first.pagesWithSameLink {
            let share = min(shared, count)
            text += "\n\n**Start here:** \(share.formatted()) of these \(count.formatted()) pages share one link — \(first.text)"
            if let position = first.position, position.isTemplate { text += ", in the \(position.label.lowercased())" }
            text += ". It's part of the theme: change it once and they clear together. "
            text += table == nil ? "Each subtask says whether it's one of them." : "The table shows which."
        }
        if let table { text += "\n\n" + table }
        if table == nil, count > showing {
            text += "\n\nThe \(showing.formatted()) most linked-to pages are subtasks below; "
            text += "all \(count.formatted()) are in the CSV attached to this task."
        }
        text += "\n\nFound by Crawlspace in *\(crawl)*."
        return text
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
            let link = "[\(cell(subtaskName(for: row.url, site: site)))](\(linkTarget(row.url)))"
            entries.append((link, cell(wrong), evidence.items.first?.position?.label ?? ""))
        }
        var lines = ["**Affected URLs**" + (ids.count > shown.count
            ? " — the first \(shown.count.formatted()) of \(ids.count.formatted()), all in the attached CSV" : ""), ""]
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

    /// The evidence, among a handful of pages, whose leading link is shared by the most pages —
    /// the one change in the theme worth doing first.
    static func templateLead(code: String, ids: [Int64], store: CrawlStore) throws -> IssueEvidence? {
        try ids.map { try IssueEvidenceBuilder.evidence(for: code, urlID: $0, store: store) }
            .filter(\.isTemplateWide)
            .max { ($0.items.first?.pagesWithSameLink ?? 0) < ($1.items.first?.pagesWithSameLink ?? 0) }
    }

    /// A subtask's body: the page, exactly what on it is wrong, and what to do about it there.
    static func subtaskMarkdown(url: String, crawl: String, evidence: IssueEvidence) -> String {
        var text = url
        if !evidence.items.isEmpty {
            text += "\n\n**What's wrong**"
            for item in evidence.items {
                var line = "\n- \(item.text)"
                if let position = item.position { line += " — in the \(position.label.lowercased())" }
                if let shared = item.pagesWithSameLink, shared > 1 { line += " (same link on \(shared.formatted()) pages)" }
                text += line
            }
            if evidence.more > 0 { text += "\n- …and \(evidence.more.formatted()) more" }
        }
        if !evidence.fix.isEmpty { text += "\n\n**How to fix**\n\(evidence.fix)" }
        text += "\n\nFrom **\(crawl)**."
        return text
    }

    static func csvData(store: CrawlStore, ids: [Int64], code: String) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try TableExport.export(store: store, ids: ids, columns: URLFilter.issue(code).defaultColumns,
                               format: .csv, to: file)
        return try Data(contentsOf: file)
    }
}
