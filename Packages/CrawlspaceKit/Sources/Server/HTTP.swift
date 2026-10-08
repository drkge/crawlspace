import CrawlCore
import Foundation
import Hummingbird

/// Request context with room for report logos and long URL lists in request bodies.
struct AppContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        coreContext = .init(source: source)
    }

    var maxUploadSize: Int { 25 * 1024 * 1024 }
}

enum Coding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Any encodable value as a JSON response that the browser never caches.
struct JSON<Value: Encodable & Sendable>: ResponseGenerator {
    var value: Value
    var status: HTTPResponse.Status = .ok

    init(_ value: Value, status: HTTPResponse.Status = .ok) {
        self.value = value
        self.status = status
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let data = try Coding.encoder.encode(value)
        return Response(status: status,
                        headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// A file for the browser to save, such as an export or report.
func download(_ data: Data, filename: String, contentType: String) -> Response {
    // RFC 6266: an ASCII fallback, and the real name percent-encoded for browsers that read it.
    let ascii = String(filename.unicodeScalars.map { $0.isASCII && $0 != "\"" ? Character($0) : "_" })
    let encoded = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
    return Response(
        status: .ok,
        headers: [
            .contentType: contentType,
            .contentDisposition: "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)",
            .cacheControl: "no-store",
        ],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
    )
}

/// The same, shown in the browser rather than saved (HTML reports, page source, screenshots).
func inline(_ data: Data, contentType: String) -> Response {
    Response(status: .ok,
             headers: [.contentType: contentType, .cacheControl: "no-store", .init("X-Content-Type-Options")!: "nosniff"],
             body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
}

extension Request {
    func query(_ name: String) -> String? {
        uri.queryParameters[Substring(name)].map { String($0).removingPercentEncoding ?? String($0) }
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, context: AppContext) async throws -> T {
        var request = self
        let buffer = try await request.collectBody(upTo: context.maxUploadSize)
        do {
            return try Coding.decoder.decode(type, from: Data(buffer.readableBytesView))
        } catch {
            throw ServerError.badRequest("That request couldn't be read: \(error.localizedDescription)")
        }
    }
}

extension Parameters {
    /// A path parameter, percent-decoded: crawl names contain spaces.
    func string(_ name: String) throws -> String {
        let raw = try require(name)
        return raw.removingPercentEncoding ?? raw
    }
}

/// Keeps the server to this Mac's own browser.
///
/// It listens on 127.0.0.1 only, but any web page the user visits could still try to reach it.
/// Three checks stop that:
/// - the Host header must name this server, which defeats DNS rebinding;
/// - every API call needs the install's token, set as a SameSite=Strict cookie by the link the
///   app opens, which other sites can neither read nor send;
/// - anything that changes state must come from this server's own origin.
struct SecurityMiddleware: RouterMiddleware {
    typealias Context = AppContext

    static let cookieName = "crawlspace_session"

    let port: Int
    let token: String
    /// Origins allowed besides our own: the Vite dev server, when developing the UI.
    let extraOrigins: Set<String>
    /// Host names allowed besides our own; only tests need any.
    var extraHosts: Set<String> = []

    var allowedHosts: Set<String> { Set(["127.0.0.1:\(port)", "localhost:\(port)"]).union(extraHosts) }

    func isAllowed(host: String) -> Bool { allowedHosts.contains(host) }
    var allowedOrigins: Set<String> { Set(allowedHosts.map { "http://\($0)" }).union(extraOrigins) }

    func handle(_ request: Request, context: AppContext,
                next: (Request, AppContext) async throws -> Response) async throws -> Response {
        let host = request.head.authority ?? ""
        guard isAllowed(host: host) else {
            return Response(status: .misdirectedRequest)
        }

        if let origin = request.headers[.origin], !allowedOrigins.contains(origin),
           request.method != .get, request.method != .head {
            return try ServerError.forbidden("Requests from \(origin) aren't allowed.").response(from: request, context: context)
        }

        // The link the app opens carries the token once; swap it for a cookie and drop it from the
        // address bar so it isn't left in history or bookmarks.
        if request.uri.path == "/auth", let supplied = request.query("t") {
            guard constantTimeEqual(supplied, token) else {
                return Response(status: .seeOther, headers: [.location: "/"])
            }
            // Only a path on this server: never somewhere else the link might have been pointed.
            var next = request.query("next") ?? "/"
            if !next.hasPrefix("/") || next.hasPrefix("//") || next.contains("\\") { next = "/" }
            let maxAge = 60 * 60 * 24 * 365
            return Response(status: .seeOther, headers: [
                .location: next,
                .setCookie: "\(Self.cookieName)=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(maxAge)",
            ])
        }

        let path = request.uri.path
        if path.hasPrefix("/api/"), path != "/api/health" {
            let cookie = request.cookies[Self.cookieName]?.value ?? ""
            guard constantTimeEqual(cookie, token) else {
                return try ServerError.forbidden("Open \(AppIdentity.name) from its menu-bar icon to sign this browser in.")
                    .response(from: request, context: context)
            }
        }

        var response = try await next(request, context)
        response.headers[.init("X-Content-Type-Options")!] = "nosniff"
        response.headers[.init("Referrer-Policy")!] = "no-referrer"
        return response
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
