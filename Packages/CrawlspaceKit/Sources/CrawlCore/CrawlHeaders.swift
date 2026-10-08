import Foundation

/// A crawl's cookie and custom headers can carry a signed-in session, so they're kept in the
/// secrets file rather than in the crawl package or schedule file. A `.crawlspace` package sent to
/// someone else then has everything about the crawl except the login.
extension CrawlConfig {
    private struct Headers: Codable {
        var cookie: String
        var headers: [String: String]
    }

    /// This config as it should be written to disk: the cookie and custom headers are saved under
    /// `account` in the secrets file and left out of the copy returned.
    public func separatingHeaders(account: String) throws -> CrawlConfig {
        guard !cookieHeader.isEmpty || !customHeaders.isEmpty else {
            CredentialStore.delete(account: account)
            return self
        }
        let json = try JSONEncoder().encode(Headers(cookie: cookieHeader, headers: customHeaders))
        try CredentialStore.save(password: String(decoding: json, as: UTF8.self), account: account)
        var stored = self
        stored.cookieHeader = ""
        stored.customHeaders = [:]
        return stored
    }

    /// Puts back the cookie and headers saved under `account`. A config written before they moved
    /// out keeps its own.
    public mutating func restoreHeaders(account: String) {
        guard cookieHeader.isEmpty, customHeaders.isEmpty,
              let json = CredentialStore.password(account: account),
              let headers = try? JSONDecoder().decode(Headers.self, from: Data(json.utf8)) else { return }
        cookieHeader = headers.cookie
        customHeaders = headers.headers
    }
}
