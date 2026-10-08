import AppKit
import Foundation
import PDFKit
import WebKit

/// Turns an HTML string into a paginated PDF.
///
/// WebKit gives us two options and both have problems: `createPDF` produces one page as tall as
/// the content, and printing headlessly through AppKit runs away (hundreds of megabytes). So this
/// takes the tall page and slices it — but first it asks the page where its blocks end, and cuts
/// between blocks rather than through them.
@MainActor
public enum PDFRenderer {
    /// A4 at 72dpi, which is the unit `createPDF` works in.
    public static let a4 = CGSize(width: 595, height: 842)

    public enum PDFError: LocalizedError {
        case loadFailed(String)
        case pdfFailed

        public var errorDescription: String? {
            switch self {
            case .loadFailed(let detail): "Couldn't lay the report out: \(detail)"
            case .pdfFailed: "Couldn't produce the PDF."
            }
        }
    }

    /// Elements the paginator is allowed to break between.
    /// Structural blocks only — breaking between paragraphs inside a card splits the card.
    private static let breakSelectors = "header, section, h2, h3, .issue, .chart, .tiles, table tr"

    public static func pdf(html: String, pageSize: CGSize = a4) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: pageSize), configuration: configuration)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate

        // WebKit only lays out and paints inside a window.
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: pageSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        webView.loadHTMLString(html, baseURL: nil)
        try await delegate.waitUntilLoaded()
        try? await Task.sleep(for: .milliseconds(200))

        let contentHeight = try await measure(webView, script: "document.body.scrollHeight")
        guard contentHeight > 0 else { throw PDFError.loadFailed("the page measured zero height") }

        // Grow the view to the full content height so the capture includes everything.
        webView.frame = CGRect(x: 0, y: 0, width: pageSize.width, height: contentHeight)
        try? await Task.sleep(for: .milliseconds(200))

        let breaks = try await breakOffsets(webView)
        let configurationPDF = WKPDFConfiguration()
        configurationPDF.rect = CGRect(x: 0, y: 0, width: pageSize.width, height: contentHeight)
        let tall = try await webView.pdf(configuration: configurationPDF)

        return try paginate(tall: tall, contentHeight: contentHeight, breaks: breaks, pageSize: pageSize)
    }

    // MARK: - Measuring

    private static func measure(_ webView: WKWebView, script: String) async throws -> CGFloat {
        let value = try await webView.evaluateJavaScript(script)
        return (value as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    /// Y offsets (from the top of the document) where a page break wouldn't cut through content.
    private static func breakOffsets(_ webView: WKWebView) async throws -> [CGFloat] {
        let script = """
        Array.from(document.querySelectorAll('\(breakSelectors)'))
          .map(el => el.getBoundingClientRect().bottom + window.scrollY)
          .filter(y => y > 0)
          .sort((a, b) => a - b)
        """
        let value = try await webView.evaluateJavaScript(script)
        let offsets = (value as? [Any])?.compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } } ?? []
        return offsets
    }

    // MARK: - Slicing

    /// Slices a tall single-page PDF into pages, cutting at the given content offsets.
    /// Pure CoreGraphics work, so it doesn't need the main actor.
    public nonisolated static func paginate(tall: Data, contentHeight: CGFloat, breaks: [CGFloat], pageSize: CGSize) throws -> Data {
        guard let document = PDFDocument(data: tall), let page = document.page(at: 0),
              let pageRef = page.pageRef else { throw PDFError.pdfFailed }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { throw PDFError.pdfFailed }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw PDFError.pdfFailed }

        var top: CGFloat = 0
        while top < contentHeight - 1 {
            let idealBottom = min(top + pageSize.height, contentHeight)
            var bottom = idealBottom
            if idealBottom < contentHeight {
                // Cut at the last block boundary that fits, as long as it fills a reasonable part
                // of the page; otherwise cut at the page height and accept the split.
                if let candidate = breaks.last(where: { $0 <= idealBottom && $0 > top + pageSize.height * 0.4 }) {
                    bottom = candidate
                }
            }
            let sliceHeight = bottom - top
            if ProcessInfo.processInfo.environment["CRAWLSPACE_DEBUG_PDF"] != nil {
                FileHandle.standardError.write(Data("page cut: \(top) → \(bottom) (ideal \(idealBottom), height \(sliceHeight))\n".utf8))
            }

            context.beginPage(mediaBox: &mediaBox)
            context.saveGState()
            // Clip to this slice, or the content that follows it bleeds into the blank space left
            // at the bottom of a short page.
            context.clip(to: CGRect(x: 0, y: pageSize.height - sliceHeight, width: pageSize.width, height: sliceHeight))
            // PDF coordinates start at the bottom-left, so shift the tall page up to expose this
            // slice, then sit the slice at the top of the paper.
            context.translateBy(x: 0, y: pageSize.height - sliceHeight - (contentHeight - bottom))
            context.drawPDFPage(pageRef)
            context.restoreGState()
            context.endPage()

            top = bottom
        }
        context.closePDF()
        return output as Data
    }
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finished = false
    private var failure: (any Error)?

    func waitUntilLoaded() async throws {
        if finished {
            if let failure { throw failure }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.resume(with: nil)
            }
        }
    }

    private func resume(with error: (any Error)?) {
        guard !finished else { return }
        finished = true
        failure = error
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(with: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resume(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resume(with: error)
    }
}
