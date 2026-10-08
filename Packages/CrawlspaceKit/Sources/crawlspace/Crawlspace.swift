import ArgumentParser
import Audit
import Compare
import CrawlCore
import Crawler
import Export
import Foundation
import Integrations
import Lighthouse
import Parsing
import Rendering
import Server
import Storage

/// Starts the right thing for the arguments.
///
/// The menu-bar app and scheduled runs need AppKit's run loop on the main thread, for the menu and
/// for WebKit. Started from inside Swift's async `main` that loop would run inside a main-queue job,
/// and nothing on the main actor would ever get a turn. So those two start here, before any async
/// code, and every other command runs as an ordinary async command.
@main
enum Main {
    static func main() {
        let command: any ParsableCommand
        do {
            command = try Crawlspace.parseAsRoot()
        } catch {
            Crawlspace.exit(withError: error)
        }
        switch command {
        case let serve as Serve:
            CrawlspacePaths.makePrivate()
            serve.start()
        case let schedule as RunSchedule:
            CrawlspacePaths.makePrivate()
            schedule.start()
        case let asyncCommand as any AsyncParsableCommand:
            runAsync(asyncCommand)
        default:
            var command = command
            do { try command.run() } catch { Crawlspace.exit(withError: error) }
        }
    }

    private static func runAsync(_ command: any AsyncParsableCommand) {
        nonisolated(unsafe) var command = command
        Task {
            do {
                try await command.run()
                Crawlspace.exit()
            } catch {
                Crawlspace.exit(withError: error)
            }
        }
        dispatchMain()
    }
}

struct Crawlspace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crawlspace",
        abstract: "Crawl a site and audit it for SEO problems.",
        discussion: "With no command, starts Crawlspace in the menu bar and opens it in your browser.",
        version: AppVersion.current,
        subcommands: [Serve.self, RunSchedule.self, Crawl.self, Summary.self, ExportCommand.self, Report.self, Robots.self, Render.self,
                      CompareCommand.self,
                      ClickUpLists.self, ClickUpExport.self, Analyse.self, Explain.self, LighthouseCommand.self],
        defaultSubcommand: Serve.self
    )
}

// MARK: - serve

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run Crawlspace in the menu bar and open it in the browser (the default)."
    )

    @Option(help: "Port to listen on, or the first free one after it.") var port: Int = 7777
    @Flag(name: .customLong("no-open"), help: "Don't open the browser.") var noOpen = false
    @Flag(help: "Serve the API only, for the Vite dev server in Web/ (npm run dev).") var dev = false
    @Option(help: .hidden) var after: Int32?
    /// How launchd starts scheduled crawls (see `LaunchAgent.definition`).
    @Option(name: .customLong("run-schedule"), help: .hidden) var runSchedule: String?
    /// Finder and Xcode sometimes pass arguments of their own; they mean nothing here.
    @Argument(parsing: .allUnrecognized, help: .hidden) var ignored: [String] = []

    /// Never returns: the app runs until it quits.
    func start() -> Never {
        MainActor.assumeIsolated {
            if let runSchedule {
                guard let id = UUID(uuidString: runSchedule) else {
                    Crawlspace.exit(withError: ValidationError("Not a schedule id: \(runSchedule)"))
                }
                AppShell.runSchedule(id)
            }
            AppShell.serve(ServerOptions(port: port, openBrowser: !noOpen && !dev, developmentUI: dev, afterPID: after))
        }
    }
}

struct RunSchedule: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-schedule",
        abstract: "Run a scheduled crawl now, without the app, as launchd does."
    )

    @Argument(help: "The schedule's id.") var id: String

    func start() -> Never {
        guard let uuid = UUID(uuidString: id) else { Crawlspace.exit(withError: ValidationError("Not a schedule id: \(id)")) }
        MainActor.assumeIsolated { AppShell.runSchedule(uuid) }
    }
}

// MARK: - crawl

struct Crawl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Crawl a site into a .crawlspace package.")

    @Argument(help: "The URL to start from.") var url: String
    @Option(name: .shortAndLong, help: "Where to write the .crawlspace package.") var out: String?
    @Option(help: "A saved crawl configuration (JSON) to start from.") var preset: String?
    @Option(name: .customLong("max-urls"), help: "Maximum URLs to crawl.") var maxURLs: Int?
    @Option(name: .shortAndLong, help: "Concurrent requests.") var concurrency: Int?
    @Option(help: "Request timeout in seconds.") var timeout: Double?
    @Option(help: "Maximum URLs per second (0 for no limit).") var rate: Double?
    @Option(help: "Only crawl URLs matching this regular expression (repeatable).") var include: [String] = []
    @Option(help: "Skip URLs matching this regular expression (repeatable).") var exclude: [String] = []
    @Option(help: "Platform defaults: auto, shopify or none.") var platform: String = "auto"
    @Flag(help: "Leave URLs robots.txt blocks out of the reports.") var skipRobotsBlocked = false
    @Option(help: "E-commerce checks: auto (on for Shopify), on or off.") var ecommerce: String = "auto"
    @Option(name: .customLong("user-agent"), help: "User-Agent header to send.") var userAgent: String?
    @Flag(name: .customLong("ignore-robots"), help: "Crawl URLs that robots.txt disallows. Only use this on sites you control.")
    var ignoreRobots = false
    @Flag(name: .customLong("store-html"), help: "Store each page's HTML in the package.") var storeHTML = false
    @Flag(help: "Render pages with WebKit so JavaScript-built content is audited.") var render = false
    @Option(name: .customLong("render-wait"), help: "Seconds to wait after load when rendering.") var renderWait: Double?
    @Option(help: "Crawl an XML sitemap's URLs (repeatable). Use with --mode sitemap to crawl only those.")
    var sitemap: [String] = []
    @Option(help: "spider (default), list or sitemap.") var mode: String?
    @Option(name: .customLong("list-file"), help: "A file of URLs, one per line, for list mode.") var listFile: String?
    @Option(help: "Username for HTTP basic authentication.") var username: String?
    @Option(help: "Cookie header sent to the site being crawled, e.g. \"session=…\".") var cookie: String?
    @Option(name: .customLong("export-csv"), help: "Also export the internal HTML table to this CSV file when the crawl finishes.") var exportCSV: String?
    @Flag(name: .shortAndLong, help: "Don't print progress.") var quiet = false

    mutating func run() async throws {
        var config = CrawlConfig()
        if let preset {
            config = try JSONDecoder().decode(CrawlConfig.self, from: Data(contentsOf: URL(filePath: preset)))
        }
        config.startURL = url
        if let maxURLs { config.maxURLs = maxURLs }
        if let concurrency { config.concurrency = concurrency }
        if let timeout { config.timeoutSeconds = timeout }
        if let rate { config.maxURLsPerSecond = rate }
        if let userAgent { config.userAgent = userAgent }
        if !include.isEmpty { config.includePatterns = include }
        if !exclude.isEmpty { config.excludePatterns = exclude }
        if ignoreRobots { config.respectRobotsTxt = false }
        if storeHTML { config.storeHTML = true }
        if render { config.renderJavaScript = true }
        if let renderWait { config.renderSettleSeconds = renderWait }
        if !sitemap.isEmpty { config.sitemapURLs = sitemap }
        if let cookie { config.cookieHeader = cookie }
        if let username { config.basicAuthUsername = username }
        if let mode {
            guard let parsed = CrawlConfig.Mode(rawValue: mode) else {
                throw ValidationError("Mode must be spider, list or sitemap.")
            }
            config.mode = parsed
        }
        if let listFile {
            config.listURLs = try String(contentsOf: URL(filePath: listFile), encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if config.mode == .spider { config.mode = .list }
        }

        // Passwords come from the environment or the secrets file, never a command-line flag, so they
        // don't end up in shell history or process listings.
        let password = ProcessInfo.processInfo.environment["CRAWLSPACE_PASSWORD"]

        let errors = config.validationErrors()
        guard errors.isEmpty else { throw ValidationError(errors.joined(separator: " ")) }

        switch platform.lowercased() {
        case "auto", "automatic": config.platformProfile = .automatic
        case "shopify": config.platformProfile = .shopify
        case "none", "off": config.platformProfile = .none
        default: throw ValidationError("--platform takes auto, shopify or none.")
        }
        switch ecommerce.lowercased() {
        case "auto", "automatic": config.ecommerceMode = .automatic
        case "on": config.ecommerceMode = .on
        case "off": config.ecommerceMode = .off
        default: throw ValidationError("--ecommerce takes auto, on or off.")
        }
        if skipRobotsBlocked { config.skipRobotsBlocked = true }
        config = await PlatformDetector.tailor(config)
        if let profile = config.appliedProfile, !quiet {
            print("\(profile) detected: filters, sorting, search, variants and share buttons won't be crawled, and pages robots.txt blocks are left out of the reports.")
        }

        let packageURL = out.map { URL(filePath: $0) }
            ?? CrawlStore.suggestedPackageURL(in: URL(filePath: FileManager.default.currentDirectoryPath), for: config)
        let store: CrawlStore
        if FileManager.default.fileExists(atPath: packageURL.path) {
            store = try CrawlStore.open(at: packageURL)
            if !quiet { print("Resuming \(packageURL.lastPathComponent)") }
        } else {
            store = try CrawlStore.create(at: packageURL, config: config)
        }

        let engine = try CrawlEngine(store: store, config: try store.status() == .new ? config : nil, password: password)
        let quiet = quiet
        let reporter = Task {
            for await progress in engine.progress where !quiet {
                let line = "\(progress.phase.rawValue.capitalized): \(progress.crawled) crawled, \(progress.queued) queued, \(String(format: "%.1f", progress.urlsPerSecond))/s"
                FileHandle.standardError.write(Data(("\r\u{1B}[K" + line).utf8))
            }
        }
        await engine.run()
        reporter.cancel()
        if !quiet { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        try Summary.printSummary(store: store, packageURL: packageURL)
        if let exportCSV {
            let ids = try store.rowIDs(for: URLListQuery(filter: .internalHTML, sortColumn: .address))
            try TableExport.export(store: store, ids: ids, columns: URLFilter.internalHTML.defaultColumns,
                                   format: .csv, to: URL(filePath: exportCSV))
            print("Exported \(ids.count) rows to \(exportCSV)")
        }
    }
}

// MARK: - summary

struct Summary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a summary of a crawl.")

    @Argument(help: "Path to a .crawlspace package.") var package: String
    @Flag(help: "Print JSON instead of text.") var json = false

    mutating func run() async throws {
        let url = URL(filePath: package)
        let store = try CrawlStore.open(at: url)
        if json {
            let issues = try store.issueCounts()
            let overview = try store.overview()
            let payload: [String: Any] = [
                "status": try store.status().rawValue,
                "crawled": overview.crawled,
                "internalHTML": overview.internalHTML,
                "indexable": overview.indexable,
                "nonIndexable": overview.nonIndexable,
                "issues": issues,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            Swift.print(String(decoding: data, as: UTF8.self))
        } else {
            try Self.printSummary(store: store, packageURL: url)
        }
    }

    static func printSummary(store: CrawlStore, packageURL: URL) throws {
        let overview = try store.overview()
        let issues = try store.issueCounts()
        Swift.print("""

        \(packageURL.lastPathComponent)  [\(try store.status().rawValue)]
          URLs crawled     \(overview.crawled)  (\(overview.internalHTML) internal HTML, \(overview.external) external, \(overview.internalOther) other)
          Indexable        \(overview.indexable)     Non-indexable \(overview.nonIndexable)
          Status codes     \(overview.statusClasses.filter { $0.count > 0 }.map { "\($0.label): \($0.count)" }.joined(separator: "   "))
          Avg response     \(overview.averageResponseMs.map { String(format: "%.0f ms", $0) } ?? "—")
        """)

        for severity in IssueSeverity.allCases {
            let rows = IssueCatalogue.all
                .filter { $0.severity == severity && (issues[$0.code] ?? 0) > 0 }
                .sorted { (issues[$0.code] ?? 0) > (issues[$1.code] ?? 0) }
            guard !rows.isEmpty else { continue }
            Swift.print("\n  \(severity.label.uppercased())")
            for definition in rows {
                let count = issues[definition.code] ?? 0
                Swift.print("    \(String(count).padding(toLength: 7, withPad: " ", startingAt: 0)) \(definition.category.rawValue): \(definition.title)")
            }
        }
        Swift.print("")
    }
}

// MARK: - export

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export a crawl table to CSV or Excel.")

    @Argument(help: "Path to a .crawlspace package.") var package: String
    @Option(name: .shortAndLong, help: "Output file (.csv or .xlsx).") var out: String
    @Option(help: "What to export: internal-html, internal-all, external, images, css-js, not-crawled, all, or issue:<code>.")
    var filter: String = "internal-html"

    mutating func run() async throws {
        let store = try CrawlStore.open(at: URL(filePath: package))
        let url = URL(filePath: out)
        let format: ExportFormat = url.pathExtension.lowercased() == "xlsx" ? .xlsx : .csv
        let selection: URLFilter = switch filter {
        case "internal-html": .internalHTML
        case "internal-all": .internalAll
        case "external": .external
        case "images": .images
        case "css-js": .cssAndJavaScript
        case "not-crawled": .notCrawled
        case "all": .all
        default:
            if filter.hasPrefix("issue:") {
                .issue(String(filter.dropFirst("issue:".count)))
            } else {
                throw ValidationError("Unknown filter '\(filter)'.")
            }
        }
        var columns = selection.defaultColumns
        if case .issue(let code) = selection, let definition = IssueCatalogue.definition(for: code) {
            columns = definition.tableColumns
        }
        let ids = try store.rowIDs(for: URLListQuery(filter: selection, sortColumn: .address))
        try TableExport.export(store: store, ids: ids, columns: columns, format: format, to: url)
        print("Exported \(ids.count) rows to \(out)")
    }
}

// MARK: - report

struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build a client-facing audit report (PDF or HTML).")

    @Argument(help: "Path to a .crawlspace package.") var package: String
    @Option(name: .shortAndLong, help: "Output file (.pdf or .html).") var out: String
    @Option(help: "Report title.") var title: String = "SEO Audit"
    @Option(help: "Client name shown in the header.") var client: String?
    @Option(name: .customLong("prepared-by"), help: "Who prepared the report.") var preparedBy: String?
    @Option(help: "Accent colour, e.g. #2F6FEB.") var accent: String = "#2F6FEB"
    @Option(help: "Logo image (PNG) to embed in the header.") var logo: String?
    @Option(help: "How many issues to detail.") var issues: Int = 25

    mutating func run() async throws {
        let store = try CrawlStore.open(at: URL(filePath: package))
        var options = ReportOptions(title: title, accent: accent, maxIssues: issues)
        options.clientName = client ?? ""
        options.preparedBy = preparedBy ?? ""
        if let logo { options.logo = try Data(contentsOf: URL(filePath: logo)) }

        let html = try ReportBuilder.html(store: store, options: options)
        let url = URL(filePath: out)
        if url.pathExtension.lowercased() == "pdf" {
            let pdf = try await PDFRenderer.pdf(html: html)
            try pdf.write(to: url)
        } else {
            try Data(html.utf8).write(to: url)
        }
        print("Wrote \(out)")
    }
}

// MARK: - render

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render one URL with WebKit and report what JavaScript changed.")

    @Argument(help: "The URL to render.") var url: String
    @Option(help: "Seconds to wait after load for late DOM changes.") var settle: Double = 2
    @Flag(help: "Print the rendered HTML.") var printHTML = false

    mutating func run() async throws {
        guard let target = URLNormalizer.normalize(url) else { throw ValidationError("Not a valid http(s) URL.") }
        let userAgent = "Crawlspace/1.0"
        let renderer = PageRenderer(options: .init(userAgent: userAgent, concurrency: 1, settleSeconds: settle))
        let fetcher = Fetcher(userAgent: userAgent, timeout: 20, maxConnectionsPerHost: 2)

        var rawPage: ParsedPage?
        if case .success(let response) = await fetcher.fetch(target, body: .always(maxBytes: 20_000_000)), let body = response.body {
            rawPage = HTMLParser.parse(body, headerCharset: response.charset)
        }
        let result = await renderer.render(target)
        guard let html = result.html else {
            print("Rendering failed: \(result.error ?? "unknown error")")
            return
        }
        let rendered = HTMLParser.parse(Data(html.utf8), headerCharset: "utf-8")
        func links(_ page: ParsedPage?) -> Int { page?.links.count { $0.type == .anchor } ?? 0 }

        print("""
        \(target.absoluteString)
          status        \(result.statusCode.map(String.init) ?? "—")
          render time   \(String(format: "%.0f ms", result.renderMs))
          title         raw: \(rawPage?.titles.first ?? "—")
                        rendered: \(rendered.titles.first ?? "—")
          h1            raw: \(rawPage?.h1.first ?? "—")
                        rendered: \(rendered.h1.first ?? "—")
          words         raw: \(rawPage?.wordCount ?? 0)  rendered: \(rendered.wordCount)
          links         raw: \(links(rawPage))  rendered: \(links(rendered))
        """)
        if printHTML { print(html) }
    }
}

// MARK: - compare

struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Show what changed between two crawls of the same site."
    )

    @Argument(help: "The earlier crawl.") var baseline: String
    @Argument(help: "The later crawl.") var current: String
    @Flag(help: "Print JSON instead of text.") var json = false

    mutating func run() async throws {
        let store = try CrawlStore.open(at: URL(filePath: current))
        let comparison = try CrawlComparer.compare(baseline: URL(filePath: baseline), current: store)

        if json {
            let payload: [String: Any] = [
                "baseline": comparison.baselineName,
                "current": comparison.currentName,
                "added": comparison.counts.added,
                "removed": comparison.counts.removed,
                "statusChanged": comparison.counts.statusChanged,
                "titleChanged": comparison.counts.titleChanged,
                "newIssues": comparison.counts.newIssues,
                "fixedIssues": comparison.counts.fixedIssues,
                "issueDeltas": comparison.issueDeltas.map {
                    ["code": $0.code, "before": $0.before, "after": $0.after, "change": $0.change]
                },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }

        print("""

        \(comparison.baselineName)  →  \(comparison.currentName)
          URLs            \(comparison.counts.baselineURLs) → \(comparison.counts.currentURLs)
          New URLs        \(comparison.counts.added)
          Gone            \(comparison.counts.removed)
          Status changed  \(comparison.counts.statusChanged)
          Titles changed  \(comparison.counts.titleChanged)
          New issues      \(comparison.counts.newIssues)
          Fixed issues    \(comparison.counts.fixedIssues)
        """)

        if !comparison.issueDeltas.isEmpty {
            print("\n  ISSUE CHANGES")
            for delta in comparison.issueDeltas {
                let change = delta.change > 0 ? "+\(delta.change)" : "\(delta.change)"
                print("    \(change.padding(toLength: 7, withPad: " ", startingAt: 0)) \(delta.title)  (\(delta.before) → \(delta.after))")
            }
        }
        print("")
    }
}

// MARK: - robots

struct Robots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check whether URLs are allowed by a site's robots.txt.")

    @Argument(help: "URLs to test.") var urls: [String]
    @Option(name: .customLong("user-agent"), help: "Product token to match against User-agent lines.") var userAgent: String = "Crawlspace"

    mutating func run() async throws {
        let fetcher = Fetcher(userAgent: "Crawlspace/1.0", timeout: 20, maxConnectionsPerHost: 2)
        let cache = RobotsCache(fetcher: fetcher, productToken: userAgent)
        for string in urls {
            guard let url = URLNormalizer.normalize(string) else {
                print("\(string): not a valid http(s) URL")
                continue
            }
            let verdict = await cache.verdict(for: url)
            let rule = verdict.rule.map { "\($0.allow ? "Allow" : "Disallow"): \($0.pattern) (line \($0.line))" } ?? "no matching rule"
            print("\(verdict.allowed ? "ALLOWED " : "BLOCKED ") \(url.absoluteString)  —  \(rule)")
        }
    }
}


// MARK: - clickup

/// Shared options: where the token comes from, and which ClickUp to talk to.
struct ClickUpOptions: ParsableArguments {
    @Option(help: "ClickUp personal API token. Defaults to CLICKUP_TOKEN, then the saved token.")
    var token: String?

    @Option(help: "API base, for testing against a stand-in.")
    var base: String = ClickUpClient.defaultBase.absoluteString

    func client() throws -> ClickUpClient {
        // A flag would end up in shell history and in ps; the environment or the secrets file won't.
        let token = token
            ?? ProcessInfo.processInfo.environment["CLICKUP_TOKEN"]
            ?? ClickUpClient.storedToken()
        guard let token, !token.isEmpty else {
            throw ValidationError("""
            No ClickUp token. Create one in ClickUp ▸ Settings ▸ Apps, then either set CLICKUP_TOKEN \
            or save it in Crawlspace's settings.
            """)
        }
        guard let base = URL(string: base) else { throw ValidationError("--base isn't a URL.") }
        return ClickUpClient(token: token, base: base)
    }
}

struct ClickUpLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clickup-lists",
        abstract: "Show the ClickUp lists an export can be filed into, with their ids."
    )

    @OptionGroup var clickUp: ClickUpOptions

    mutating func run() async throws {
        let client = try clickUp.client()
        for workspace in try await client.workspaces() {
            print("\(workspace.name)  [workspace \(workspace.id)]")
            for space in try await client.spaces(workspace: workspace.id) {
                print("  \(space.name)")
                for list in try await client.lists(space: space.id) {
                    print("    \(list.name)  --list \(list.id)")
                }
                for folder in try await client.folders(space: space.id) {
                    print("    \(folder.name)/")
                    // The folder listing usually carries its lists; ask only when it doesn't.
                    var lists = folder.lists ?? []
                    if lists.isEmpty { lists = try await client.lists(folder: folder.id) }
                    for list in lists {
                        print("      \(list.name)  --list \(list.id)")
                    }
                }
            }
        }
    }
}

struct ClickUpExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clickup",
        abstract: "File a crawl's issues into ClickUp: a task per issue, subtasks for the pages."
    )

    @Argument(help: "Path to a .crawlspace package.") var package: String
    @Option(help: "List id to file into. Find one with clickup-lists.") var list: String
    @Option(help: "Which severities to export: error, warning, notice (comma separated).")
    var severities: String = "error,warning"
    @Option(help: "Most subtasks per issue. 0, the default, files every affected page.")
    var cap: Int = 0
    @Flag(help: "Don't attach the CSV of everything the cap left out.") var noAttachment = false
    @Option(help: "Extra tag to put on every task. Repeatable.") var tag: [String] = []
    @Option(help: "Severities filed as one task with a table of URLs instead of subtasks (comma separated, or none).")
    var tables: String = "notice"
    @OptionGroup var clickUp: ClickUpOptions

    mutating func run() async throws {
        let wanted = severities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let chosen = Set(IssueSeverity.allCases.filter { wanted.contains($0.name) })
        guard !chosen.isEmpty else {
            throw ValidationError("--severities takes any of error, warning, notice.")
        }

        let store = try CrawlStore.open(at: URL(filePath: package))
        let tableNames = tables.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let asTables = Set(IssueSeverity.allCases.filter { tableNames.contains($0.name) })
        let options = ClickUpExportOptions(listID: list, severities: chosen, subtaskLimit: cap,
                                           attachFullList: !noAttachment, extraTags: tag, tableSeverities: asTables)
        let result = try await ClickUpExporter.export(store: store, options: options,
                                                      client: try clickUp.client()) { title, _ in
            print("  \(title)")
        }
        print("Filed \(result.summary) into list \(list).")
        if result.urlsInAttachments > 0 {
            print("\(result.urlsCovered.formatted()) URLs as subtasks, \(result.urlsInAttachments.formatted()) in CSVs.")
        }
    }
}


// MARK: - analyse

struct Analyse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-run the post-crawl analysis on a saved crawl.",
        discussion: "Picks up improvements to the checks without crawling the site again."
    )

    @Argument(help: "Path to a .crawlspace package.") var package: String

    mutating func run() async throws {
        let store = try CrawlStore.open(at: URL(filePath: package))
        let before = try store.issueCounts()
        try PostCrawlAnalyzer.run(store: store)
        let after = try store.issueCounts()
        let changed = Set(before.keys).union(after.keys)
            .filter { before[$0, default: 0] != after[$0, default: 0] }
            .sorted()
        guard !changed.isEmpty else {
            print("Analysed. Nothing changed.")
            return
        }
        print("Analysed. Changed:")
        for code in changed {
            let title = IssueCatalogue.definition(for: code).map { "\($0.category.rawValue): \($0.title)" } ?? code
            print("  \(before[code, default: 0]) → \(after[code, default: 0])  \(title)")
        }
    }
}

// MARK: - lighthouse

struct LighthouseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lighthouse",
        abstract: "Measure pages of a crawl with Lighthouse, mobile and desktop.",
        discussion: "With neither --top nor --url, measures as many pages as the crawl's settings ask for."
    )

    @Argument(help: "Path to a .crawlspace package.") var package: String
    @Option(help: "Measure this many of the most-linked indexable pages.") var top: Int?
    @Option(help: "Measure this page (repeatable). It must be in the crawl.") var url: [String] = []

    mutating func run() async throws {
        guard case .ready(let toolchain) = LighthouseToolchain.locate() else {
            throw ValidationError("Lighthouse isn't installed. Open Crawlspace to set it up, or set CRAWLSPACE_NODE, CRAWLSPACE_LIGHTHOUSE_CLI and CHROME_PATH.")
        }
        let store = try CrawlStore.open(at: URL(filePath: package))
        let config = try store.loadConfig()
        var pages: [LighthouseBatch.Page] = []
        for address in url {
            guard let id = try store.rowID(forURL: address) else { throw ValidationError("\(address) isn't in this crawl.") }
            pages.append(.init(id: id, url: address))
        }
        if url.isEmpty {
            // --top asks for the most-linked pages, whatever the platform.
            pages = top != nil
                ? try store.lighthouseCandidates(limit: top!).map { .init(id: $0.id, url: $0.url) }
                : try LighthousePages.choose(store: store, config: config)
        }
        guard !pages.isEmpty else {
            print("No pages to measure.")
            return
        }
        let plan = pages.contains { $0.template != nil } ? " (one of each Shopify template)" : ""
        print("Measuring \(pages.count) page\(pages.count == 1 ? "" : "s")\(plan), mobile and desktop…")
        let batch = LighthouseBatch(store: store, runner: LighthouseRunner(toolchain: toolchain), pages: pages,
                                    headers: LighthouseBatch.headers(for: config))
        let result = try await batch.run { progress in
            let current = progress.currentURL.map { " \(progress.currentDevice?.label ?? "") \($0)" } ?? ""
            FileHandle.standardError.write(Data("\r\u{1B}[K\(progress.done)/\(progress.total)\(current)".utf8))
        }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
        for page in pages {
            guard let row = try store.row(id: page.id) else { continue }
            func score(_ value: Double?) -> String { value.map { String(Int($0)) } ?? "–" }
            let template = page.template.map { "\($0): " } ?? ""
            print("  \(score(row.lighthouseMobile.score).padding(toLength: 4, withPad: " ", startingAt: 0))"
                  + "\(score(row.lighthouseDesktop.score).padding(toLength: 4, withPad: " ", startingAt: 0))\(template)\(page.url)")
        }
        print("Mobile and desktop scores. \(result.measured) runs measured.")
        for failure in result.failures {
            print("  \(failure.device.label) \(failure.url): \(failure.message)")
        }
    }
}

// MARK: - explain

struct Explain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show exactly what is behind the issues on one URL, and how to fix each."
    )

    @Argument(help: "Path to a .crawlspace package.") var package: String
    @Argument(help: "The URL to explain.") var url: String
    @Option(help: "Only this issue code.") var issue: String?

    mutating func run() async throws {
        let store = try CrawlStore.open(at: URL(filePath: package))
        guard let id = try store.rowID(forURL: url) else {
            throw ValidationError("\(url) isn't in that crawl.")
        }
        let codes = try issue.map { [$0] } ?? store.issueCodes(for: id)
        guard !codes.isEmpty else {
            print("No issues on \(url).")
            return
        }
        for code in codes {
            let title = IssueCatalogue.definition(for: code).map { "\($0.category.rawValue): \($0.title)" } ?? code
            let evidence = try IssueEvidenceBuilder.evidence(for: code, urlID: id, store: store)
            print("\n\(title)")
            for item in evidence.items {
                var line = "  • \(item.text)"
                if let position = item.position { line += "  [\(position.label.lowercased())]" }
                if let shared = item.pagesWithSameLink, shared > 1 { line += "  (on \(shared) pages)" }
                print(line)
            }
            if evidence.more > 0 { print("  …and \(evidence.more) more") }
            print("  Fix: \(evidence.fix)")
        }
    }
}
