import CrawlCore
import Foundation
import Integrations

/// The API tokens the app holds for other services: one per service, so adding a token replaces
/// the one before. Each is kept with the date it was added, and shown to the browser masked.
/// Updates come from a public repository, so there's no GitHub token among them.
public enum AppTokens {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case clickup

        var account: String {
            switch self {
            case .clickup: ClickUpClient.keychainAccount
            }
        }

        var service: String {
            switch self {
            case .clickup: "ClickUp"
            }
        }

        /// What the token is used for, and so what stops without it.
        var purpose: String {
            switch self {
            case .clickup: "Files issues into ClickUp"
            }
        }
    }

    /// One row of the tokens table.
    struct Entry: Encodable, Sendable {
        var kind: Kind
        var service: String
        var purpose: String
        /// `pk_…X4qZ`, or nil when none has been added.
        var masked: String?
        var addedAt: Date?
    }

    private static func dateAccount(_ kind: Kind) -> String { "\(kind.account).added-at" }

    public static func save(_ value: String, as kind: Kind) throws {
        try CredentialStore.save(password: value, account: kind.account)
        try CredentialStore.save(password: ISO8601DateFormatter().string(from: .now), account: dateAccount(kind))
    }

    public static func remove(_ kind: Kind) {
        CredentialStore.delete(account: kind.account)
        CredentialStore.delete(account: dateAccount(kind))
    }

    static func entries() -> [Entry] {
        Kind.allCases.map { kind in
            let token = CredentialStore.password(account: kind.account)
            let added = CredentialStore.password(account: dateAccount(kind)).flatMap { ISO8601DateFormatter().date(from: $0) }
            return Entry(kind: kind, service: kind.service, purpose: kind.purpose,
                         masked: token.map(mask), addedAt: token == nil ? nil : added)
        }
    }

    /// The answer to "does this token work?", from asking the service itself.
    struct Check: Encodable, Sendable {
        enum Status: String, Encodable, Sendable {
            /// The service accepted it and it can do its job.
            case working
            /// The service doesn't accept it at all: mistyped, expired or revoked.
            case rejected
            /// Couldn't ask: offline, or the service is having trouble.
            case unknown
        }
        var status: Status
        var detail: String
        var checkedAt = Date()
    }

    /// Asks the service whether the saved token works, with one harmless read.
    static func check(_ kind: Kind) async -> Check {
        guard let token = CredentialStore.password(account: kind.account) else {
            return Check(status: .unknown, detail: "No token added.")
        }
        var request: URLRequest
        switch kind {
        case .clickup:
            // Whose token this is: proves it's valid, and says which account it belongs to.
            request = URLRequest(url: URL(string: "https://api.clickup.com/api/v2/user")!)
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.setValue("\(AppIdentity.name)/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let status: Int
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return Check(status: .unknown, detail: "Couldn't reach \(kind.service): \(error.localizedDescription)")
        }

        switch (kind, status) {
        case (.clickup, 200):
            let user = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["user"] as? [String: Any]
            let name = user?["username"] as? String ?? user?["email"] as? String
            return Check(status: .working, detail: name.map { "Connected as \($0)" } ?? "Connected")
        case (_, 401):
            return Check(status: .rejected, detail: "\(kind.service) doesn't accept this token. It may be mistyped, expired or revoked.")
        default:
            return Check(status: .unknown, detail: "\(kind.service) answered \(status). Try again in a moment.")
        }
    }

    /// Keeps a token's type prefix (`pk_`, `github_pat_`, `ghp_`) and its last four characters.
    static func mask(_ token: String) -> String {
        let prefix = token.range(of: "^[A-Za-z]+(_[A-Za-z]+)?_", options: .regularExpression).map { String(token[$0]) } ?? ""
        guard token.count >= prefix.count + 8 else { return prefix + "…" }
        return prefix + "…" + token.suffix(4)
    }
}
