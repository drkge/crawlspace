import Compression
import Foundation

/// A parsed XML sitemap or sitemap index.
public struct Sitemap: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case index
        case urlSet
        case text
    }

    public struct Entry: Sendable, Hashable {
        public var loc: String
        public var lastModified: String?
    }

    public var kind: Kind
    public var entries: [Entry]

    /// Google's limits: 50,000 URLs and 50 MB uncompressed per file.
    public static let maxEntries = 50_000
    public static let maxBytes = 50 * 1_024 * 1_024
}

public enum SitemapParser {
    /// Parses XML (optionally gzipped) or a plain-text sitemap.
    public static func parse(_ data: Data) -> Sitemap? {
        let data = Gzip.isGzipped(data) ? (Gzip.decompress(data) ?? data) : data
        guard data.count <= Sitemap.maxBytes else { return nil }

        let delegate = SitemapXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        if parser.parse(), !delegate.entries.isEmpty || delegate.sawSitemapElement {
            return Sitemap(kind: delegate.isIndex ? .index : .urlSet, entries: delegate.entries)
        }

        // Plain-text sitemaps: one URL per line.
        let text = String(decoding: data.prefix(Sitemap.maxBytes), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("http") }
        guard !lines.isEmpty else { return nil }
        return Sitemap(kind: .text, entries: lines.prefix(Sitemap.maxEntries).map { .init(loc: $0, lastModified: nil) })
    }
}

private final class SitemapXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [Sitemap.Entry] = []
    var isIndex = false
    var sawSitemapElement = false
    private var currentElement = ""
    private var currentLoc = ""
    private var currentLastMod = ""
    private var insideEntry = false
    /// Only a <loc> directly inside <url> is the URL. Image, video and news sitemaps nest their
    /// own <loc> one level deeper — and with namespaces processed, <image:loc> arrives here as
    /// plain "loc", so without this the image URL is appended to the page's.
    private var depth = 0
    private var entryDepth: Int?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        currentElement = elementName.lowercased()
        switch currentElement {
        case "sitemapindex":
            isIndex = true
            sawSitemapElement = true
        case "urlset":
            sawSitemapElement = true
        case "url", "sitemap":
            insideEntry = true
            entryDepth = depth
            currentLoc = ""
            currentLastMod = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideEntry, let entryDepth, depth == entryDepth + 1 else { return }
        switch currentElement {
        case "loc": currentLoc += string
        case "lastmod": currentLastMod += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName.lowercased() == "url" || elementName.lowercased() == "sitemap", depth == entryDepth {
            insideEntry = false
            entryDepth = nil
            let loc = currentLoc.trimmingCharacters(in: .whitespacesAndNewlines)
            if !loc.isEmpty, entries.count < Sitemap.maxEntries {
                let lastMod = currentLastMod.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(.init(loc: loc, lastModified: lastMod.isEmpty ? nil : lastMod))
            }
        }
        currentElement = ""
        depth -= 1
    }
}

public enum Gzip {
    public static func isGzipped(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Inflates a gzip container (RFC 1952) using the system's raw DEFLATE decoder.
    public static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }

        let flags = bytes[3]
        var offset = 10
        if flags & 0b0000_0100 != 0 {  // FEXTRA
            guard offset + 1 < bytes.count else { return nil }
            offset += 2 + Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        if flags & 0b0000_1000 != 0 {  // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0b0001_0000 != 0 {  // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0b0000_0010 != 0 { offset += 2 }  // FHCRC
        guard offset < bytes.count - 8 else { return nil }

        let payload = Array(bytes[offset..<(bytes.count - 8)])
        // The last four bytes of a gzip file hold the uncompressed size, modulo 2^32.
        let declaredSize = bytes.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
        let capacity = max(declaredSize, payload.count * 4) + 1_024

        var output = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let written = payload.withUnsafeBufferPointer { input in
            compression_decode_buffer(buffer, capacity, input.baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        output.append(buffer, count: written)
        return output
    }
}
