import Foundation

/// A column in a URL table: either one of the built-in fields, or a custom extractor's value.
public enum URLTableColumn: Sendable, Hashable, Identifiable, Codable {
    case standard(URLColumn)
    case extraction(String)

    public var id: String {
        switch self {
        case .standard(let column): "standard:\(column.rawValue)"
        case .extraction(let name): "extraction:\(name)"
        }
    }

    public var title: String {
        switch self {
        case .standard(let column): column.title
        case .extraction(let name): name
        }
    }

    public var defaultWidth: Double {
        switch self {
        case .standard(let column): column.defaultWidth
        case .extraction: 200
        }
    }

    public var kind: URLColumn.Kind {
        switch self {
        case .standard(let column): column.kind
        case .extraction: .text
        }
    }

    /// Extraction columns live in another table, so they can't be sorted by SQL here.
    public var sortableColumn: URLColumn? {
        switch self {
        case .standard(let column): column
        case .extraction: nil
        }
    }

    public func value(for row: URLRow, extractions: [String: String]) -> URLColumn.Value {
        switch self {
        case .standard(let column): column.value(for: row)
        case .extraction(let name): extractions[name].map(URLColumn.Value.text) ?? .empty
        }
    }
}

extension [URLColumn] {
    public var asTableColumns: [URLTableColumn] { map(URLTableColumn.standard) }
}
