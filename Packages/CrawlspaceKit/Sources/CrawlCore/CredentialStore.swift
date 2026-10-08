import Foundation

/// Keeps crawl passwords and API tokens out of config files and crawl packages.
///
/// Not the Keychain: the app is ad-hoc signed and replaced on every update, and the Keychain ties an
/// item to the signature of the app that saved it, so every update would ask permission again.
/// Secrets live in one JSON file that only this user can read (`secrets.json`, mode 0600).
public enum CredentialStore {
    private static let lock = NSLock()

    public static var fileURL: URL { CrawlspacePaths.secrets }

    /// Account name for a crawl's HTTP credentials.
    public static func account(host: String, username: String) -> String {
        "\(username)@\(host)"
    }

    public static func save(password: String, account: String) throws {
        try save(password: password, account: account, in: fileURL)
    }

    public static func password(account: String) -> String? {
        password(account: account, in: fileURL)
    }

    public static func delete(account: String) {
        delete(account: account, in: fileURL)
    }

    // `file` is for tests, which each use a throwaway copy.

    static func save(password: String, account: String, in file: URL) throws {
        try lock.withLock {
            var secrets = try read(file)
            secrets[account] = password
            try write(secrets, to: file)
        }
    }

    static func password(account: String, in file: URL) -> String? {
        lock.withLock { (try? read(file))?[account] }
    }

    static func delete(account: String, in file: URL) {
        lock.withLock {
            guard var secrets = try? read(file), secrets.removeValue(forKey: account) != nil else { return }
            try? write(secrets, to: file)
        }
    }

    // MARK: - file

    /// Everything in the file; empty when there's no file yet. A file that's there but can't be
    /// read throws rather than reading as empty: saving on top of "empty" would wipe every other
    /// secret in it.
    private static func read(_ fileURL: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
        } catch {
            throw CredentialStoreError.unreadable(fileURL.path)
        }
    }

    private static func write(_ secrets: [String: String], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(secrets)
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Written beside the real file with 0600 from the start, then renamed over it, so there is
        // never a moment where the secrets are readable by anyone else or half-written.
        let temporary = folder.appending(path: ".secrets-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CredentialStoreError.cannotWrite(fileURL.path)
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CredentialStoreError.cannotWrite(fileURL.path)
        }
    }

}

public enum CredentialStoreError: LocalizedError {
    case cannotWrite(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .cannotWrite(let path): "Couldn't save the secrets file at \(path)."
        case .unreadable(let path): "The secrets file at \(path) couldn't be read, so nothing was saved over it."
        }
    }
}
