import Audit
import CrawlCore
import Foundation
import Integrations
import Storage

/// Files what a crawl found as ClickUp tasks, one per thing to fix rather than one per issue type.
///
/// A real site produces thousands of affected URLs — one client shop had 41 issue types across
/// 5,081 of them — and most of that is the same few fixes seen from every page: a broken link in
/// the footer, a missing security header, an image without alt text in the header. Filed per page
/// or per issue, each of those becomes thousands of tasks for one edit, and ClickUp allows 100
/// requests a minute on most plans. So links, images, site settings, duplicates, speed and
/// products each get a list where a task is the one thing to change, listing every page it
/// clears; what's left goes page by page, a task per page with its issues listed in it.
public struct ClickUpExportOptions: Sendable {
    public var listID: String
    public var severities: Set<IssueSeverity>
    /// The lists to file. Each topic's tasks go into the list chosen for it.
    public var topics: Set<ClickUpTopic>
    public var extraTags: [String]
    /// Pages listed in a task's table; the attached CSV holds every one.
    public var tableRows = 200

    public init(listID: String, severities: Set<IssueSeverity> = [.error, .warning],
                topics: Set<ClickUpTopic> = Set(ClickUpTopic.allCases), extraTags: [String] = []) {
        self.listID = listID
        self.severities = severities
        self.topics = topics
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
            summary += ". \(legacyTasks.formatted()) open \(legacyTasks == 1 ? "task" : "tasks") from the earlier "
            summary += "one-task-per-issue layout \(legacyTasks == 1 ? "is" : "are") still in the list and no longer updated"
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

    /// Works out the tasks once, then files each list's share, with progress across the whole export.
    public static func export(store: CrawlStore, destination: ClickUpDestination, options: ClickUpExportOptions,
                              client: ClickUpClient,
                              progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> (ClickUpExportResult, Resolved) {
        progress?("Finding the lists in \(destination.spaceName)…", 0)
        let resolved = try await resolve(destination, topics: options.topics, client: client)
        let units = try ClickUpUnitBuilder.units(store: store, severities: options.severities, topics: options.topics)
        // Topics sharing a list are filed together, so neither closes the other's tasks.
        var byList: [String: Set<ClickUpTopic>] = [:]
        for (topic, list) in resolved.lists { byList[list, default: []].insert(topic) }
        let lists = byList.sorted { ($0.value.map(\.order).min() ?? 0) < ($1.value.map(\.order).min() ?? 0) }

        var total = ClickUpExportResult()
        var done = 0
        for (list, topics) in lists {
            let share = units.filter { topics.contains($0.topic) }
            let names = topics.sorted { $0.order < $1.order }.compactMap { resolved.paths[$0] }.joined(separator: ", ")
            let start = done
            let result = try await ClickUpExporter.file(share, topics: topics, into: list, store: store,
                                                        options: options, client: client) { title, fraction in
                progress?("\(names): \(title)", (Double(start) + fraction * Double(share.count)) / Double(max(1, units.count)))
            }
            done += share.count
            total.add(result)
        }
        progress?("Done", 1)
        return (total, resolved)
    }
}

extension ClickUpTopic {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
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

    static func tags(site: String, unit: ClickUpUnit, extra: [String]) -> [String] {
        var tags = ["crawlspace", tagSlug(site), tagSlug(unit.severity.label), unit.topic.tag]
        // So whoever looks after the catalogue can filter to their own tasks.
        if unit.codes.contains(where: { IssueCatalogue.definition(for: $0)?.category == .ecommerce }) {
            tags.append("e-commerce")
        }
        tags.append(contentsOf: extra)
        return tags
    }

    static func tagSlug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    /// Files every chosen topic into one list.
    public static func export(
        store: CrawlStore,
        options: ClickUpExportOptions,
        client: ClickUpClient,
        progress: (@Sendable (String, Double) -> Void)? = nil
    ) async throws -> ClickUpExportResult {
        let units = try ClickUpUnitBuilder.units(store: store, severities: options.severities, topics: options.topics)
        let result = try await file(units, topics: options.topics, into: options.listID, store: store,
                                    options: options, client: client, progress: progress)
        progress?("Done", 1)
        return result
    }

    /// Files units into a list that holds the given topics, reconciling with what's already there.
    static func file(_ units: [ClickUpUnit], topics: Set<ClickUpTopic>, into listID: String, store: CrawlStore,
                     options: ClickUpExportOptions, client: ClickUpClient,
                     progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> ClickUpExportResult {
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let siteTag = tagSlug(site)
        let crawlName = store.packageURL.deletingPathExtension().lastPathComponent

        // What is already in the list, so a second export updates its own tasks rather than
        // filing a second copy of everything. Tasks are matched by topic and name among those
        // tagged for this site, which survives a rebuilt Mac and doesn't need a custom field.
        let detail = try await client.list(id: listID)
        let existing = try await client.tasks(listID: listID)
        var result = ClickUpExportResult()

        // Closing is only as trustworthy as the crawl. A page's task closes when the page was
        // crawled again and came back clean; anything else only when the crawl covered the whole
        // site. Anything the crawl didn't reach stays open rather than being marked fixed.
        let coveredWholeSite = try store.status() == .completed && store.crawledCount() < config.maxURLs
        let recrawled = Set(try store.rows(ids: store.rowIDs(for: URLListQuery(filter: .internalAll)))
            .map { pageName(for: $0.url, site: site) })

        var children: [String: [ClickUpClient.ExistingTask]] = [:]
        for task in existing { if let parent = task.parent { children[parent, default: []].append(task) } }
        var mine: [String: ClickUpClient.ExistingTask] = [:]
        for task in existing where task.parent == nil
            && task.tagNames.contains("crawlspace") && task.tagNames.contains(siteTag) {
            guard let topic = topic(of: task) else {
                // Filed by the earlier layout: left alone, but worth knowing about.
                if !task.isClosed { result.legacyTasks += 1 }
                continue
            }
            let key = "\(topic.rawValue)|\(task.name)"
            if mine[key] != nil { result.duplicatesFound += 1 }
            mine[key] = task
        }

        var handled: Set<String> = []
        for (index, unit) in units.enumerated() {
            progress?(unit.name, Double(index) / Double(max(1, units.count)))
            let key = "\(unit.topic.rawValue)|\(unit.name)"
            handled.insert(key)
            // Only issues left out of this export: its task, if any, stays as it is.
            if unit.heldOpen { continue }

            let body = try ClickUpUnitBuilder.markdown(for: unit, store: store, rows: options.tableRows)
            let ref = fingerprint(body)
            let markdown = body + "\n\nFound by Crawlspace in *\(crawlName)*. Covers \(unit.count.formatted()) \(unit.noun) · ref \(ref)"

            let taskID: String
            var isNew = false
            var countChanged = false
            if let task = mine[key] {
                taskID = task.id
                let before = footer(of: task.description)
                countChanged = before?.count != unit.count
                if task.isClosed, let open = detail.openStatus {
                    try await client.updateTask(id: task.id, status: open, markdown: markdown)
                    try await client.comment(taskID: task.id, text: "Back: \(unit.count.formatted()) \(unit.noun) in \(crawlName).")
                    result.tasksReopened += 1
                } else if before?.ref != ref {
                    try await client.updateTask(id: task.id, markdown: markdown)
                    if countChanged, let count = before?.count {
                        try await client.comment(taskID: task.id,
                                                 text: "Crawlspace: \(count.formatted()) → \(unit.count.formatted()) \(unit.noun) in \(crawlName).")
                    }
                    result.tasksUpdated += 1
                }
            } else {
                let created = try await client.createTask(listID: listID, .init(
                    name: unit.name, markdown: markdown,
                    tags: tags(site: site, unit: unit, extra: options.extraTags),
                    priority: priority(for: unit.severity)
                ))
                taskID = created.id
                isNew = true
                result.tasks += 1
            }

            // Every page in a CSV when the table can't hold them, attached again only when the
            // pages have changed.
            if !unit.countsIssues, unit.pages.count > options.tableRows, isNew || countChanged {
                let csv = try csvData(store: store, ids: unit.pages, code: unit.codes.first ?? "")
                try await client.attach(taskID: taskID, filename: "\(tagSlug(unit.topic.label))-\(unit.pages.count)-urls.csv", data: csv)
                result.attachments += 1
                result.urlsInAttachments += unit.pages.count
            }

            if !unit.subtasks.isEmpty {
                try await fileSubtasks(of: unit, under: taskID, existing: children[taskID] ?? [], listID: listID, site: site,
                                       crawlName: crawlName, wholeSite: coveredWholeSite, detail: detail, store: store,
                                       options: options, client: client, result: &result)
            }
        }

        // What's gone: close it rather than leave it looking outstanding.
        if let closed = detail.closedStatus {
            for (key, task) in mine where !handled.contains(key) && !task.isClosed {
                // Left out of this export by the lists or severities chosen.
                guard let topic = topic(of: task), topics.contains(topic),
                      let severity = severity(of: task), options.severities.contains(severity) else { continue }
                let pageLists: Set<ClickUpTopic> = [.products, .collections, .storePages, .blog, .otherPages]
                let isPage = (topic.pageSeverity != nil || pageLists.contains(topic)) && !task.name.hasSuffix(" template")
                guard isPage ? recrawled.contains(task.name) : coveredWholeSite else {
                    if !coveredWholeSite { result.closingHeldBack = true }
                    continue
                }
                // A later page of a collection or blog filed on its own by an earlier export: its
                // issues now live with the first page, so it closes as moved rather than fixed.
                let first = ClickUpUnitBuilder.paginationBase(of: task.name)
                let movedTo = first.flatMap { handled.contains("\(topic.rawValue)|\($0)") ? $0 : nil }
                try await client.updateTask(id: task.id, status: closed)
                try await client.comment(taskID: task.id, text: movedTo.map { "Moved: now filed under \($0) with its other pages." }
                                                                ?? "Fixed: not found in \(crawlName).")
                result.tasksClosed += 1
                // Its issues go with it; the task's comment says why.
                for child in children[task.id] ?? [] where !child.isClosed {
                    try await client.updateTask(id: child.id, status: closed)
                    result.subtasksClosed += 1
                }
            }
        }
        return result
    }

    /// A page's or template's issues as subtasks, reconciled with what's already under it: new ones
    /// filed, changed ones rewritten, returning ones reopened, and gone ones closed. Never a second
    /// copy of a name; one already there twice is reported.
    private static func fileSubtasks(of unit: ClickUpUnit, under parent: String, existing: [ClickUpClient.ExistingTask],
                                     listID: String, site: String, crawlName: String, wholeSite: Bool,
                                     detail: ClickUpClient.ListDetail, store: CrawlStore, options: ClickUpExportOptions,
                                     client: ClickUpClient, result: inout ClickUpExportResult) async throws {
        var byName: [String: ClickUpClient.ExistingTask] = [:]
        for child in existing {
            if byName[child.name] != nil { result.duplicatesFound += 1 }
            byName[child.name] = child
        }
        var wanted: Set<String> = []
        for subtask in unit.subtasks {
            wanted.insert(subtask.name)
            let body = try ClickUpUnitBuilder.markdown(for: subtask, in: unit, store: store, rows: options.tableRows)
            let ref = fingerprint(body)
            let count = subtask.pages.count
            let noun = count == 1 ? "page" : "pages"
            let markdown = body + "\n\nFound by Crawlspace in *\(crawlName)*. Covers \(count.formatted()) \(noun) · ref \(ref)"
            var attach = false
            if let child = byName[subtask.name] {
                let before = footer(of: child.description)
                if child.isClosed, let open = detail.openStatus {
                    try await client.updateTask(id: child.id, status: open, markdown: markdown)
                    try await client.comment(taskID: child.id, text: "Back: \(count.formatted()) \(noun) in \(crawlName).")
                    result.tasksReopened += 1
                } else if before?.ref != ref {
                    try await client.updateTask(id: child.id, markdown: markdown)
                    if let previous = before?.count, previous != count {
                        try await client.comment(taskID: child.id, text: "Crawlspace: \(previous.formatted()) → \(count.formatted()) \(noun) in \(crawlName).")
                    }
                    result.tasksUpdated += 1
                }
                attach = before?.count != count
                if attach, count > options.tableRows {
                    try await attachCSV(subtask, to: child.id, store: store, client: client, result: &result)
                }
            } else {
                var tags = ["crawlspace", tagSlug(site), tagSlug(subtask.severity.label), unit.topic.tag]
                tags.append(contentsOf: options.extraTags)
                let created = try await client.createTask(listID: listID, .init(
                    name: subtask.name, markdown: markdown, tags: tags,
                    priority: priority(for: subtask.severity), parent: parent
                ))
                result.subtasks += 1
                if count > options.tableRows {
                    try await attachCSV(subtask, to: created.id, store: store, client: client, result: &result)
                }
            }
        }

        // Issues gone from the page, or from the template: only those at the severities exported,
        // and a template's only on the word of a crawl of the whole site.
        guard let closed = detail.closedStatus else { return }
        let isTemplate = if case .template = unit.kind { true } else { false }
        for child in existing where !wanted.contains(child.name) && !child.isClosed {
            guard let severity = severity(of: child), options.severities.contains(severity) else { continue }
            guard !isTemplate || wholeSite else {
                result.closingHeldBack = true
                continue
            }
            try await client.updateTask(id: child.id, status: closed)
            try await client.comment(taskID: child.id, text: "Fixed: not found in \(crawlName).")
            result.subtasksClosed += 1
        }
    }

    private static func attachCSV(_ subtask: ClickUpSubtask, to task: String, store: CrawlStore, client: ClickUpClient,
                                  result: inout ClickUpExportResult) async throws {
        let csv = try csvData(store: store, ids: subtask.pages, code: subtask.code)
        try await client.attach(taskID: task, filename: "\(subtask.code)-\(subtask.pages.count)-urls.csv", data: csv)
        result.attachments += 1
        result.urlsInAttachments += subtask.pages.count
    }

    /// Which list a task was filed for, from its tags; nil for the earlier layout's tasks.
    static func topic(of task: ClickUpClient.ExistingTask) -> ClickUpTopic? {
        let tags = task.tagNames
        if tags.contains("pages") { return severity(of: task).map(ClickUpTopic.pages) }
        return ClickUpTopic.allCases.first { $0.pageSeverity == nil && tags.contains($0.tag) }
    }

    static func severity(of task: ClickUpClient.ExistingTask) -> IssueSeverity? {
        IssueSeverity.allCases.first { task.tagNames.contains(tagSlug($0.label)) }
    }

    /// The count and ref a task was last written with, read back from its footer. ClickUp hands
    /// the description back as plain text, so this reads either.
    static func footer(of description: String?) -> (count: Int, ref: String)? {
        guard let description,
              let match = description.firstMatch(of: /Covers ([0-9][0-9,]*) (?:issues?|pages?) · ref ([0-9a-f]{8})/),
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

    static func csvData(store: CrawlStore, ids: [Int64], code: String) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let columns = code.isEmpty ? URLFilter.internalAll.defaultColumns : URLFilter.issue(code).defaultColumns
        try TableExport.export(store: store, ids: ids, columns: columns, format: .csv, to: file)
        return try Data(contentsOf: file)
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
