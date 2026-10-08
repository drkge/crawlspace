import Audit
import Compare
import CrawlCore
import Export
import Foundation
import Hummingbird
import Lighthouse
import Rendering
import Storage

/// `/api/crawls`: the library, crawl control, tables, the inspector, exports and Lighthouse.
struct CrawlRoutes {
    let library: Library

    func register(on router: Router<AppContext>) {
        let crawls = router.group("api/crawls")

        crawls.get { _, _ in JSON(await library.list()) }

        crawls.post { request, context in
            let body = try await request.decodeJSON(ConfigBody.self, context: context)
            let session = try await library.create(config: body.config)
            return JSON(await session.state(), status: .created)
        }

        crawls.get(":id") { _, context in
            JSON(try await session(context).state())
        }

        crawls.delete(":id") { _, context in
            try await library.trash(context.parameters.string("id"))
            return Response(status: .noContent)
        }

        crawls.get(":id/events") { _, context in
            let session = try await session(context)
            let initial = ServerEvent(name: "state", json: try Coding.encoder.encode(await session.state()))
            return eventStream(session.events, initial: [initial])
        }

        // Control
        crawls.post(":id/start") { _, context in
            let session = try await session(context)
            try await session.start()
            return JSON(await session.state())
        }
        crawls.post(":id/pause") { _, context in
            let session = try await session(context)
            await session.pause()
            return JSON(await session.state())
        }
        crawls.post(":id/resume") { _, context in
            let session = try await session(context)
            await session.resume()
            return JSON(await session.state())
        }
        crawls.post(":id/stop") { _, context in
            let session = try await session(context)
            await session.stop()
            return JSON(await session.state())
        }
        crawls.post(":id/analyse") { _, context in
            let session = try await session(context)
            try await session.analyse()
            return JSON(await session.state())
        }
        crawls.post(":id/rescan") { _, context in
            let session = try await library.rescan(context.parameters.string("id"))
            return JSON(await session.state(), status: .created)
        }
        crawls.post(":id/reveal") { _, context in
            try await library.revealInFinder(context.parameters.string("id"))
            return Response(status: .noContent)
        }
        crawls.put(":id/config") { request, context in
            let body = try await request.decodeJSON(ConfigBody.self, context: context)
            let session = try await session(context)
            try await session.updateConfig(body.config)
            return JSON(await session.state())
        }

        // Sidebar and overview
        crawls.get(":id/counts") { _, context in
            let store = try await session(context).store
            return JSON(try await background { try counts(store) })
        }

        // Tables
        crawls.get(":id/rows") { request, context in
            let store = try await session(context).store
            let selection = try selection(request)
            let query = try listQuery(request, selection: selection)
            return JSON(try await background {
                let hasLighthouse = try store.hasLighthouseData()
                let columns = selection.columns(hasLighthouse: hasLighthouse)
                let ids = try query.map { try store.rowIDs(for: $0) } ?? []
                var issue: IssueDTO?
                if case .issue(let code) = selection, let definition = IssueCatalogue.definition(for: code) {
                    issue = IssueDTO(definition)
                }
                return RowListDTO(title: selection.title, ids: ids, columns: columns.map(ColumnDTO.init), issue: issue)
            })
        }

        crawls.post(":id/rows/data") { request, context in
            let body = try await request.decodeJSON(RowDataBody.self, context: context)
            guard body.ids.count <= 2_000 else { throw ServerError.badRequest("Ask for at most 2,000 rows at a time.") }
            let columns = body.columns.compactMap(URLTableColumn.init(id:))
            let store = try await session(context).store
            return JSON(try await background {
                let rows = try store.rows(ids: body.ids)
                let needsExtractions = columns.contains { if case .extraction = $0 { true } else { false } }
                let extractions = needsExtractions ? try store.extractionValues(ids: body.ids) : [:]
                return rows.map { row in
                    RowDTO(id: row.id, url: row.url, statusCode: row.statusCode,
                           indexable: row.indexability == .indexable, crawled: row.state == .crawled,
                           cells: columns.map { $0.value(for: row, extractions: extractions[row.id] ?? [:]).displayString })
                }
            })
        }

        crawls.get(":id/lookup") { request, context in
            guard let url = request.query("url") else { throw ServerError.badRequest("Which URL?") }
            let store = try await session(context).store
            return JSON(LookupResult(id: try store.rowID(forURL: url)))
        }

        // Inspector
        crawls.get(":id/rows/:row") { _, context in
            let store = try await session(context).store
            let id = try context.parameters.require("row", as: Int64.self)
            guard let inspector = await background({ InspectorDTO(store: store, id: id) }) else {
                throw ServerError.notFound("That URL isn't in this crawl.")
            }
            return JSON(inspector)
        }
        crawls.get(":id/rows/:row/html") { _, context in
            let store = try await session(context).store
            let id = try context.parameters.require("row", as: Int64.self)
            guard let html = try store.storedHTML(id: id) else { throw ServerError.notFound("No stored HTML for that URL.") }
            return inline(html, contentType: "text/plain; charset=utf-8")
        }
        crawls.get(":id/rows/:row/rendered") { _, context in
            let store = try await session(context).store
            let id = try context.parameters.require("row", as: Int64.self)
            guard let html = try store.renderedHTML(id: id) else { throw ServerError.notFound("No rendered DOM for that URL.") }
            return inline(html, contentType: "text/plain; charset=utf-8")
        }
        crawls.get(":id/rows/:row/screenshot") { _, context in
            let store = try await session(context).store
            let id = try context.parameters.require("row", as: Int64.self)
            guard let png = try store.screenshot(id: id) else { throw ServerError.notFound("No screenshot for that URL.") }
            return inline(png, contentType: "image/png")
        }
        crawls.get(":id/rows/:row/lighthouse/:device") { _, context in
            let store = try await session(context).store
            let id = try context.parameters.require("row", as: Int64.self)
            guard let device = LighthouseDevice(rawValue: try context.parameters.string("device")),
                  let html = try store.lighthouseReportHTML(urlID: id, device: device) else {
                throw ServerError.notFound("No Lighthouse report for that page yet.")
            }
            return inline(html, contentType: "text/html; charset=utf-8")
        }

        // Compare
        crawls.get(":id/compare/:baseline") { _, context in
            let store = try await session(context).store
            let baselineID = try context.parameters.string("baseline")
            let baseline = try await library.session(baselineID).packageURL
            return JSON(try await background { try CrawlComparer.compare(baseline: baseline, current: store) })
        }

        // Exports
        crawls.get(":id/export/table") { request, context in
            let session = try await session(context)
            let store = session.store
            let format = ExportFormat(rawValue: request.query("format") ?? "csv") ?? .csv
            let selection = try selection(request, default: .filter(.internalHTML))
            guard let query = try listQuery(request, selection: selection) else {
                throw ServerError.badRequest("The overview has no table to export.")
            }
            let name = await session.name
            let data = try await session.runExport("\(selection.title) as \(format.rawValue.uppercased())") {
                try await background {
                    let columns = selection.columns(hasLighthouse: try store.hasLighthouseData())
                    let ids = try store.rowIDs(for: query)
                    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try TableExport.export(store: store, ids: ids, columns: columns, format: format, to: url,
                                           sheetName: String(selection.title.prefix(28)))
                    return try Data(contentsOf: url)
                }
            }
            let contentType = format == .csv
                ? "text/csv; charset=utf-8"
                : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            return download(data, filename: "\(name) – \(selection.title).\(format.fileExtension)", contentType: contentType)
        }

        crawls.post(":id/export/report") { request, context in
            let body = try await request.decodeJSON(ReportBody.self, context: context)
            var options = ReportOptions()
            if let title = body.title, !title.isEmpty { options.title = title }
            options.clientName = body.clientName ?? ""
            options.preparedBy = body.preparedBy ?? ""
            options.notes = body.notes ?? ""
            if let accent = body.accent, accent.wholeMatch(of: /#[0-9A-Fa-f]{6}/) != nil { options.accent = accent }
            options.logo = body.logo.flatMap { Data(base64Encoded: $0) }
            options.maxIssues = min(max(body.maxIssues ?? options.maxIssues, 5), 80)
            options.examplesPerIssue = min(max(body.examplesPerIssue ?? options.examplesPerIssue, 1), 20)
            let asPDF = body.format != "html"
            let reportOptions = options

            let session = try await session(context)
            let store = session.store
            let name = await session.name
            let data = try await session.runExport(asPDF ? "the PDF report" : "the HTML report") {
                let html = try await background { try ReportBuilder.html(store: store, options: reportOptions) }
                return asPDF ? try await PDFRenderer.pdf(html: html) : Data(html.utf8)
            }
            return download(data, filename: "\(name) – \(options.title).\(asPDF ? "pdf" : "html")",
                            contentType: asPDF ? "application/pdf" : "text/html; charset=utf-8")
        }

        // Lighthouse
        crawls.post(":id/lighthouse") { request, context in
            let body = try await request.decodeJSON(LighthouseBody.self, context: context)
            let session = try await session(context)
            try await session.startLighthouse(top: body.top, rowIDs: body.rowIds ?? [])
            return JSON(await session.state())
        }
        crawls.get(":id/speed") { _, context in
            let store = try await session(context).store
            return JSON(try await background { try store.lighthouseMeasuredPages() })
        }
        crawls.delete(":id/lighthouse") { _, context in
            let session = try await session(context)
            await session.cancelLighthouse()
            return JSON(await session.state())
        }
    }

    // MARK: - Helpers

    private func session(_ context: AppContext) async throws -> CrawlSession {
        try await library.session(context.parameters.string("id"))
    }

    private func selection(_ request: Request, default fallback: Selection = .filter(.internalHTML)) throws -> Selection {
        guard let text = request.query("selection") else { return fallback }
        guard let selection = Selection(text) else { throw ServerError.badRequest("Unknown table \(text).") }
        return selection
    }

    /// The query behind a table, or nil for the overview.
    private func listQuery(_ request: Request, selection: Selection) throws -> URLListQuery? {
        guard let filter = selection.urlFilter else { return nil }
        let sort = request.query("sort").flatMap(URLTableColumn.init(id:))?.sortableColumn
        return URLListQuery(filter: filter, search: request.query("q") ?? "", sortColumn: sort,
                            ascending: request.query("asc") != "false")
    }

    private func counts(_ store: CrawlStore) throws -> CountsDTO {
        let issueCounts = try store.issueCounts()
        let issues = issueCounts.compactMap { code, count -> IssueCountDTO? in
            // Codes from checks 2.0 dropped (the Google ones) have no definition, so they're left out.
            guard count > 0, let definition = IssueCatalogue.definition(for: code) else { return nil }
            return IssueCountDTO(issue: IssueDTO(definition), count: count)
        }
        .sorted { ($0.issue.severity, $0.issue.category, $0.issue.title) < ($1.issue.severity, $1.issue.category, $1.issue.title) }
        var filters: [String: Int] = [:]
        for (filter, count) in try store.filterCounts() {
            if let name = Selection.name(of: filter) { filters[name] = count }
        }
        if let nearDuplicates = try? store.pool.read({ db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT url_id) FROM near_duplicates")
        }) {
            filters["nearDuplicates"] = nearDuplicates
        }
        return CountsDTO(
            issues: issues, filters: filters,
            extractions: try store.extractionCounts().map { NamedCountDTO(name: $0.name, count: $0.count) },
            searches: try store.searchHitCounts().map { NamedCountDTO(name: $0.name, count: $0.count) },
            hasLighthouse: try store.hasLighthouseData(),
            overview: try store.overview()
        )
    }
}

/// Runs database work off the server's own threads.
func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated, operation: work).value
}

func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

/// A server-sent event stream: `initial` first, then whatever the hub publishes, with a comment
/// every 15 seconds so a closed tab is noticed and its listener dropped.
func eventStream(_ hub: EventHub, initial: [ServerEvent] = []) -> Response {
    let events = hub.subscribe()
    let body = ResponseBody { writer in
        let (merged, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(128))
        let forward = Task {
            for await event in events { continuation.yield(event.wireFormat) }
            continuation.finish()
        }
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                continuation.yield(": keep-alive\n\n")
            }
        }
        defer {
            forward.cancel()
            heartbeat.cancel()
        }
        try await writer.write(ByteBuffer(string: "retry: 2000\n\n"))
        for event in initial { try await writer.write(ByteBuffer(string: event.wireFormat)) }
        for await chunk in merged {
            try await writer.write(ByteBuffer(string: chunk))
        }
        try await writer.finish(nil)
    }
    return Response(status: .ok, headers: [
        .contentType: "text/event-stream",
        .cacheControl: "no-store",
        .init("X-Accel-Buffering")!: "no",
    ], body: body)
}
