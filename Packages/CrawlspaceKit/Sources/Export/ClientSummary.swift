import Audit
import CrawlCore
import Foundation
import Storage

/// A short summary for a client: what is wrong with the site, in plain words, and what to do first.
///
/// The audit report counts URLs, so a broken link in the footer reads as 3,000 errors; the fixes
/// count changes to make, which on a shop of 10,000 products is still 10,000 of something. A client
/// wants the kinds of problem — *4,922 images are larger than they need to be* — with how many pages
/// each touches and whether one change clears it. No URL lists, no crawl settings, no jargon. Every
/// kind of problem is named, in a sentence: a client can't act on "and three more".
public enum ClientSummaryBuilder {
    /// How many problems "Start here" leads with. Every one is named under its area too.
    static let priorities = 5

    public static func html(store: CrawlStore, baseline: CrawlStore? = nil,
                            options: ReportOptions = ReportOptions(title: "Website Summary")) throws -> String {
        let config = try store.loadConfig()
        let overview = try store.overview()
        let started = try store.meta("started_at").flatMap { ISO8601DateFormatter().date(from: $0) }
        let site = CrawlScope(config: config).startHost
        // The pages' problems; speed and the sitemap are summed up apart, after them.
        let all = try kinds(store: store)
        let problems = all.filter { !$0.group.isApart }

        var body = ReportBuilder.header(options: options, config: config, started: started)
        body += headline(problems, pages: overview.internalHTML, site: site)
        if let baseline {
            body += try progress(problems, baseline: baseline, store: store, config: config)
        }
        if !problems.isEmpty {
            body += topPriorities(problems)
            body += areas(problems)
        }
        body += working(problems)
        body += apart(all.filter { $0.group.isApart })
        body += nextSteps(problems, options: options)
        body += try allIssues(store: store)
        return ReportBuilder.document(title: options.title, accent: options.accent, body: body, style: style)
    }

    /// Every issue the crawl found, as the app lists them, in a table after the summary: for
    /// whoever does the work, and anyone who wants the whole picture. Speed and the sitemap get
    /// tables of their own, as the app keeps them apart.
    private static func allIssues(store: CrawlStore) throws -> String {
        let counts = try store.issueCounts()
        let issues = IssueCatalogue.all
            .compactMap { definition in counts[definition.code].flatMap { $0 > 0 ? (definition, $0) : nil } }
            .sorted { ($0.0.severity, -$0.1, $0.0.title) < ($1.0.severity, -$1.1, $1.0.title) }
        var html = ""
        for (title, chosen) in [
            ("Every issue found", issues.filter { !$0.0.group.isApart }),
            ("Speed (Lighthouse)", issues.filter { $0.0.group == .lighthouse }),
            ("Sitemap", issues.filter { $0.0.group == .sitemap }),
        ] where !chosen.isEmpty {
            let rows = chosen.map { definition, count in
                """
                <tr class="\(definition.severity.cssClass)"><td>\(ReportBuilder.escape("\(definition.category.rawValue): \(definition.title)"))</td>\
                <td>\(label(definition.severity))</td><td class="num">\(count.formatted())</td></tr>
                """
            }.joined()
            html += """
            <section class="all-issues"><h2>\(title)</h2>
            <table><thead><tr><th>Issue</th><th>Priority</th><th class="num">Pages</th></tr></thead><tbody>\(rows)</tbody></table>
            </section>
            """
        }
        return html
    }

    // MARK: - The client

    /// Who the site belongs to, from the crawl: the name the home page's title gives the site —
    /// "Rosy Roo" from "Rosy Roo – Rosyroo" on rosyroo.co.uk — or nil when it doesn't spell it.
    public static func clientName(store: CrawlStore) throws -> String? {
        let config = try store.loadConfig()
        let host = CrawlScope(config: config).startHost
        let title: String? = try store.pool.read { db in
            // The start page, or where it redirected.
            try String.fetchOne(db, sql: """
                SELECT COALESCE(u.title, t.title) FROM urls u LEFT JOIN urls t ON t.id = u.redirect_to_id
                WHERE u.depth = 0 ORDER BY u.id LIMIT 1
                """)
        }
        return title.flatMap { siteName(title: $0, host: host) }
    }

    /// The words of a page title that spell the site's domain: "Chimney Sheep" from "Chimney Sheep®
    /// draught excluders…" on chimneysheep.co.uk, "Jolly Good Yarn" from "Jolly Good Yarn: Eco-Friendly…".
    static func siteName(title: String, host: String) -> String? {
        func letters(_ text: some StringProtocol) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let label = host.lowercased().replacing(/^www\./, with: "").split(separator: ".").first.map(letters) ?? ""
        guard !label.isEmpty else { return nil }
        let segments = title.components(separatedBy: CharacterSet(charactersIn: "|–—:·•")).flatMap { $0.components(separatedBy: " - ") }
        for segment in segments {
            var taken: [Substring] = []
            for word in segment.split(separator: " ") {
                taken.append(word)
                let spelled = letters(taken.joined())
                if spelled == label {
                    return taken.joined(separator: " ").filter { !"®™©".contains($0) }.trimmingCharacters(in: .punctuationCharacters)
                }
                if !label.hasPrefix(spelled) { break }
            }
        }
        return nil
    }

    // MARK: - Kinds of problem

    /// One kind of problem: an issue, with the things it covers (addresses, images, groups of
    /// pages, or pages) and every page it touches.
    struct Kind {
        var code: String
        var severity: IssueSeverity
        var area: Area
        /// Errors, warnings or notices by severity, or Lighthouse or Sitemap, kept apart.
        var group: IssueGroup {
            IssueCatalogue.definition(for: code)?.group ?? IssueGroup(severity)
        }
        /// Separate fixes: an address, an image, a group of pages, a link in the theme, or a page.
        var items = 0
        var pages: Set<Int64> = []
        /// True when every fix is made once for the whole site: a setting, a template, a theme link.
        var siteWide = true
    }

    /// The product card linking through collection addresses, which stands for several issues.
    static let productCards = "product_cards"

    /// The kind of problem an issue counts as: a pair measured two ways under the worse of the
    /// two, and the issue on pages linking to a broken URL under the URL's own.
    public static func kindCode(for code: String) -> String {
        if let pair = FixBuilder.pair(of: code) { return pair.primary }
        if let target = FixBuilder.targetCodes.first(where: { $0.value == code })?.key { return target }
        return code
    }

    /// The kind of problem a fix counts as, by its worst issue.
    public static func kindCode(of unit: Fix) -> String {
        if case .productCards = unit.kind { return productCards }
        let own = unit.codes.filter { !FixBuilder.linkSourceCodes.contains($0) }
        return kindCode(for: own.first ?? unit.codes.first ?? "")
    }

    /// The crawl's problems by kind, worst first. The issue on pages linking to a broken URL is
    /// the same problem as the URL itself, so it is counted there.
    static func kinds(store: CrawlStore) throws -> [Kind] {
        let units = try FixBuilder.units(store: store, severities: Set(IssueSeverity.allCases))
        var byCode: [String: Kind] = [:]
        for unit in units {
            if case .productCards = unit.kind {
                byCode[productCards] = Kind(code: productCards, severity: unit.severity, area: .links,
                                            items: unit.counts["addresses"] ?? 0, pages: Set(unit.pages), siteWide: true)
                continue
            }
            let siteWide = switch unit.kind {
            case .setting, .link, .template: true
            default: false
            }
            // A pair measured two ways is one problem, counted under the worse of the two.
            let codes = Set(unit.codes.map { FixBuilder.pair(of: $0)?.primary ?? $0 })
            for code in codes where !FixBuilder.linkSourceCodes.contains(code) {
                guard let definition = IssueCatalogue.definition(for: code) else { continue }
                var kind = byCode[code] ?? Kind(code: code, severity: severity(of: definition),
                                                area: area(of: definition, in: unit.group))
                // A pattern stands for each of its addresses.
                if case .pattern = unit.kind { kind.items += unit.counts["addresses"] ?? 1 } else { kind.items += 1 }
                kind.pages.formUnion(unit.pages)
                kind.siteWide = kind.siteWide && siteWide
                byCode[code] = kind
            }
        }
        return ranked(Array(byCode.values))
    }

    /// Where a problem belongs: speed and product data by what they are, wherever they were filed,
    /// so a Shopify product's long title reads as a page problem, not a product-data one.
    private static func area(of definition: IssueDefinition, in group: FixGroup) -> Area {
        if definition.category == .speed { return .speed }
        if definition.category == .ecommerce { return .products }
        let area = Area.of(group)
        return area == .products ? .pages : area
    }

    /// An issue's severity, or that of the links to it when those are worse: a broken page is as
    /// urgent as the links sending people there.
    private static func severity(of definition: IssueDefinition) -> IssueSeverity {
        guard let paired = FixBuilder.targetCodes[definition.code] ?? nil,
              let links = IssueCatalogue.definition(for: paired) else { return definition.severity }
        return min(definition.severity, links.severity)
    }

    static func ranked(_ kinds: [Kind]) -> [Kind] {
        kinds.sorted { a, b in
            if a.severity != b.severity { return a.severity < b.severity }
            if a.pages.count != b.pages.count { return a.pages.count > b.pages.count }
            return a.code < b.code
        }
    }

    // MARK: - Sections

    private static func headline(_ problems: [Kind], pages: Int, site: String) -> String {
        func count(_ severity: IssueSeverity) -> Int { problems.filter { $0.severity == severity }.count }
        let lead: String
        if problems.isEmpty {
            lead = "We checked \(pages.formatted()) pages on \(site) and found nothing that needs fixing."
        } else {
            let touched = Set(problems.flatMap(\.pages)).count
            lead = "We checked \(pages.formatted()) pages on \(site) and found **\(problems.count) "
                + "\(problems.count == 1 ? "kind" : "kinds") of problem**, between them touching "
                + "\(touched.formatted()) \(touched == 1 ? "page" : "pages"). Many come from the site's shared design or "
                + "settings, where one change fixes every page at once."
        }
        let tiles = [
            ("Fix now", count(.error), "broken for visitors or search engines", "error"),
            ("Fix soon", count(.warning), "holding the site back", "warning"),
            ("When you can", count(.notice), "smaller improvements", "notice"),
        ].map { title, value, detail, kind in
            """
            <div class="tile \(kind)"><div class="tile-title">\(title)</div>
            <div class="tile-value">\(value.formatted())</div>
            <div class="tile-detail">\(detail)</div></div>
            """
        }.joined()
        return "<section><p class=\"lead\">\(inline(lead))</p><div class=\"tiles\">\(tiles)</div></section>"
    }

    /// What changed since an earlier crawl: problems gone, problems new, and how many pages are
    /// affected now against then.
    private static func progress(_ problems: [Kind], baseline: CrawlStore, store: CrawlStore,
                                 config: CrawlConfig) throws -> String {
        let before = try kinds(store: baseline).filter { !$0.group.isApart }
        let now = Set(problems.map(\.code))
        let then = Set(before.map(\.code))
        let fixed = before.filter { !now.contains($0.code) }
        let new = problems.filter { !then.contains($0.code) }
        let pagesThen = Set(before.flatMap(\.pages)).count
        let pagesNow = Set(problems.flatMap(\.pages)).count
        let date = (try baseline.meta("started_at").flatMap { ISO8601DateFormatter().date(from: $0) })
            .map { $0.formatted(date: .long, time: .omitted) } ?? "the last check"

        var html = "<section><h2>Since \(ReportBuilder.escape(date))</h2><div class=\"tiles\">"
        let tiles: [(String, String, String)] = [
            ("Fixed", fixed.count.formatted(), "fixed"), ("New", new.count.formatted(), "error"),
            ("Pages affected", "\(pagesThen.formatted()) → \(pagesNow.formatted())", pagesNow <= pagesThen ? "fixed" : "error"),
        ]
        for (title, value, kind) in tiles {
            html += "<div class=\"tile \(kind)\"><div class=\"tile-title\">\(title)</div><div class=\"tile-value\">\(value)</div></div>"
        }
        html += "</div>"
        for (title, list) in [("Fixed since then", fixed), ("New since then", new)] where !list.isEmpty {
            html += "<h3>\(title)</h3><ul class=\"plain\">"
                + list.map { "<li>\(ReportBuilder.escape(sentence($0)))</li>" }.joined()
                + "</ul>"
        }
        let whole = try store.status() == .completed && store.crawledCount() < config.maxURLs
        if !whole {
            html += "<p class=\"muted\">This check didn't reach every page, so some of what was found before may not have been looked at again.</p>"
        }
        return html + "</section>"
    }

    private static func topPriorities(_ problems: [Kind]) -> String {
        var html = "<section><h2>Start here</h2><p class=\"muted\">The problems that matter most, worst first.</p>"
        for (index, kind) in problems.prefix(priorities).enumerated() {
            var facts = [label(kind.severity), "\(kind.pages.count.formatted()) \(kind.pages.count == 1 ? "page" : "pages") affected"]
            if kind.siteWide { facts.append("one change fixes it everywhere") }
            html += """
            <div class="issue \(kind.severity.cssClass)">
              <div class="issue-head"><span class="number">\(index + 1)</span>
              <strong>\(ReportBuilder.escape(sentence(kind)))</strong></div>
              <p>\(ReportBuilder.escape(kind.area.why))</p>
              <p class="facts">\(ReportBuilder.escape(facts.joined(separator: " · ")))</p>
            </div>
            """
        }
        return html + "</section>"
    }

    private static func areas(_ problems: [Kind]) -> String {
        var html = "<section><h2>By area</h2>"
        for area in Area.allCases {
            let group = problems.filter { $0.area == area }
            guard !group.isEmpty else { continue }
            let pages = Set(group.flatMap(\.pages)).count
            let named = group.map { "<li>\(ReportBuilder.escape(sentence($0)))</li>" }.joined()
            html += """
            <div class="issue area">
              <div class="issue-head"><strong>\(area.label)</strong>
              <span class="muted">\(group.count) \(group.count == 1 ? "problem" : "problems") · \(pages.formatted()) \(pages == 1 ? "page" : "pages") affected</span></div>
              <p>\(ReportBuilder.escape(area.why))</p>
              <ul class="plain">\(named)</ul>
            </div>
            """
        }
        return html + "</section>"
    }

    private static func working(_ problems: [Kind]) -> String {
        // Speed has its own section, with the sitemap: it isn't one of the pages' areas.
        let clear = Area.allCases.filter { area in area != .speed && !problems.contains { $0.area == area } }
        guard !clear.isEmpty else { return "" }
        let items = clear.map { "<li><strong>\($0.label):</strong> \(ReportBuilder.escape($0.good))</li>" }.joined()
        return "<section><h2>What's working</h2><ul class=\"plain good\">\(items)</ul></section>"
    }

    /// Speed and the sitemap, kept apart from the pages' problems: Lighthouse measures a sample of
    /// pages, and the sitemap is a file of its own, so neither counts towards the pages' totals.
    private static func apart(_ kinds: [Kind]) -> String {
        guard !kinds.isEmpty else { return "" }
        var html = "<section><h2>Speed and sitemap</h2>"
        for (title, why, group) in [
            ("Speed", Area.speed.why + " Measured by Lighthouse on a sample of pages.", IssueGroup.lighthouse),
            ("Sitemap", "The XML sitemap tells search engines which pages to index: it should list every page that matters, and nothing else.", .sitemap),
        ] {
            let chosen = kinds.filter { $0.group == group }
            guard !chosen.isEmpty else { continue }
            let pages = Set(chosen.flatMap(\.pages)).count
            html += """
            <div class="issue area">
              <div class="issue-head"><strong>\(title)</strong>
              <span class="muted">\(chosen.count) \(chosen.count == 1 ? "problem" : "problems") · \(pages.formatted()) \(pages == 1 ? "page" : "pages")</span></div>
              <p>\(ReportBuilder.escape(why))</p>
              <ul class="plain">\(chosen.map { "<li>\(ReportBuilder.escape(sentence($0)))</li>" }.joined())</ul>
            </div>
            """
        }
        return html + "</section>"
    }

    private static func nextSteps(_ problems: [Kind], options: ReportOptions) -> String {
        guard !problems.isEmpty else { return "" }
        let who = options.preparedBy.isEmpty ? "We" : ReportBuilder.escape(options.preparedBy)
        var text = "Start with the problems marked <em>Fix now</em>. "
        if problems.contains(where: \.siteWide) {
            text += "Those marked <em>one change fixes it everywhere</em> are quick wins: a single change to the site's design or settings clears them from every page. "
        }
        text += "\(who) can take you through any of these, and a fresh check once the work is done shows what has been fixed."
        return "<section><h2>Next steps</h2><p>\(text)</p></section>"
    }

    // MARK: - Words

    private static func label(_ severity: IssueSeverity) -> String {
        switch severity {
        case .error: "Fix now"
        case .warning: "Fix soon"
        case .notice: "When you can"
        }
    }

    /// A kind of problem, said plainly with its numbers.
    static func sentence(_ kind: Kind) -> String {
        let n = kind.items.formatted()
        let p = kind.pages.count.formatted()
        let pages = kind.pages.count == 1 ? "1 page" : "\(p) pages"
        let one = kind.items == 1
        let link = kind.pages.count == 1 ? "links" : "link"
        switch kind.code {
        case productCards:
            return kind.items > 0
                ? "Product cards on \(pages) link through collection addresses, sending visitors through \(n) \(one ? "redirect" : "redirects")"
                : "Product cards on \(pages) link to products through a collection's address rather than their own"
        case "response_internal_4xx", "response_internal_5xx", "response_internal_no_response":
            let what = one ? "1 address on the site no longer works" : "\(n) addresses on the site no longer work"
            return kind.pages.isEmpty ? what : "\(what), and \(pages) \(link) to \(one ? "it" : "them")"
        case "response_external_broken":
            return "\(pages) \(link) to \(one ? "a page" : "\(n) pages") on other sites that no longer \(one ? "works" : "work")"
        case "response_external_unverified":
            return "\(one ? "1 link" : "\(n) links") to other sites couldn't be checked automatically"
        case "response_internal_3xx":
            return "\(pages) \(link) to \(one ? "an address that redirects" : "\(n) addresses that redirect") elsewhere"
        case "redirect_chain":
            return "\(one ? "1 redirect passes" : "\(n) redirects pass") through several steps before arriving"
        case "redirect_loop":
            return "\(one ? "1 redirect goes" : "\(n) redirects go") round in a circle and never load"
        case "links_non_descriptive_anchor":
            return "Links on \(pages) say “click here” or “read more” rather than where they go"
        case "links_internal_nofollow":
            return "Links on \(pages) tell search engines not to follow them"
        case "title_duplicate", "meta_description_duplicate", "h1_duplicate":
            let what = ["title_duplicate": "page title", "meta_description_duplicate": "search description", "h1_duplicate": "main heading"][kind.code]!
            return one ? "\(pages) share the same \(what)" : "\(n) groups of pages share the same \(what), \(p) pages in all"
        case "content_exact_duplicate":
            return one ? "\(pages) have exactly the same content" : "\(n) groups of pages have exactly the same content, \(p) pages in all"
        case "content_near_duplicate":
            return one ? "\(pages) have very similar content" : "\(n) groups of pages have very similar content, \(p) pages in all"
        default:
            break
        }
        if let image = imageProblems[kind.code] {
            return "\(one ? "1 image" : "\(n) images") \(one ? image.0 : image.1), shown on \(pages)"
        }
        if let setting = settings[kind.code] { return setting }
        if let phrase = pageProblems[kind.code] {
            if kind.code.hasPrefix("lh_") { return "\(pages) measured \(kind.pages.count == 1 ? singular(phrase) : phrase)" }
            let noun = kind.area == .products && kind.code.hasPrefix("ecom_product") ? (one ? "1 product" : "\(p) products") : pages
            return "\(noun) \(one ? phrase : plural(phrase))"
        }
        let title = IssueCatalogue.definition(for: kind.code).map { "\($0.category.rawValue): \($0.title)" } ?? kind.code
        return "\(title), on \(pages)"
    }

    /// "has no page title" → "have no page title": the first verb, for more than one page.
    static func plural(_ phrase: String) -> String {
        var words = phrase.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !words.isEmpty else { return phrase }
        let index = words[0] == "only" && words.count > 1 ? 1 : 0
        let verb = words[index]
        words[index] = switch verb {
        case "has": "have"
        case "is": "are"
        case "isn't": "aren't"
        case "doesn't": "don't"
        case "didn't", "can": verb
        default: verb.hasSuffix("s") ? String(verb.dropLast()) : verb
        }
        return words.joined(separator: " ").replacingOccurrences(of: " its ", with: " their ")
    }

    /// "take a long time" → "takes a long time": the speed phrases are written for several pages.
    static func singular(_ phrase: String) -> String {
        var words = phrase.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let verb = words.first else { return phrase }
        words[0] = switch verb {
        case "are": "is"
        case "could", "can": verb
        default: verb + "s"
        }
        return words.joined(separator: " ").replacingOccurrences(of: " their ", with: " its ")
    }

    enum Area: CaseIterable {
        case links, images, settings, duplicates, speed, products, pages

        static func of(_ group: FixGroup) -> Area {
            switch group {
            case .links: .links
            case .images: .images
            case .siteSettings: .settings
            case .duplicates: .duplicates
            case .speed: .speed
            case .products: .products
            case .errors, .warnings, .notices, .collections, .storePages, .blog, .otherPages: .pages
            }
        }

        var label: String {
            switch self {
            case .links: "Links"
            case .images: "Images"
            case .settings: "Site settings"
            case .duplicates: "Duplicate pages"
            case .speed: "Speed"
            case .products: "Products"
            case .pages: "Individual pages"
            }
        }

        var why: String {
            switch self {
            case .links: "Broken links and redirects send visitors and search engines to dead ends or the long way round."
            case .images: "Image descriptions are read aloud to people using screen readers and help images appear in search; large images slow pages down."
            case .settings: "Settings for the whole site, usually changed once by your developer or hosting provider."
            case .duplicates: "Pages that look the same to search engines compete with each other, and neither ranks as well as one would."
            case .speed: "Slow pages lose visitors, and Google takes speed into account when ranking."
            case .products: "Complete product details let Google show price, stock and reviews beside your products."
            case .pages: "Problems particular to a page, such as a missing title or description, which shape how it appears in Google."
            }
        }

        var good: String {
            switch self {
            case .links: "no broken links or unnecessary redirects."
            case .images: "images are described and sized well."
            case .settings: "security headers are in order."
            case .duplicates: "every page has its own title, description and content."
            case .speed: "no speed problems in the pages measured."
            case .products: "product details are complete."
            case .pages: "no problems particular to individual pages."
            }
        }
    }

    /// One image, and several.
    private static let imageProblems: [String: (String, String)] = [
        "images_missing_alt_attribute": ("has no description for screen readers and search engines",
                                         "have no description for screen readers and search engines"),
        "images_missing_alt_text": ("has an empty description", "have empty descriptions"),
        "images_alt_over_100_characters": ("has an overly long description", "have overly long descriptions"),
        "images_missing_dimensions": ("has no size set, so pages shift as they load", "have no size set, so pages shift as they load"),
        "images_over_100kb": ("is a larger file than it needs to be", "are larger files than they need to be"),
    ]

    private static let settings: [String: String] = [
        "security_missing_hsts": "The site doesn't tell browsers to always use a secure connection",
        "security_missing_nosniff": "A security setting that stops browsers guessing file types is missing",
        "security_missing_csp": "There's no content security policy limiting what the site can load",
        "security_mixed_content": "Some secure pages load files over an insecure connection",
        "url_http_on_https_site": "Some pages are still reached over an insecure (http) address",
        "sitemap_missing": "There's no sitemap telling search engines which pages exist",
        "sitemap_non_200": "The sitemap lists pages that don't work",
        "sitemap_non_indexable": "The sitemap lists pages that are hidden from search",
        "sitemap_orphan": "Some pages are in the sitemap but not linked from anywhere on the site",
        "response_internal_blocked_robots": "Some pages are blocked from search engines by the robots.txt file",
    ]

    /// What's wrong with one page, as "/about has no page title" would say it.
    private static let pageProblems: [String: String] = [
        "response_slow": "responds slowly",
        "response_meta_refresh": "uses an old-style redirect",
        "links_no_internal_outlinks": "has no links to the rest of the site",
        "links_high_crawl_depth": "is many clicks from the home page",
        "url_uppercase": "has capital letters in its address",
        "url_underscores": "has underscores in its address",
        "url_over_115_characters": "has a very long address",
        "title_missing": "has no page title",
        "title_multiple": "has more than one page title",
        "title_over_60_characters": "has a page title too long for Google to show in full",
        "title_over_561_pixels": "has a page title too long for Google to show in full",
        "title_below_30_characters": "has a very short page title",
        "title_same_as_h1": "repeats its heading as its page title",
        "meta_description_missing": "has no search description",
        "meta_description_multiple": "has more than one search description",
        "meta_description_over_155_characters": "has a search description too long for Google to show in full",
        "meta_description_over_985_pixels": "has a search description too long for Google to show in full",
        "meta_description_below_70_characters": "has a very short search description",
        "h1_missing": "has no main heading",
        "h1_multiple": "has more than one main heading",
        "h1_over_70_characters": "has a very long main heading",
        "h2_missing": "has no subheadings",
        "content_low_word_count": "has very little text",
        "canonical_missing": "doesn't say which address is its main one",
        "canonical_canonicalised": "points search engines to another page as its main version",
        "canonical_multiple_conflicting": "gives search engines conflicting main addresses",
        "canonical_relative": "has its main-address tag set up incorrectly",
        "canonical_outside_head": "has its main-address tag in the wrong place",
        "canonical_target_non_200": "points search engines to a main version that doesn't work",
        "canonical_target_non_indexable": "points search engines to a main version that's hidden from search",
        "directives_noindex": "is hidden from search engines",
        // The summary counts a page with both noindex and nofollow under noindex.
        "directives_nofollow": "tells search engines not to follow its links",
        "hreflang_invalid_code": "has language settings that need correcting",
        "hreflang_missing_self_reference": "has language settings that need correcting",
        "hreflang_missing_x_default": "has language settings that need correcting",
        "hreflang_missing_return_links": "has language settings that need correcting",
        "hreflang_non_200_target": "points to a language version that doesn't work",
        "javascript_render_failed": "didn't load properly when tested",
        "javascript_content_only_rendered": "only shows its text once scripts have run",
        "javascript_links_only_rendered": "only shows its links once scripts have run",
        "javascript_title_changed": "has its title changed by scripts",
        "javascript_meta_description_changed": "has its search description changed by scripts",
        "javascript_canonical_changed": "has its main address changed by scripts",
        "structured_data_parse_error": "has broken structured data",
        "lh_low_score": "score poorly for speed",
        "lh_needs_improvement": "could be faster",
        "lh_poor_lcp": "take a long time to show their main content",
        "lh_poor_cls": "move about as they load",
        "lh_high_tbt": "are slow to respond to taps and clicks",
        "ecom_product_schema_missing": "has no product details for Google",
        "ecom_product_no_price": "has no price in its product details",
        "ecom_product_no_availability": "doesn't say whether it's in stock",
        "ecom_product_no_image": "has no image in its product details",
        "ecom_product_no_identifier": "has no barcode in its product details",
        "ecom_product_duplicate_path": "can be reached at a second address",
        "ecom_links_to_duplicate_product": "links to products at their second address",
        "ecom_product_orphan": "isn't linked from anywhere on the site",
        "ecom_product_no_collection": "isn't in any collection",
    ]

    /// **Bold** to <strong>, everything else escaped.
    private static func inline(_ text: String) -> String {
        ReportBuilder.escape(text).replacing(/\*\*(.+?)\*\*/) { "<strong>\($0.1)</strong>" }
    }

    private static let style = """
      .lead { font-size: 15px; margin: 0 0 14px; }
      .tile.error .tile-value { color: #A3281E; } .tile.warning .tile-value { color: #8A5200; }
      .tile.notice .tile-value { color: #46506B; } .tile.fixed .tile-value { color: #1E7F4F; }
      .issue.error { border-left-color: #C0362C; } .issue.warning { border-left-color: #D98A1B; }
      .issue.notice { border-left-color: #8792A8; } .issue.area { border-left-color: var(--accent); }
      .issue-head .muted { margin-left: auto; font-size: 12px; }
      .number { display: inline-block; min-width: 20px; height: 20px; border-radius: 10px; background: var(--accent);
                color: #fff; text-align: center; font-weight: 600; font-size: 12px; line-height: 20px; }
      .facts { color: var(--muted); font-size: 12px; }
      ul.plain { margin: 6px 0 0; padding-left: 18px; }
      ul.plain li { margin: 2px 0; }
      ul.good li::marker { color: #1E7F4F; }
      .all-issues { page-break-before: always; }
      .all-issues table { border-collapse: collapse; width: 100%; font-size: 12px; }
      .all-issues th, .all-issues td { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--line); }
      .all-issues thead { display: table-header-group; }
      .all-issues tr { page-break-inside: avoid; }
      .all-issues .num { text-align: right; font-variant-numeric: tabular-nums; }
      .all-issues tr.error td:first-child { border-left: 3px solid #C0362C; }
      .all-issues tr.warning td:first-child { border-left: 3px solid #D98A1B; }
      .all-issues tr.notice td:first-child { border-left: 3px solid #8792A8; }
    """
}
