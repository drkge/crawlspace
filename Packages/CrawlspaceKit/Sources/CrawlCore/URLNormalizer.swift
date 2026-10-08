import Foundation

/// Turns an href found in a document into the canonical string form used as a URL's identity.
///
/// Normalisation that doesn't change which resource is addressed:
/// - resolve relative references (RFC 3986) against the base URL
/// - lowercase scheme and host, punycode internationalised hosts, drop default ports
/// - remove dot segments, drop the fragment, default an empty path to `/`
/// - uppercase percent-escape hex digits and decode escaped unreserved characters
///
/// Trailing slashes, case in paths, and query strings are preserved because servers (and search
/// engines) treat those as different URLs. Only parameters listed in `stripParameters` are removed.
public enum URLNormalizer {
    public static func normalize(_ raw: String, relativeTo base: URL? = nil, stripParameters: [String] = []) -> URL? {
        // Browsers strip leading/trailing C0 control/space and remove tab/newline anywhere.
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            cleaned.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" }
        }
        guard !cleaned.isEmpty, !cleaned.hasPrefix("#") else { return nil }

        guard let resolved = URL(string: cleaned, relativeTo: base)?.absoluteURL,
              // Re-parse the absolute string so internationalised hosts come back as punycode.
              var components = URLComponents(string: resolved.absoluteString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.percentEncodedHost, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.percentEncodedHost = host.lowercased()
        if let port = components.port, (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }
        components.fragment = nil
        components.user = nil
        components.password = nil

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        path = normalizePercentEncoding(removeDotSegments(path))
        components.percentEncodedPath = path

        if let query = components.percentEncodedQuery {
            var normalizedQuery = normalizePercentEncoding(query)
            if !stripParameters.isEmpty {
                normalizedQuery = strip(parameters: stripParameters, from: normalizedQuery)
            }
            components.percentEncodedQuery = normalizedQuery.isEmpty ? nil : normalizedQuery
        }

        return components.url
    }

    /// Convenience returning the normalised absolute string.
    public static func normalizedString(_ raw: String, relativeTo base: URL? = nil, stripParameters: [String] = []) -> String? {
        normalize(raw, relativeTo: base, stripParameters: stripParameters)?.absoluteString
    }

    /// RFC 3986 §5.2.4, operating on an absolute path.
    static func removeDotSegments(_ path: String) -> String {
        guard path.contains(".") else { return path }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        var output: [Substring] = []
        let last = segments.count - 1
        for (index, segment) in segments.enumerated() {
            if segment == "." {
                if index == last { output.append("") }
            } else if segment == ".." {
                if output.count > 1 { output.removeLast() }
                if index == last { output.append("") }
            } else {
                output.append(segment)
            }
        }
        let joined = output.joined(separator: "/")
        return joined.hasPrefix("/") ? joined : "/" + joined
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// Uppercases escape hex digits and decodes escapes of unreserved characters (ALPHA DIGIT - . _ ~).
    static func normalizePercentEncoding(_ input: String) -> String {
        guard input.utf8.contains(UInt8(ascii: "%")) else { return input }
        let bytes = Array(input.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "%"), i + 2 < bytes.count,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                let decoded = hi << 4 | lo
                if isUnreserved(decoded) {
                    out.append(decoded)
                } else {
                    out.append(UInt8(ascii: "%"))
                    out.append(hexDigits[Int(hi)])
                    out.append(hexDigits[Int(lo)])
                }
                i += 3
            } else {
                out.append(byte)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    private static func strip(parameters patterns: [String], from query: String) -> String {
        query
            .split(separator: "&", omittingEmptySubsequences: true)
            .filter { pair in
                let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                return !patterns.contains { matchesParameter(name, pattern: $0) }
            }
            .joined(separator: "&")
    }

    static func matchesParameter(_ name: String, pattern: String) -> Bool {
        if pattern.hasSuffix("*") {
            return name.lowercased().hasPrefix(pattern.dropLast().lowercased())
        }
        return name.caseInsensitiveCompare(pattern) == .orderedSame
    }
}
