import Audit
import CrawlCore
import Foundation
import Storage

/// Measures a set of pages, mobile then desktop, saves each result as it arrives, and refreshes
/// the Speed issues at the end.
public struct LighthouseBatch: Sendable {
    public struct Page: Sendable, Hashable {
        public var id: Int64
        public var url: String
        /// The Shopify template this page stands for, when it was picked as one.
        public var template: String?
        public init(id: Int64, url: String, template: String? = nil) {
            self.id = id
            self.url = url
            self.template = template
        }
    }

    public struct Progress: Sendable, Equatable, Codable {
        /// Runs finished, counting each device separately.
        public var done: Int
        public var total: Int
        /// The page being measured now.
        public var currentURL: String?
        public var currentDevice: LighthouseDevice?
        public var failures: Int

        public init(done: Int, total: Int, currentURL: String? = nil, currentDevice: LighthouseDevice? = nil, failures: Int) {
            self.done = done
            self.total = total
            self.currentURL = currentURL
            self.currentDevice = currentDevice
            self.failures = failures
        }
    }

    public struct Result: Sendable {
        public var measured: Int
        public var failures: [(url: String, device: LighthouseDevice, message: String)]
    }

    public let store: CrawlStore
    public let runner: LighthouseRunner
    public let pages: [Page]
    public let headers: [String: String]

    public init(store: CrawlStore, runner: LighthouseRunner, pages: [Page], headers: [String: String] = [:]) {
        self.store = store
        self.runner = runner
        self.pages = pages
        self.headers = headers
    }

    /// Roughly how long a batch takes: about 15 seconds a run, two runs a page.
    public static func estimatedSeconds(pages: Int) -> Int { pages * 2 * 15 }

    /// The headers a crawl sends, so Lighthouse can reach the same authenticated pages.
    public static func headers(for config: CrawlConfig) -> [String: String] {
        var headers = config.customHeaders
        if !config.cookieHeader.isEmpty { headers["Cookie"] = config.cookieHeader }
        if !config.basicAuthUsername.isEmpty {
            let account = CredentialStore.account(host: CrawlScope(config: config).startHost,
                                                  username: config.basicAuthUsername)
            if let password = CredentialStore.password(account: account) {
                let token = Data("\(config.basicAuthUsername):\(password)".utf8).base64EncodedString()
                headers["Authorization"] = "Basic \(token)"
            }
        }
        return headers
    }

    /// Runs every page. Cancelling the task stops after the run in progress is abandoned; whatever
    /// finished before that is kept.
    public func run(progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Result {
        var state = Progress(done: 0, total: pages.count * 2, failures: 0)
        var failures: [(url: String, device: LighthouseDevice, message: String)] = []
        defer { try? PostCrawlAnalyzer.runSpeedChecks(store: store) }

        for page in pages {
            for device in LighthouseDevice.allCases {
                try Task.checkCancellation()
                state.currentURL = page.url
                state.currentDevice = device
                progress(state)
                do {
                    let output = try await runner.run(url: page.url, device: device, headers: headers)
                    try store.saveLighthouse(urlID: page.id, device: device, metrics: output.report.metrics,
                                             opportunities: output.report.opportunities,
                                             reportHTML: output.html, error: output.report.runtimeError,
                                             template: page.template)
                    if let error = output.report.runtimeError {
                        failures.append((page.url, device, error))
                    }
                } catch LighthouseError.cancelled {
                    throw CancellationError()
                } catch {
                    let message = error.localizedDescription
                    failures.append((page.url, device, message))
                    try? store.saveLighthouse(urlID: page.id, device: device, metrics: LighthouseMetrics(),
                                              opportunities: [], reportHTML: nil, error: message, template: page.template)
                }
                state.done += 1
                state.failures = failures.count
            }
        }
        state.currentURL = nil
        state.currentDevice = nil
        progress(state)
        return Result(measured: pages.count * 2 - failures.count, failures: failures)
    }
}
