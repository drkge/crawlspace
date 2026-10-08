import AppKit
import CrawlCore
import Foundation
import WebKit

/// Renders pages with WebKit so JavaScript-built content is crawled the way a browser sees it.
///
/// WKWebView is main-thread only, so the renderer is a `@MainActor` class holding a small pool of
/// offscreen web views. Loading is asynchronous, so the main actor stays free while pages load and
/// several pages render at once.
///
/// Note this is WebKit, not the Chromium that Googlebot uses, so a small number of rendering
/// differences are possible — and rendering is far slower than fetching HTML, so it suits subsets
/// of a site rather than a million URLs.
@MainActor
public final class PageRenderer {
    public struct RenderResult: Sendable {
        /// Serialised DOM after scripts have run.
        public var html: String?
        public var finalURL: URL?
        public var statusCode: Int?
        /// PNG of the viewport, if screenshots were requested.
        public var screenshot: Data?
        public var error: String?
        public var renderMs: Double
    }

    public struct Options: Sendable {
        public var userAgent: String
        public var concurrency: Int
        /// How long to keep waiting after `didFinish` for late, script-driven changes.
        public var settleSeconds: Double
        public var timeoutSeconds: Double
        public var viewport: CGSize
        public var captureScreenshots: Bool
        /// Skip images, media and fonts, which makes rendering much faster.
        public var blockHeavyResources: Bool

        public init(userAgent: String, concurrency: Int = 4, settleSeconds: Double = 2,
                    timeoutSeconds: Double = 20, viewport: CGSize = CGSize(width: 1_200, height: 900),
                    captureScreenshots: Bool = false, blockHeavyResources: Bool = false) {
            self.userAgent = userAgent
            self.concurrency = max(1, min(concurrency, 8))
            self.settleSeconds = settleSeconds
            self.timeoutSeconds = timeoutSeconds
            self.viewport = viewport
            self.captureScreenshots = captureScreenshots
            self.blockHeavyResources = blockHeavyResources
        }
    }

    private let options: Options
    private var idle: [RenderWebView] = []
    private var created = 0
    private var waiters: [CheckedContinuation<RenderWebView, Never>] = []
    private var ruleList: WKContentRuleList?
    private var preparedRules = false
    /// Cookies injected into every render (set for authenticated crawls).
    private var cookies: [HTTPCookie] = []

    /// Nothing here touches the main actor, so a crawl can build the renderer from any context;
    /// the web views themselves are created on demand on the main actor.
    public nonisolated init(options: Options) {
        self.options = options
    }

    public func setCookies(_ cookies: [HTTPCookie]) {
        self.cookies = cookies
    }

    public func render(_ url: URL) async -> RenderResult {
        let clock = ContinuousClock()
        let start = clock.now
        await prepareRulesIfNeeded()
        let view = await acquire()
        defer { release(view) }

        for cookie in cookies {
            await view.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }

        var result = await view.load(url, settle: options.settleSeconds, timeout: options.timeoutSeconds)
        if result.error == nil, options.captureScreenshots {
            result.screenshot = await view.screenshot()
        }
        result.renderMs = start.duration(to: clock.now).milliseconds
        await view.reset()
        return result
    }

    // MARK: - Pool

    private func acquire() async -> RenderWebView {
        if let view = idle.popLast() { return view }
        if created < options.concurrency {
            created += 1
            let view = RenderWebView(options: options, ruleList: ruleList)
            return view
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func release(_ view: RenderWebView) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: view)
        } else {
            idle.append(view)
        }
    }

    private func prepareRulesIfNeeded() async {
        guard options.blockHeavyResources, !preparedRules else { return }
        preparedRules = true
        let rules = """
        [{"trigger": {"url-filter": ".*", "resource-type": ["image", "media", "font"]}, "action": {"type": "block"}}]
        """
        ruleList = try? await WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "crawlspace-block-heavy", encodedContentRuleList: rules
        )
    }
}

/// One offscreen web view plus the navigation delegate that reports how the load went.
@MainActor
final class RenderWebView: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    /// Offscreen host window: WebKit only paints (so snapshots only work) in a window.
    private let window: NSWindow
    private var continuation: CheckedContinuation<PageRenderer.RenderResult, Never>?
    private var statusCode: Int?
    private var failure: String?

    init(options: PageRenderer.Options, ruleList: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = false
        if let ruleList { configuration.userContentController.add(ruleList) }
        webView = WKWebView(frame: CGRect(origin: .zero, size: options.viewport), configuration: configuration)
        webView.customUserAgent = options.userAgent
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: options.viewport),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderBack(nil)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL, settle: Double, timeout: Double) async -> PageRenderer.RenderResult {
        statusCode = nil
        failure = nil

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<PageRenderer.RenderResult, Never>) in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            webView.load(request)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.continuation != nil else { return }
                self.webView.stopLoading()
                self.finish(error: "Render timeout")
            }
        }
        guard loaded.error == nil else { return loaded }

        // Give late, script-driven DOM changes a chance to land before serialising.
        try? await Task.sleep(for: .seconds(settle))

        var result = loaded
        let dom = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
        result.html = dom as? String
        result.finalURL = webView.url
        if result.html == nil { result.error = "Couldn't read the rendered DOM" }
        return result
    }

    func screenshot() async -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 600
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func reset() async {
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func finish(error: String? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: PageRenderer.RenderResult(
            html: nil, finalURL: webView.url, statusCode: statusCode, screenshot: nil,
            error: error ?? failure, renderMs: 0
        ))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            statusCode = response.statusCode
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(error: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(error: error.localizedDescription)
    }
}
