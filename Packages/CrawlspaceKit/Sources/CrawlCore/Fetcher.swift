import Foundation

public struct FetchResponse: Sendable {
    public var url: URL
    public var statusCode: Int
    /// Header names lowercased; repeated headers joined with ", ".
    public var headers: [String: String]
    /// MIME type without parameters, lowercased.
    public var mimeType: String?
    public var charset: String?
    public var body: Data?
    public var bodyTruncated: Bool
    /// Content-Length if the server sent one, otherwise the decoded body size when read.
    public var sizeBytes: Int64?
    public var ttfbMs: Double
    public var totalMs: Double
    /// Resolved `Location` header for 3xx responses.
    public var redirectLocation: URL?

    /// Standard reason phrases (RFC 9110). Foundation's localised strings say things like
    /// "no error" for 200, which isn't what an SEO report should show.
    public var statusText: String {
        HTTPStatus.reasonPhrase(statusCode)
    }
}

public enum FetchFailure: Error, Sendable, Equatable {
    case timeout
    case dns
    case connection(String)
    case tls(String)
    case cancelled
    case other(String)

    public var label: String {
        switch self {
        case .timeout: "Timeout"
        case .dns: "DNS lookup failed"
        case .connection(let detail): "Connection failed: \(detail)"
        case .tls(let detail): "TLS error: \(detail)"
        case .cancelled: "Cancelled"
        case .other(let detail): detail
        }
    }

    init(_ error: any Error) {
        guard let urlError = error as? URLError else {
            self = error is CancellationError ? .cancelled : .other(error.localizedDescription)
            return
        }
        switch urlError.code {
        case .timedOut: self = .timeout
        case .cannotFindHost, .dnsLookupFailed: self = .dns
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable:
            self = .connection(urlError.localizedDescription)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            self = .tls(urlError.localizedDescription)
        case .cancelled: self = .cancelled
        default: self = .other(urlError.localizedDescription)
        }
    }
}

/// HTTP client for crawling. Redirects are never followed automatically so every hop can be
/// recorded; bodies are only downloaded when needed and are size-capped.
public final class Fetcher: Sendable {
    public enum BodyPolicy: Sendable {
        /// Headers only; the transfer is cancelled as soon as they arrive.
        case never
        /// Download the body only for HTML responses.
        case htmlOnly(maxBytes: Int)
        /// Download the body only if the server didn't send Content-Length (to measure size).
        case sizeIfUnknown(maxBytes: Int)
        case always(maxBytes: Int)
    }

    /// Extra request headers for authenticated crawls. They are only ever sent to URLs the
    /// `appliesTo` predicate approves, so credentials never leak to external sites.
    public struct Authentication: Sendable {
        public var username: String
        public var password: String
        public var headers: [String: String]
        public var cookieHeader: String
        public var appliesTo: @Sendable (URL) -> Bool

        public init(username: String = "", password: String = "", headers: [String: String] = [:],
                    cookieHeader: String = "", appliesTo: @escaping @Sendable (URL) -> Bool) {
            self.username = username
            self.password = password
            self.headers = headers
            self.cookieHeader = cookieHeader
            self.appliesTo = appliesTo
        }

        var authorizationHeader: String? {
            guard !username.isEmpty else { return nil }
            let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
            return "Basic \(encoded)"
        }

        var isEmpty: Bool { username.isEmpty && headers.isEmpty && cookieHeader.isEmpty }
    }

    private let crawlSession: URLSession
    private let followingSession: URLSession
    private let authentication: Authentication?

    public convenience init(userAgent: String, timeout: TimeInterval, maxConnectionsPerHost: Int) {
        self.init(userAgent: userAgent, timeout: timeout, maxConnectionsPerHost: maxConnectionsPerHost, authentication: nil)
    }

    public init(userAgent: String, timeout: TimeInterval, maxConnectionsPerHost: Int, authentication: Authentication?) {
        self.authentication = authentication.flatMap { $0.isEmpty ? nil : $0 }
        func configuration() -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.httpMaximumConnectionsPerHost = max(1, maxConnectionsPerHost)
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 3
            config.waitsForConnectivity = false
            config.httpAdditionalHeaders = [
                "User-Agent": userAgent,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-GB,en;q=0.9",
            ]
            return config
        }
        crawlSession = URLSession(configuration: configuration(), delegate: NoRedirectDelegate(), delegateQueue: nil)
        followingSession = URLSession(configuration: configuration())
    }

    deinit {
        crawlSession.invalidateAndCancel()
        followingSession.invalidateAndCancel()
    }

    /// Fetches without following redirects.
    public func fetch(_ url: URL, body policy: BodyPolicy) async -> Result<FetchResponse, FetchFailure> {
        await perform(url, policy: policy, session: crawlSession)
    }

    /// Fetches following redirects (used for robots.txt and sitemaps).
    public func fetchFollowingRedirects(_ url: URL, body policy: BodyPolicy) async -> Result<FetchResponse, FetchFailure> {
        await perform(url, policy: policy, session: followingSession)
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        guard let authentication, authentication.appliesTo(url) else { return request }
        if let header = authentication.authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        if !authentication.cookieHeader.isEmpty {
            request.setValue(authentication.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in authentication.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func perform(_ url: URL, policy: BodyPolicy, session: URLSession) async -> Result<FetchResponse, FetchFailure> {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (bytes, response) = try await session.bytes(for: request(for: url))
            let ttfb = start.duration(to: clock.now)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return .failure(.other("Not an HTTP response"))
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let name = (key as? String)?.lowercased() else { continue }
                let text = "\(value)"
                headers[name] = headers[name].map { "\($0), \(text)" } ?? text
            }
            let contentLength = headers["content-length"].flatMap { Int64($0) }
            let mimeType = http.mimeType?.lowercased()
            let isHTML = mimeType == "text/html" || mimeType == "application/xhtml+xml"

            let maxBytes: Int? = switch policy {
            case .never: nil
            case .htmlOnly(let max): isHTML ? max : nil
            case .sizeIfUnknown(let max): contentLength == nil ? max : nil
            case .always(let max): max
            }

            var body: Data?
            var truncated = false
            if let maxBytes {
                var buffer: [UInt8] = []
                buffer.reserveCapacity(Int(min(contentLength ?? 64_000, Int64(maxBytes))))
                for try await byte in bytes {
                    if buffer.count >= maxBytes {
                        truncated = true
                        break
                    }
                    buffer.append(byte)
                }
                if truncated { bytes.task.cancel() }
                body = Data(buffer)
            } else {
                bytes.task.cancel()
            }

            var redirect: URL?
            if (300...399).contains(http.statusCode), let location = headers["location"] {
                redirect = URL(string: location, relativeTo: url)?.absoluteURL
            }

            return .success(FetchResponse(
                url: url,
                statusCode: http.statusCode,
                headers: headers,
                mimeType: mimeType,
                charset: http.textEncodingName,
                body: body,
                bodyTruncated: truncated,
                sizeBytes: contentLength ?? body.map { Int64($0.count) },
                ttfbMs: ttfb.milliseconds,
                totalMs: start.duration(to: clock.now).milliseconds,
                redirectLocation: redirect
            ))
        } catch {
            return .failure(FetchFailure(error))
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension Duration {
    public var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
