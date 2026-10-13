import Audit
import Foundation
import Integrations

/// What an overview export files, and where. The overview itself is `ClickUpOverview`; the detail it
/// leaves out lives in the site's `Worklist`.
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
    /// What reconciling with a list that already has these tasks in it did.
    public var tasksUpdated = 0
    public var tasksClosed = 0
    public var tasksReopened = 0
    /// Copies already in ClickUp from an earlier export — reported, never filed again.
    public var duplicatesFound = 0
    /// Open tasks an earlier layout filed, which this export leaves alone.
    public var legacyTasks = 0

    public var summary: String {
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks.formatted()) new \(tasks == 1 ? "task" : "tasks")") }
        if tasksUpdated > 0 { parts.append("\(tasksUpdated.formatted()) updated") }
        if tasksReopened > 0 { parts.append("\(tasksReopened.formatted()) reopened") }
        if tasksClosed > 0 { parts.append("\(tasksClosed.formatted()) closed") }
        var summary = parts.isEmpty ? "nothing to change" : parts.joined(separator: ", ")
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

    /// Adds up the exports into each list.
    mutating func add(_ other: ClickUpExportResult) {
        tasks += other.tasks
        tasksUpdated += other.tasksUpdated
        tasksClosed += other.tasksClosed
        tasksReopened += other.tasksReopened
        duplicatesFound += other.duplicatesFound
        legacyTasks += other.legacyTasks
    }
}

/// The list one severity's tasks go into: a list that's there (by id), or one to find or make by
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

/// Where a site's overview goes: a ClickUp space, and a list in it for each severity.
public struct ClickUpDestination: Codable, Sendable, Hashable {
    public var spaceID: String
    public var spaceName: String
    /// By severity, as "errors", "warnings" and "notices".
    public var targets: [String: ClickUpListTarget]

    public init(spaceID: String, spaceName: String, targets: [IssueSeverity: ClickUpListTarget] = [:]) {
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { (Self.key(for: $0.key), $0.value) })
    }

    /// How a severity's list is saved: "errors", "warnings", "notices".
    public static func key(for severity: IssueSeverity) -> String { severity.label.lowercased() }

    private enum CodingKeys: String, CodingKey { case spaceID, spaceName, targets, folderName }

    /// Reads every earlier shape: a single folder for all three severities (1.x); lists saved by
    /// "error", "warning", "notice"; and lists saved for every kind of list, of which only the
    /// three severities are still used.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaceID = try c.decode(String.self, forKey: .spaceID)
        spaceName = try c.decodeIfPresent(String.self, forKey: .spaceName) ?? ""
        let names = Dictionary(uniqueKeysWithValues: IssueSeverity.allCases.map { ($0.name, Self.key(for: $0)) })
        if let saved = try c.decodeIfPresent([String: ClickUpListTarget].self, forKey: .targets) {
            var targets: [String: ClickUpListTarget] = [:]
            for (key, target) in saved {
                let severity = names[key] ?? key
                if names.values.contains(severity) { targets[severity] = target }
            }
            self.targets = targets
        } else {
            let folder = try c.decodeIfPresent(String.self, forKey: .folderName) ?? "Crawlspace"
            targets = Dictionary(uniqueKeysWithValues: IssueSeverity.allCases.map {
                (Self.key(for: $0), ClickUpListTarget(folderName: folder, listName: $0.label))
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
        targets[Self.key(for: severity)] ?? .standard(for: severity)
    }
}

/// Finds the list for each severity in a destination, by id or by name, making any folder or list
/// that isn't there yet.
public enum ClickUpFolderExport {
    public struct Resolved: Sendable {
        public var lists: [IssueSeverity: String]
        /// Where each severity went, for the result message.
        public var paths: [IssueSeverity: String]
        /// What had to be made: "the Crawlspace folder", "the Crawlspace › Errors list".
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
                var all = spaceLists ?? []
                for folder in folders { all += try await lists(in: folder) }
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
}
