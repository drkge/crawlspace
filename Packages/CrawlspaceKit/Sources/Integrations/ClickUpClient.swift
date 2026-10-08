import CrawlCore
import Foundation

/// ClickUp's v2 REST API, enough of it to file what a crawl found.
///
/// Authentication is a personal API token (ClickUp ▸ Settings ▸ Apps), which goes in the secrets file
/// like every other credential here. An OAuth app would be the alternative, but it exists so that
/// *other people's* workspaces can be reached — not the case for a tool an agency runs on its own.
public struct ClickUpClient: Sendable {
    public static let keychainAccount = "clickup.api-token"
    public static let defaultBase = URL(string: "https://api.clickup.com/api")!

    let token: String
    let base: URL
    let session: URLSession
    private let limiter: APIRateLimiter

    /// ClickUp allows 100 requests a minute per token on Free, Unlimited and Business, more on the
    /// larger plans. 1.5/second leaves a little room under the smallest of those.
    public init(token: String, base: URL = ClickUpClient.defaultBase,
                session: URLSession = .shared, requestsPerSecond: Double = 1.5) {
        self.token = token
        self.base = base
        self.session = session
        limiter = APIRateLimiter(requestsPerSecond: requestsPerSecond)
    }

    public static func storedToken() -> String? {
        CredentialStore.password(account: keychainAccount)
    }

    // MARK: - Where things can go

    public struct Workspace: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
    }

    public struct Space: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
    }

    public struct Folder: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var lists: [TaskList]?
    }

    public struct TaskList: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
    }

    public func workspaces() async throws -> [Workspace] {
        try await get("/v2/team", as: Envelope<Workspace>.self).teams ?? []
    }

    public func spaces(workspace id: String) async throws -> [Space] {
        try await get("/v2/team/\(id)/space", as: Envelope<Space>.self).spaces ?? []
    }

    public func folders(space id: String) async throws -> [Folder] {
        try await get("/v2/space/\(id)/folder", as: Envelope<Folder>.self).folders ?? []
    }

    public func lists(folder id: String) async throws -> [TaskList] {
        try await get("/v2/folder/\(id)/list", as: Envelope<TaskList>.self).lists ?? []
    }

    /// Lists that sit directly in a space rather than in a folder.
    public func lists(space id: String) async throws -> [TaskList] {
        try await get("/v2/space/\(id)/list", as: Envelope<TaskList>.self).lists ?? []
    }

    /// Makes a folder in a space, for a store's Crawlspace folder that isn't there yet.
    public func createFolder(space id: String, name: String) async throws -> Folder {
        try await send(method: "POST", path: "/v2/space/\(id)/folder", body: try JSONEncoder().encode(["name": name]),
                       contentType: "application/json", as: Folder.self)
    }

    /// Makes a list directly in a space, outside any folder.
    public func createList(space id: String, name: String) async throws -> TaskList {
        try await send(method: "POST", path: "/v2/space/\(id)/list", body: try JSONEncoder().encode(["name": name]),
                       contentType: "application/json", as: TaskList.self)
    }

    /// Makes a list in a folder, such as its Errors, Warnings or Notices list.
    public func createList(folder id: String, name: String) async throws -> TaskList {
        try await send(method: "POST", path: "/v2/folder/\(id)/list", body: try JSONEncoder().encode(["name": name]),
                       contentType: "application/json", as: TaskList.self)
    }

    private struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
        var teams: [T]?
        var spaces: [T]?
        var folders: [T]?
        var lists: [T]?
    }

    /// A list's own statuses, which is how a task gets closed: the names are per-list, so the one
    /// to use has to be looked up rather than guessed.
    public struct ListDetail: Decodable, Sendable {
        public var id: String
        public var name: String
        public var statuses: [Status]?

        public struct Status: Decodable, Sendable, Hashable {
            public var status: String
            public var type: String
            public var orderindex: Int?
        }

        /// The status a finished task goes to, and the one it comes back to if the issue returns.
        public var closedStatus: String? {
            statuses?.first { $0.type == "closed" }?.status ?? statuses?.first { $0.type == "done" }?.status
        }

        public var openStatus: String? {
            statuses?.first { $0.type == "open" }?.status ?? statuses?.first?.status
        }
    }

    public func list(id: String) async throws -> ListDetail {
        try await get("/v2/list/\(id)", as: ListDetail.self)
    }

    // MARK: - Tasks

    /// The parts of a ClickUp task this export sets. `parent` is what makes a task a subtask; the
    /// parent has to be in the same list.
    public struct NewTask: Encodable, Sendable {
        public var name: String
        public var markdown_description: String?
        public var tags: [String]?
        public var priority: Int?
        public var parent: String?

        public init(name: String, markdown: String? = nil, tags: [String]? = nil,
                    priority: Int? = nil, parent: String? = nil) {
            self.name = name
            markdown_description = markdown
            self.tags = tags
            self.priority = priority
            self.parent = parent
        }
    }

    public struct CreatedTask: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var url: String?
    }

    @discardableResult
    public func createTask(listID: String, _ task: NewTask) async throws -> CreatedTask {
        try await send(method: "POST", path: "/v2/list/\(listID)/task",
                       body: try JSONEncoder().encode(task),
                       contentType: "application/json", as: CreatedTask.self)
    }

    /// A task already in the list, which is how a second export finds its own work rather than
    /// filing everything twice.
    public struct ExistingTask: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var parent: String?
        public var status: StatusHolder?
        public var description: String?
        public var tags: [Tag]?

        public struct StatusHolder: Decodable, Sendable, Hashable {
            public var status: String?
            public var type: String?
        }

        public struct Tag: Decodable, Sendable, Hashable {
            public var name: String
        }

        public var isClosed: Bool { status?.type == "closed" || status?.type == "done" }
        public var tagNames: [String] { (tags ?? []).map(\.name) }
    }

    /// Every task in a list, subtasks and closed ones included, a page at a time.
    ///
    /// Reconciliation is only as good as this listing: a task that isn't seen here gets filed
    /// again. So it pages until ClickUp says it has finished, and when `last_page` is missing it
    /// keeps asking until a page comes back empty — one extra request, and no guess about the page
    /// size. An earlier version took a missing `last_page` as "done", stopped after the first
    /// hundred, and filed everything else again on every re-run.
    public func tasks(listID: String) async throws -> [ExistingTask] {
        struct Page: Decodable { var tasks: [ExistingTask]; var last_page: Bool? }
        var all: [ExistingTask] = []
        var seen: Set<String> = []
        for page in 0..<1_000 {
            let batch: Page = try await get("/v2/list/\(listID)/task", query: [
                URLQueryItem(name: "subtasks", value: "true"),
                URLQueryItem(name: "include_closed", value: "true"),
                URLQueryItem(name: "page", value: String(page)),
            ], as: Page.self)
            // A page of nothing but tasks already seen means the server is repeating itself.
            let fresh = batch.tasks.filter { seen.insert($0.id).inserted }
            all.append(contentsOf: fresh)
            if batch.tasks.isEmpty || fresh.isEmpty { break }
            if batch.last_page == true { break }
        }
        return all
    }

    public func updateTask(id: String, status: String? = nil, markdown: String? = nil) async throws {
        struct Update: Encodable {
            var status: String?
            var markdown_description: String?
        }
        struct Ignored: Decodable {}
        _ = try await send(method: "PUT", path: "/v2/task/\(id)",
                           body: try JSONEncoder().encode(Update(status: status, markdown_description: markdown)),
                           contentType: "application/json", as: Ignored.self)
    }

    /// Notes what changed, so a task carries its own history between crawls.
    public func comment(taskID: String, text: String) async throws {
        struct Comment: Encodable { var comment_text: String; var notify_all = false }
        struct Ignored: Decodable {}
        _ = try await send(method: "POST", path: "/v2/task/\(taskID)/comment",
                           body: try JSONEncoder().encode(Comment(comment_text: text)),
                           contentType: "application/json", as: Ignored.self)
    }

    /// Attaches a file to a task. The full list of affected URLs rides along this way rather than
    /// as hundreds of subtasks.
    public func attach(taskID: String, filename: String, data: Data) async throws {
        let boundary = "crawlspace.\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"attachment\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: text/csv\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        _ = try await send(method: "POST", path: "/v2/task/\(taskID)/attachment", body: body,
                           contentType: "multipart/form-data; boundary=\(boundary)", as: Attachment.self)
    }

    private struct Attachment: Decodable, Sendable { var id: String? }

    // MARK: - Plumbing

    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [],
                                             as type: T.Type) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: nil, contentType: nil, as: type)
    }

    private func send<T: Decodable & Sendable>(method: String, path: String, query: [URLQueryItem] = [],
                                               body: Data?, contentType: String?, as type: T.Type,
                                               attempt: Int = 0) async throws -> T {
        // The query has to be attached as a query: appending(path:) would percent-encode the "?"
        // into the path and the request would go nowhere.
        var url = base.appending(path: path.trimmingPrefix("/"))
        if !query.isEmpty { url = url.appending(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        // A personal token is sent as-is; it isn't a bearer token.
        request.setValue(token, forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        await limiter.wait()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            guard attempt < 2 else { throw ClickUpError.transport(error.localizedDescription) }
            try await Task.sleep(for: .seconds(pow(2, Double(attempt + 1))))
            return try await send(method: method, path: path, query: query, body: body,
                                  contentType: contentType, as: type, attempt: attempt + 1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClickUpError.transport("not an HTTP response")
        }
        // ClickUp says what this token is actually allowed. On the bigger plans that is ten or a
        // hundred times the default, and a long export has no reason to crawl along at the
        // smallest plan's pace.
        if let allowed = http.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Double.init), allowed > 0 {
            await limiter.setRate(requestsPerSecond: max(1, allowed * 0.9) / 60)
        }
        switch http.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw ClickUpError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
            }
        case 401, 403:
            // ClickUp answers several refusals this way, and only some of them are about the
            // token. Calling them all a bad token sent people off to regenerate a token that was
            // fine.
            let code = Self.errorCode(data)
            if code == "ITEM_327" { throw ClickUpError.tooManySubtasks(Self.detail(data)) }
            if code?.hasPrefix("OAUTH") == true || code == nil && http.statusCode == 401 {
                throw ClickUpError.unauthorised(Self.detail(data))
            }
            throw ClickUpError.http(status: http.statusCode, detail: Self.detail(data))
        case 429, 500, 502, 503:
            guard attempt < 3 else { throw ClickUpError.rateLimited(Self.detail(data)) }
            // ClickUp says when the window resets; failing that, back off and try again.
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
            let wait = reset.map { max(1, $0 - Date().timeIntervalSince1970) }
                ?? http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                ?? pow(2, Double(attempt + 1)) * 5
            try await Task.sleep(for: .seconds(min(wait, 90)))
            return try await send(method: method, path: path, query: query, body: body,
                                  contentType: contentType, as: type, attempt: attempt + 1)
        default:
            throw ClickUpError.http(status: http.statusCode, detail: Self.detail(data))
        }
    }

    static func errorCode(_ data: Data) -> String? {
        struct Failure: Decodable { var ECODE: String? }
        return (try? JSONDecoder().decode(Failure.self, from: data))?.ECODE
    }

    static func detail(_ data: Data) -> String {
        struct Failure: Decodable { var err: String?; var ECODE: String? }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data), let message = failure.err {
            return failure.ECODE.map { "\(message) (\($0))" } ?? message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

public enum ClickUpError: LocalizedError {
    case unauthorised(String)
    case tooManySubtasks(String)
    case rateLimited(String)
    case http(status: Int, detail: String)
    case badResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorised(let detail):
            "ClickUp wouldn't accept the token: \(detail). Check it in ClickUp ▸ Settings ▸ Apps."
        case .tooManySubtasks:
            "ClickUp allows at most 1,000 subtasks under one task, and this one is full. If the same " +
            "pages appear more than once under it, an earlier export filed them twice — remove the " +
            "copies in ClickUp and export again."
        case .rateLimited(let detail): "ClickUp is rate limiting the export: \(detail)"
        case .http(let status, let detail): "ClickUp returned HTTP \(status): \(detail)"
        case .badResponse(let body): "ClickUp sent something unexpected: \(body)"
        case .transport(let detail): detail
        }
    }
}
