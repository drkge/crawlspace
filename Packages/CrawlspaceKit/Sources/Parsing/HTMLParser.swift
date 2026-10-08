import CoreFoundation
import CrawlCore
import Foundation
import Kanna

public enum HTMLParser {
    /// Parses an HTML body. `headerCharset` is the charset from the Content-Type header, if any.
    /// `robotsTokens` are extra meta names treated like `robots` (e.g. `googlebot`, `crawlspace`).
    public static func parse(_ data: Data, headerCharset: String?, robotsTokens: [String] = [],
                             extractors: [Extractor] = [], searches: [CustomSearch] = []) -> ParsedPage {
        let html = decode(data, headerCharset: headerCharset)
        guard let doc = try? Kanna.HTML(html: html, encoding: .utf8) else { return ParsedPage() }
        var page = ParsedPage()
        let robotsNames = Set(["robots"] + robotsTokens.map { $0.lowercased() })

        page.lang = doc.at_xpath("/html/@lang")?.text.map(collapse).flatMap(nilIfEmpty)
        page.baseHref = doc.at_xpath("//head/base[@href]")?["href"]

        page.titles = doc.xpath("//title[not(ancestor::svg)]").compactMap { $0.text.map(collapse) }

        for meta in doc.xpath("//meta") {
            let content = meta["content"] ?? ""
            if let name = meta["name"]?.lowercased() {
                if name == "description" {
                    page.metaDescriptions.append(collapse(content))
                } else if robotsNames.contains(name) {
                    page.metaRobots.append(content.lowercased())
                }
            }
            if meta["http-equiv"]?.lowercased() == "refresh", let target = metaRefreshTarget(content) {
                page.metaRefresh = target
                page.links.append(.init(href: target, type: .metaRefresh, text: "", flags: []))
            }
        }

        page.h1 = doc.xpath("//h1").map { collapse($0.text ?? "") }
        page.h2 = doc.xpath("//h2").map { collapse($0.text ?? "") }

        for link in doc.xpath("//link[@rel][@href]") {
            guard let href = link["href"], let rel = link["rel"] else { continue }
            let rels = Set(rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            if rels.contains("canonical") {
                let inHead = link.parent?.tagName?.lowercased() == "head"
                page.canonicals.append(.init(href: href.trimmingCharacters(in: .whitespaces), inHead: inHead))
            }
            if rels.contains("alternate"), let lang = link["hreflang"] {
                page.hreflang.append(.init(lang: lang.trimmingCharacters(in: .whitespaces), href: href))
            }
            if rels.contains("stylesheet") {
                page.links.append(.init(href: href, type: .stylesheet, text: "", flags: []))
            }
        }

        for anchor in doc.xpath("//a[@href] | //area[@href]") {
            guard let href = anchor["href"] else { continue }
            var text = collapse(anchor.text ?? "")
            if text.isEmpty, let alt = anchor.at_xpath(".//img/@alt")?.text {
                text = collapse(alt)
            }
            page.links.append(.init(href: href, type: .anchor, text: text,
                                    flags: relFlags(anchor["rel"]).with(position: position(of: anchor))))
        }

        for image in doc.xpath("//img") {
            guard let src = image["src"], !src.isEmpty else { continue }
            var flags: LinkFlags = []
            let alt = image["alt"]
            if alt == nil { flags.insert(.altAttributeMissing) }
            if image["width"] == nil || image["height"] == nil { flags.insert(.dimensionsMissing) }
            page.links.append(.init(href: src, type: .image, text: collapse(alt ?? ""),
                                    flags: flags.with(position: position(of: image))))
        }

        for script in doc.xpath("//script[@src]") {
            if let src = script["src"] { page.links.append(.init(href: src, type: .script, text: "", flags: [])) }
        }
        for frame in doc.xpath("//iframe[@src]") {
            if let src = frame["src"] { page.links.append(.init(href: src, type: .iframe, text: "", flags: [])) }
        }

        for script in doc.xpath("//script") where script["type"]?.lowercased().trimmingCharacters(in: .whitespaces) == "application/ld+json" {
            page.jsonLD.append(parseJSONLD(script.text ?? ""))
        }

        let textNodes = doc.xpath(
            "//body//text()[not(ancestor::script or ancestor::style or ancestor::noscript or ancestor::template or ancestor::svg)]"
        )
        var text = ""
        for node in textNodes {
            if let value = node.text {
                text += value
                text += " "
            }
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        page.wordCount = words.reduce(0) { count, word in
            word.contains(where: { $0.isLetter || $0.isNumber }) ? count + 1 : count
        }
        let lowercasedWords = words.map { $0.lowercased() }
        page.contentHash = StableHash.fnv1a64(lowercasedWords.joined(separator: " "))
        page.simhash = SimHash.compute(words: lowercasedWords)

        for extractor in extractors where extractor.isValid {
            if let value = run(extractor, document: doc, html: html) {
                page.extractions[extractor.name] = value
            }
        }
        let visibleText = words.joined(separator: " ")
        for search in searches where search.isValid {
            page.searchHits[search.name] = run(search, html: html, visibleText: visibleText)
        }

        return page
    }

    // MARK: - Custom extraction

    static func run(_ extractor: Extractor, document: HTMLDocument, html: String) -> String? {
        var values: [String] = []
        switch extractor.kind {
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: extractor.expression, options: [.dotMatchesLineSeparators]) else { return nil }
            let range = NSRange(html.startIndex..., in: html)
            regex.enumerateMatches(in: html, range: range) { match, _, stop in
                guard let match else { return }
                // Capture group 1 when the pattern has one, otherwise the whole match.
                let group = match.numberOfRanges > 1 ? 1 : 0
                if let matchRange = Range(match.range(at: group), in: html) {
                    values.append(collapse(String(html[matchRange])))
                }
                if !extractor.collectAll { stop.pointee = true }
            }
        case .cssSelector, .xpath:
            let object = extractor.kind == .cssSelector
                ? document.css(extractor.expression)
                : document.xpath(extractor.expression)
            switch object {
            case .NodeSet(let nodes):
                for node in nodes {
                    if let value = value(from: node, output: extractor.output, attribute: extractor.attribute) {
                        values.append(value)
                    }
                    if !extractor.collectAll { break }
                }
            case .String(let text):
                values.append(collapse(text))
            case .Number(let number):
                values.append(number == number.rounded() ? String(Int(number)) : String(number))
            case .Bool(let flag):
                values.append(flag ? "true" : "false")
            case .none:
                break
            }
        }
        let filtered = values.filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return nil }
        return extractor.collectAll ? filtered.joined(separator: " | ") : filtered[0]
    }

    private static func value(from node: Kanna.XMLElement, output: Extractor.Output, attribute: String) -> String? {
        switch output {
        case .text: collapse(node.text ?? "")
        case .innerHTML: node.innerHTML.map(collapse)
        case .outerHTML: node.toHTML.map(collapse)
        case .attribute: node[attribute].map(collapse)
        }
    }

    static func run(_ search: CustomSearch, html: String, visibleText: String) -> Bool {
        let haystack = search.visibleTextOnly ? visibleText : html
        switch search.mode {
        case .contains, .doesNotContain:
            let options: String.CompareOptions = search.caseSensitive ? [] : [.caseInsensitive]
            let found = haystack.range(of: search.term, options: options) != nil
            return search.mode == .contains ? found : !found
        case .matchesRegex, .doesNotMatchRegex:
            let options: NSRegularExpression.Options = search.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: search.term, options: options) else { return false }
            let found = regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
            return search.mode == .matchesRegex ? found : !found
        }
    }

    // MARK: - Helpers

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func nilIfEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// The part of the page an element sits in, judged by its nearest landmark: HTML5 elements or
    /// their ARIA roles. Footer wins over a navigation block inside it, and header likewise,
    /// because "it's in the footer" is what says the fix belongs in the theme.
    static func position(of element: Kanna.XMLElement) -> LinkPosition {
        func inside(_ tag: String, role: String) -> Bool {
            element.at_xpath("ancestor::*[self::\(tag) or @role='\(role)'][1]") != nil
        }
        if inside("footer", role: "contentinfo") { return .footer }
        if inside("header", role: "banner") { return .header }
        if inside("aside", role: "complementary") { return .sidebar }
        if inside("nav", role: "navigation") { return .navigation }
        return .content
    }

    static func relFlags(_ rel: String?) -> LinkFlags {
        guard let rel = rel?.lowercased() else { return [] }
        var flags: LinkFlags = []
        for token in rel.split(whereSeparator: \.isWhitespace) {
            switch token {
            case "nofollow": flags.insert(.nofollow)
            case "ugc": flags.insert(.ugc)
            case "sponsored": flags.insert(.sponsored)
            default: break
            }
        }
        return flags
    }

    /// `0; url=/next` → `/next`
    static func metaRefreshTarget(_ content: String) -> String? {
        guard let range = content.range(of: "url=", options: .caseInsensitive) else { return nil }
        let target = content[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return target.isEmpty ? nil : target
    }

    static func parseJSONLD(_ source: String) -> ParsedPage.JSONLDBlock {
        let data = Data(source.utf8)
        // Foundation's parsers accept trailing commas, which strict JSON (RFC 8259) rejects.
        if let offset = trailingCommaOffset(data) {
            return .init(types: [], error: "Trailing comma at character \(offset) (invalid JSON)")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var types: [String] = []
            collectTypes(object, into: &types)
            return .init(types: types, error: nil, products: ProductExtractor.products(in: object))
        } catch let error as NSError {
            let detail = (error.userInfo[NSDebugDescriptionErrorKey] as? String) ?? error.localizedDescription
            return .init(types: [], error: detail)
        }
    }

    /// Offset of a `,` followed (after whitespace) by `}` or `]`, ignoring string contents.
    static func trailingCommaOffset(_ data: Data) -> Int? {
        var inString = false
        var escaped = false
        var pendingComma: Int?
        for (offset, byte) in data.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true; pendingComma = nil
            case UInt8(ascii: ","): pendingComma = offset
            case UInt8(ascii: "}"), UInt8(ascii: "]"): if let comma = pendingComma { return comma }
            case 0x20, 0x09, 0x0A, 0x0D: break
            default: pendingComma = nil
            }
        }
        return nil
    }

    private static func collectTypes(_ object: Any, into types: inout [String]) {
        if let array = object as? [Any] {
            for item in array { collectTypes(item, into: &types) }
        } else if let dict = object as? [String: Any] {
            if let type = dict["@type"] as? String {
                types.append(type)
            } else if let typeList = dict["@type"] as? [String] {
                types.append(contentsOf: typeList)
            }
            if let graph = dict["@graph"] { collectTypes(graph, into: &types) }
        }
    }

    // MARK: - Character encoding

    /// Header charset, then BOM, then a `<meta charset>` sniff of the first 2 KB, then UTF-8.
    /// Undecodable bytes are replaced rather than failing the whole page.
    static func decode(_ data: Data, headerCharset: String?) -> String {
        let encoding = detectEncoding(data, headerCharset: headerCharset)
        if let text = String(data: data, encoding: encoding) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func detectEncoding(_ data: Data, headerCharset: String?) -> String.Encoding {
        if let charset = headerCharset, let encoding = encoding(forIANAName: charset) { return encoding }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }

        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let range = head.range(of: #"<meta[^>]+charset\s*=\s*["']?\s*([a-z0-9_\-:.]+)"#, options: .regularExpression) {
            let match = head[range]
            if let eq = match.range(of: "charset") {
                let value = match[eq.upperBound...]
                    .drop(while: { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "'" })
                    .prefix(while: { $0.isLetter || $0.isNumber || "-_:.".contains($0) })
                if let encoding = encoding(forIANAName: String(value)) { return encoding }
            }
        }
        return .utf8
    }

    static func encoding(forIANAName name: String) -> String.Encoding? {
        var name = name.trimmingCharacters(in: .whitespaces).lowercased()
        // Browsers treat Latin-1 labels as Windows-1252.
        if name == "iso-8859-1" || name == "latin1" || name == "us-ascii" { name = "windows-1252" }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
