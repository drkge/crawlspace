import Foundation

/// The browser UI, built from `Web/` and embedded so the app is self-contained.
public enum WebAssets {
    public struct File: Sendable {
        public let contentType: String
        public let data: Data
    }

    /// Files by path, such as `index.html` and `assets/index-3f2a.js`.
    public static let files: [String: File] = {
        var files: [String: File] = [:]
        for (path, contentType, base64) in Generated.files {
            if let data = Data(base64Encoded: base64) { files[path] = File(contentType: contentType, data: data) }
        }
        return files
    }()
}
