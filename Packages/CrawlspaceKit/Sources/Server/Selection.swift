import Audit
import Foundation
import Storage

/// What the sidebar can select: the dashboard, a table of URLs, or a report. The browser sends it
/// as a short string, such as `filter:internalHTML`, `issue:title_missing` or `extraction:Price`.
enum Selection: Hashable, Sendable {
    case overview
    case filter(URLFilter)
    case issue(String)
    case extraction(String)
    case searchHit(String)

    init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts[0]
        let value = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "overview": self = .overview
        case "issue" where !value.isEmpty: self = .issue(value)
        case "extraction" where !value.isEmpty: self = .extraction(value)
        case "search" where !value.isEmpty: self = .searchHit(value)
        case "filter":
            guard let filter = Self.filters[value] else { return nil }
            self = .filter(filter)
        default: return nil
        }
    }

    /// The fixed tables, by the names the browser uses.
    static let filters: [String: URLFilter] = [
        "all": .all, "internalAll": .internalAll, "internalHTML": .internalHTML, "external": .external,
        "images": .images, "cssAndJavaScript": .cssAndJavaScript, "notCrawled": .notCrawled,
        "redirectChains": .redirectChains, "inSitemap": .inSitemap, "nearDuplicates": .nearDuplicates,
        "noResponse": .noResponse, "2xx": .statusClass(2), "3xx": .statusClass(3), "4xx": .statusClass(4),
        "5xx": .statusClass(5),
    ]

    static func name(of filter: URLFilter) -> String? {
        filters.first { $0.value == filter }?.key
    }

    var urlFilter: URLFilter? {
        switch self {
        case .overview: nil
        case .filter(let filter): filter
        case .issue(let code): .issue(code)
        case .extraction(let name): .extraction(name)
        case .searchHit(let name): .searchHit(name)
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .filter(let filter): filter.title
        case .issue(let code): IssueCatalogue.definition(for: code).map { "\($0.category.rawValue): \($0.title)" } ?? code
        case .extraction(let name), .searchHit(let name): name
        }
    }

    /// Columns for this selection. Once Lighthouse has run, the page tables show its scores too.
    func columns(hasLighthouse: Bool) -> [URLTableColumn] {
        switch self {
        case .overview:
            return []
        case .filter(let filter):
            var columns = filter.defaultColumns.asTableColumns
            if hasLighthouse, filter == .internalHTML || filter == .all {
                columns += [.standard(.lhMobileScore), .standard(.lhDesktopScore)]
            }
            return columns
        case .issue(let code):
            return (IssueCatalogue.definition(for: code)?.tableColumns ?? URLFilter.internalHTML.defaultColumns).asTableColumns
        case .extraction(let name):
            return [.standard(.address), .extraction(name), .standard(.statusCode), .standard(.indexability), .standard(.title)]
        case .searchHit:
            return URLFilter.searchHit("").defaultColumns.asTableColumns
        }
    }
}

extension URLFilter {
    var title: String {
        switch self {
        case .all: "All URLs"
        case .internalAll: "Internal"
        case .internalHTML: "Internal HTML"
        case .external: "External"
        case .images: "Images"
        case .cssAndJavaScript: "CSS & JavaScript"
        case .notCrawled: "Not Crawled"
        case .statusClass(let code): "\(code)xx Responses"
        case .noResponse: "No Response"
        case .issue(let code): code
        case .redirectChains: "Redirect Chains"
        case .inSitemap: "In XML Sitemap"
        case .extraction(let name): name
        case .searchHit(let name): name
        case .nearDuplicates: "Near Duplicates"
        }
    }
}

extension URLTableColumn {
    /// Parses the `id` this column was sent to the browser with.
    init?(id: String) {
        if id.hasPrefix("standard:"), let column = URLColumn(rawValue: String(id.dropFirst(9))) {
            self = .standard(column)
        } else if id.hasPrefix("extraction:"), id.count > 11 {
            self = .extraction(String(id.dropFirst(11)))
        } else {
            return nil
        }
    }
}
