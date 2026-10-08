import Foundation

/// How a link was expressed in the source document. Stored as an integer in `links.type`.
public enum LinkType: Int, Codable, Sendable, CaseIterable {
    case anchor = 0
    case image = 1
    case stylesheet = 2
    case script = 3
    case canonical = 4
    case hreflang = 5
    case redirect = 6
    case iframe = 7
    case metaRefresh = 8

    public var label: String {
        switch self {
        case .anchor: "Hyperlink"
        case .image: "Image"
        case .stylesheet: "CSS"
        case .script: "JavaScript"
        case .canonical: "Canonical"
        case .hreflang: "Hreflang"
        case .redirect: "Redirect"
        case .iframe: "Iframe"
        case .metaRefresh: "Meta refresh"
        }
    }

    /// Resource type implied by the link, before the response's content type is known.
    public var impliedResourceType: ResourceType {
        switch self {
        case .image: .image
        case .stylesheet: .css
        case .script: .javascript
        default: .page
        }
    }
}

/// Attributes of a single link occurrence, packed into `links.flags`.
public struct LinkFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let nofollow = LinkFlags(rawValue: 1 << 0)
    public static let ugc = LinkFlags(rawValue: 1 << 1)
    public static let sponsored = LinkFlags(rawValue: 1 << 2)
    /// `<img>` without an `alt` attribute at all.
    public static let altAttributeMissing = LinkFlags(rawValue: 1 << 3)
    /// `<img>` without both `width` and `height` attributes.
    public static let dimensionsMissing = LinkFlags(rawValue: 1 << 4)

    // Where on the page the link sits, packed into three spare bits so it needs no column of its
    // own. Crawls saved before it existed read as `.unknown`.
    private static let positionShift = 8
    private static let positionMask = 0b111 << positionShift

    public var position: LinkPosition {
        LinkPosition(rawValue: (rawValue & Self.positionMask) >> Self.positionShift) ?? .unknown
    }

    public func with(position: LinkPosition) -> LinkFlags {
        LinkFlags(rawValue: (rawValue & ~Self.positionMask) | (position.rawValue << Self.positionShift))
    }
}

/// The part of the page a link is in. A broken link in the footer is one fix in the theme that
/// clears it from every page; the same link in an article is one fix on that page.
public enum LinkPosition: Int, Sendable, CaseIterable, Codable {
    case unknown = 0
    case navigation = 1
    case header = 2
    case footer = 3
    case sidebar = 4
    case content = 5

    public var label: String {
        switch self {
        case .unknown: "Unknown"
        case .navigation: "Navigation"
        case .header: "Header"
        case .footer: "Footer"
        case .sidebar: "Sidebar"
        case .content: "Content"
        }
    }

    /// Parts of the page every page shares, where one change in the theme fixes them all.
    public var isTemplate: Bool { [.navigation, .header, .footer, .sidebar].contains(self) }
}

public enum ResourceType: Int, Codable, Sendable, CaseIterable {
    /// An HTML page, or a URL not yet fetched that was linked like a page.
    case page = 0
    case image = 1
    case css = 2
    case javascript = 3
    case pdf = 4
    case other = 5

    public var label: String {
        switch self {
        case .page: "HTML"
        case .image: "Image"
        case .css: "CSS"
        case .javascript: "JavaScript"
        case .pdf: "PDF"
        case .other: "Other"
        }
    }

    public static func from(contentType: String?) -> ResourceType? {
        guard let type = contentType?.lowercased() else { return nil }
        if type == "text/html" || type == "application/xhtml+xml" { return .page }
        if type.hasPrefix("image/") { return .image }
        if type == "text/css" { return .css }
        if type.contains("javascript") || type == "application/ecmascript" { return .javascript }
        if type == "application/pdf" { return .pdf }
        return .other
    }
}

public enum URLState: Int, Codable, Sendable {
    case queued = 0
    case crawled = 1
    /// Discovered but deliberately not fetched (see `skip_reason`).
    case skipped = 2
}

public enum FoundVia: Int, Codable, Sendable {
    case seed = 0
    case link = 1
    case list = 2
    case sitemap = 3
}

public enum Indexability: Int, Codable, Sendable {
    case unknown = 0
    case indexable = 1
    case nonIndexable = 2

    public var label: String {
        switch self {
        case .unknown: ""
        case .indexable: "Indexable"
        case .nonIndexable: "Non-Indexable"
        }
    }
}
