import Audit
import CrawlCore
import Foundation
import Storage

public struct ReportOptions: Sendable, Hashable {
    public var title: String
    public var clientName: String
    public var preparedBy: String
    public var notes: String
    /// Accent colour as a hex string, e.g. `#2F6FEB`.
    public var accent: String
    /// PNG or JPEG logo, embedded in the report so it stays self-contained.
    public var logo: Data?
    /// How many fixes each issue shows before the rest are behind "Show N more".
    public var examplesPerIssue: Int
    /// For print: everything listed, with nothing behind "Show N more", which a PDF can't open.
    public var forPrint: Bool

    public init(title: String = "SEO Audit", clientName: String = "", preparedBy: String = "",
                notes: String = "", accent: String = "#2F6FEB", logo: Data? = nil,
                examplesPerIssue: Int = 5, forPrint: Bool = false) {
        self.title = title
        self.clientName = clientName
        self.preparedBy = preparedBy
        self.notes = notes
        self.accent = accent
        self.logo = logo
        self.examplesPerIssue = examplesPerIssue
        self.forPrint = forPrint
    }
}

/// Builds a self-contained HTML audit report — no external stylesheets, fonts or images, so it
/// prints and emails cleanly.
public enum ReportBuilder {
    public static func html(store: CrawlStore, options: ReportOptions = ReportOptions()) throws -> String {
        let config = try store.loadConfig()
        let overview = try store.overview()
        let issueCounts = try store.issueCounts()
        let started = try store.meta("started_at").flatMap { ISO8601DateFormatter().date(from: $0) }

        let issues = IssueCatalogue.all
            .compactMap { definition -> (IssueDefinition, Int)? in
                let count = issueCounts[definition.code] ?? 0
                return count > 0 ? (definition, count) : nil
            }
            .sorted { ($0.0.severity, -$0.1) < ($1.0.severity, -$1.1) }

        var body = ""
        body += header(options: options, config: config, started: started)
        body += summary(overview: overview, issues: issues)
        body += charts(overview: overview)
        body += try issueSections(store: store, issues: issues, options: options)
        body += settings(config: config, overview: overview)

        return document(title: options.title, accent: options.accent, body: body)
    }

    // MARK: - Sections

    static func header(options: ReportOptions, config: CrawlConfig, started: Date?) -> String {
        let site = CrawlScope(config: config).startHost
        let logo = options.logo.map {
            "<img class=\"logo\" src=\"data:image/png;base64,\($0.base64EncodedString())\" alt=\"\">"
        } ?? ""
        let date = (started ?? Date()).formatted(date: .long, time: .omitted)
        var meta = ["<span><strong>Site</strong> \(escape(site))</span>", "<span><strong>Crawled</strong> \(escape(date))</span>"]
        if !options.clientName.isEmpty { meta.insert("<span><strong>Client</strong> \(escape(options.clientName))</span>", at: 0) }
        if !options.preparedBy.isEmpty { meta.append("<span><strong>Prepared by</strong> \(escape(options.preparedBy))</span>") }

        return """
        <header>
          \(logo)
          <h1>\(escape(options.title))</h1>
          <div class="meta">\(meta.joined())</div>
          \(options.notes.isEmpty ? "" : "<p class=\"notes\">\(escape(options.notes))</p>")
        </header>
        """
    }

    private static func summary(overview: OverviewStats, issues: [(IssueDefinition, Int)]) -> String {
        func total(_ severity: IssueSeverity) -> Int {
            issues.filter { $0.0.severity == severity }.reduce(0) { $0 + $1.1 }
        }
        let tiles: [(String, String, String)] = [
            ("URLs crawled", overview.crawled.formatted(), "\(overview.internalHTML.formatted()) internal HTML"),
            ("Indexable", overview.indexable.formatted(), "\(overview.nonIndexable.formatted()) non-indexable"),
            ("Errors", total(.error).formatted(), "must fix"),
            ("Warnings", total(.warning).formatted(), "worth fixing"),
            ("Notices", total(.notice).formatted(), "opportunities"),
            ("Avg response", overview.averageResponseMs.map { String(format: "%.0f ms", $0) } ?? "—", "internal URLs"),
        ]
        let cards = tiles.map { title, value, detail in
            """
            <div class="tile"><div class="tile-title">\(escape(title))</div>
            <div class="tile-value">\(escape(value))</div>
            <div class="tile-detail">\(escape(detail))</div></div>
            """
        }.joined()
        return "<section><h2>Summary</h2><div class=\"tiles\">\(cards)</div></section>"
    }

    private static func charts(overview: OverviewStats) -> String {
        let statusColours = ["2xx": "#1E7F4F", "3xx": "#B56B00", "4xx": "#C0362C", "5xx": "#6C3FB5"]
        let responses = overview.statusClasses.filter { $0.count > 0 }
        let depths = overview.depths

        var html = "<section class=\"charts\"><h2>Where the crawl went</h2><div class=\"chart-row\">"
        html += chart(title: "Response codes", subtitle: "Internal URLs", buckets: responses) {
            statusColours[$0] ?? "#6B7280"
        }
        html += chart(title: "Crawl depth", subtitle: "Clicks from the start URL", buckets: depths) { _ in "#2F6FEB" }
        html += "</div></section>"
        return html
    }

    /// A horizontal bar chart as inline SVG: one series, every bar labelled with its value, so it
    /// never depends on colour alone.
    private static func chart(title: String, subtitle: String, buckets: [OverviewStats.Bucket],
                              colour: (String) -> String) -> String {
        guard !buckets.isEmpty, let maximum = buckets.map(\.count).max(), maximum > 0 else {
            return "<div class=\"chart\"><h3>\(escape(title))</h3><p class=\"muted\">No data.</p></div>"
        }
        let rowHeight = 26.0, labelWidth = 74.0, valueWidth = 54.0, width = 420.0
        let barWidth = width - labelWidth - valueWidth
        var rows = ""
        for (index, bucket) in buckets.enumerated() {
            let y = Double(index) * rowHeight
            let length = max(2, barWidth * Double(bucket.count) / Double(maximum))
            rows += """
            <text x="0" y="\(y + 16)" class="axis">\(escape(bucket.label))</text>
            <rect x="\(labelWidth)" y="\(y + 5)" width="\(length)" height="14" rx="4" fill="\(colour(bucket.label))"></rect>
            <text x="\(labelWidth + length + 8)" y="\(y + 16)" class="value">\(bucket.count.formatted())</text>
            """
        }
        return """
        <div class="chart">
          <h3>\(escape(title))</h3><p class="muted">\(escape(subtitle))</p>
          <svg viewBox="0 0 \(width) \(Double(buckets.count) * rowHeight)" width="100%" role="img">\(rows)</svg>
        </div>
        """
    }

    /// Every issue found, each with the fixes it comes to — every image missing its alt text, every
    /// broken address, every page — rather than a few example pages. The first few show; the rest
    /// are behind "Show N more", or, for print, listed in full.
    private static func issueSections(store: CrawlStore, issues: [(IssueDefinition, Int)],
                                      options: ReportOptions) throws -> String {
        guard !issues.isEmpty else {
            return "<section><h2>Issues</h2><p>No issues were found.</p></section>"
        }
        let config = try store.loadConfig()
        let site = URL(string: config.startURL)?.host() ?? config.startURL
        let units = try FixBuilder.units(store: store, severities: Set(IssueSeverity.allCases))
        var fixes: [String: [Fix]] = [:]
        for unit in units {
            var codes = Set(unit.codes)
            for issue in unit.issues { codes.insert(issue.code); codes.formUnion(issue.also) }
            for code in codes { fixes[code, default: []].append(unit) }
        }
        // The address each fix and the pages under it link to.
        var ids: Set<Int64> = []
        for unit in units {
            ids.formUnion(subject(of: unit).map { [$0] } ?? [])
            ids.formUnion(listed(unit).prefix(options.forPrint ? options.examplesPerIssue : nestedLimit))
        }
        let address = Dictionary(uniqueKeysWithValues: try store.rows(ids: Array(ids)).map { ($0.id, $0.url) })

        func link(_ url: String?, _ text: String) -> String {
            guard let url else { return escape(text) }
            return "<a href=\"\(escape(FixBuilder.linkTarget(url)))\">\(escape(text))</a>"
        }
        /// The first few as they are, the rest behind "Show N more" — or all of them, for print. The
        /// pages under a fix are only ever a sample in print, and the first hundred on screen: the
        /// fix is the thing to do, and Crawlspace has every page.
        func list(_ items: [String], total: Int? = nil, more noun: String, nested: Bool = false) -> String {
            let total = total ?? items.count
            let shown = options.forPrint && !nested ? items : Array(items.prefix(options.examplesPerIssue))
            var html = "<ul class=\"examples\">\(shown.joined())</ul>"
            let rest = total - shown.count
            guard rest > 0 else { return html }
            if options.forPrint { return html + "<p class=\"muted more\">…and \(rest.formatted()) more \(noun)</p>" }
            var hidden = items.dropFirst(shown.count).joined()
            if total > items.count { hidden += "<li class=\"muted\">…and \((total - items.count).formatted()) more \(noun), in Crawlspace</li>" }
            return html + "<details><summary>Show \(rest.formatted()) more</summary><ul class=\"examples\">\(hidden)</ul></details>"
        }
        func item(_ unit: Fix) -> String {
            let label = FixBuilder.label(group: unit.group.rawValue, name: unit.name)
            var html = "<li>" + link(subject(of: unit).flatMap { address[$0] }, label)
            if case .page = unit.kind {} else if !unit.pages.isEmpty {
                let count = unit.pages.count
                let linked = if case .target = unit.kind { "linked from" } else { "on" }
                html += " <span class=\"muted\">— \(linked) \(count.formatted()) \(count == 1 ? "page" : "pages")</span>"
            }
            // The pages a group of duplicates or a setting is about, and the addresses in a pattern.
            let pages = listed(unit)
            let under = pages.compactMap { id in address[id].map { "<li>" + link($0, FixBuilder.pageName(for: $0, site: site)) + "</li>" } }
            if !under.isEmpty { html += list(under, total: pages.count, more: "pages", nested: true) }
            return html + "</li>"
        }

        var html = "<section><h2>Issues found</h2>"
        for severity in IssueSeverity.allCases {
            let group = issues.filter { $0.0.severity == severity }
            guard !group.isEmpty else { continue }
            html += "<h3 class=\"severity \(severity.cssClass)\">\(escape(severity.label))</h3>"
            for (definition, count) in group {
                let found = fixes[definition.code] ?? []
                let items: [String]
                if found.isEmpty {
                    // Not one of the fixes: its pages, then.
                    let ids = try store.rowIDs(for: URLListQuery(filter: .issue(definition.code), sortColumn: .inlinks, ascending: false))
                    items = try store.rows(ids: ids).map { "<li>" + link($0.url, $0.url) + "</li>" }
                } else {
                    items = found.map(item)
                }
                let total = found.isEmpty ? count : found.count
                let pages = found.isEmpty ? "" : " <span class=\"muted\">· on \(count.formatted()) \(count == 1 ? "page" : "pages")</span>"
                html += """
                <div class="issue">
                  <div class="issue-head">
                    <span class="badge \(severity.cssClass)">\(total.formatted())</span>
                    <strong>\(escape(definition.category.rawValue)): \(escape(definition.title))</strong>\(pages)
                  </div>
                  <p>\(escape(definition.description))</p>
                  <p class="fix"><strong>How to fix:</strong> \(escape(definition.howToFix))</p>
                  \(list(items, more: found.isEmpty ? "pages" : "fixes"))
                </div>
                """
            }
        }
        return html + "</section>"
    }

    /// How many of the pages under a fix the report shows on screen.
    static let nestedLimit = 100

    /// The address a fix is about, to link it to: the page, image, broken address or link target,
    /// or the first of its pages.
    private static func subject(of unit: Fix) -> Int64? {
        switch unit.kind {
        case .page(let id), .image(let id), .target(let id): id
        case .link(_, let target, _): target
        default: unit.members.first ?? unit.pages.first
        }
    }

    /// What's listed under a fix: the pages a group of duplicates or a setting is about, and the
    /// addresses in a pattern. Nothing for the rest, whose pages are the theme's or the fix itself.
    private static func listed(_ unit: Fix) -> [Int64] {
        switch unit.kind {
        case .cluster, .setting: unit.pages
        case .pattern: unit.members
        default: []
        }
    }

    private static func settings(config: CrawlConfig, overview: OverviewStats) -> String {
        var rows: [(String, String)] = [
            ("Mode", config.mode.label),
            ("Start URL", config.startURL),
            ("robots.txt", config.respectRobotsTxt ? "Respected" : "Ignored"),
            ("JavaScript rendering", config.renderJavaScript ? "On" : "Off"),
            ("User-Agent", config.userAgent),
            ("Concurrent connections", String(config.concurrency)),
            ("URLs discovered", overview.totalURLs.formatted()),
        ]
        if !config.extractors.isEmpty {
            rows.append(("Custom extractors", config.extractors.map(\.name).joined(separator: ", ")))
        }
        if !config.includePatterns.isEmpty { rows.append(("Include patterns", config.includePatterns.joined(separator: ", "))) }
        if !config.excludePatterns.isEmpty { rows.append(("Exclude patterns", config.excludePatterns.joined(separator: ", "))) }

        let table = rows.map { "<tr><th>\(escape($0.0))</th><td>\(escape($0.1))</td></tr>" }.joined()
        return "<section class=\"settings\"><h2>How this crawl was run</h2><table>\(table)</table></section>"
    }

    // MARK: - Document

    static func document(title: String, accent: String, body: String, style: String = "") -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
          :root { --accent: \(escape(accent)); --ink: #1B1D21; --muted: #6B7280; --line: #E5E7EB; }
          * { box-sizing: border-box; }
          body { margin: 0; padding: 32px 36px; font: 13px/1.5 -apple-system, "Helvetica Neue", Arial, sans-serif;
                 color: var(--ink); background: #fff; }
          header { border-bottom: 3px solid var(--accent); padding-bottom: 14px; margin-bottom: 22px; }
          .logo { max-height: 46px; margin-bottom: 10px; }
          h1 { font-size: 26px; margin: 0 0 6px; }
          h2 { font-size: 17px; margin: 26px 0 10px; }
          h3 { font-size: 14px; margin: 18px 0 8px; }
          .meta { color: var(--muted); display: flex; gap: 18px; flex-wrap: wrap; }
          .meta strong { color: var(--ink); font-weight: 600; }
          .notes { margin: 10px 0 0; }
          .tiles { display: flex; flex-wrap: wrap; gap: 10px; }
          .tile { flex: 1 1 140px; border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; }
          .tile-title { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
          .tile-value { font-size: 24px; font-weight: 600; margin: 2px 0; }
          .tile-detail { color: var(--muted); font-size: 11px; }
          .chart-row { display: flex; gap: 22px; flex-wrap: wrap; }
          .chart { flex: 1 1 300px; border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; }
          .chart svg text.axis { font-size: 11px; fill: var(--ink); }
          .chart svg text.value { font-size: 11px; fill: var(--muted); }
          .muted { color: var(--muted); }
          .issue { border: 1px solid var(--line); border-left: 4px solid var(--line); border-radius: 6px;
                   padding: 10px 12px; margin-bottom: 10px; page-break-inside: avoid; }
          .issue-head { display: flex; align-items: baseline; gap: 8px; }
          .issue p { margin: 6px 0; }
          .fix { color: var(--muted); }
          .badge { font-weight: 600; font-variant-numeric: tabular-nums; border-radius: 10px; padding: 1px 8px; font-size: 12px; }
          .badge.error { background: #FBE9E7; color: #A3281E; }
          .badge.warning { background: #FDF0DC; color: #8A5200; }
          .badge.notice { background: #EEF1F6; color: #46506B; }
          .severity.error { color: #A3281E; } .severity.warning { color: #8A5200; } .severity.notice { color: #46506B; }
          .examples { margin: 6px 0 0; padding-left: 18px; color: var(--muted); word-break: break-all; }
          .examples a { color: var(--ink); text-decoration: none; }
          .examples .examples { margin-top: 2px; }
          details summary { cursor: pointer; color: var(--accent); margin: 4px 0 0 18px; }
          .more { margin: 4px 0 0 18px; }
          .settings table { border-collapse: collapse; width: 100%; }
          .settings th { text-align: left; font-weight: 600; width: 190px; padding: 4px 8px 4px 0;
                         vertical-align: top; border-bottom: 1px solid var(--line); }
          .settings td { padding: 4px 0; border-bottom: 1px solid var(--line); word-break: break-all; }
          section { page-break-inside: auto; }
          @page { margin: 14mm; }
          \(style)
        </style></head>
        <body>\(body)</body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension IssueSeverity {
    var cssClass: String {
        switch self {
        case .error: "error"
        case .warning: "warning"
        case .notice: "notice"
        }
    }
}

private func < (lhs: (IssueSeverity, Int), rhs: (IssueSeverity, Int)) -> Bool {
    lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
}
