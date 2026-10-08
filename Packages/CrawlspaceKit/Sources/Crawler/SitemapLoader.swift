import CrawlCore
import Foundation
import Storage

/// Reads XML sitemaps, following sitemap indexes to the sitemaps they list.
struct SitemapLoader: Sendable {
    let fetcher: Fetcher
    var maxFiles = 100

    struct Output: Sendable {
        var records: [SitemapRecord] = []
        var entries: [SitemapURLRecord] = []
        /// Unique, normalised URLs listed across all the sitemaps.
        var urls: [URL] = []
    }

    func load(_ sitemapURLs: [URL], stripParameters: [String]) async -> Output {
        var output = Output()
        var queue = sitemapURLs
        var visited = Set<String>()
        var seenURLs = Set<String>()

        while !queue.isEmpty, output.records.count < maxFiles {
            let sitemapURL = queue.removeFirst()
            guard visited.insert(sitemapURL.absoluteString).inserted else { continue }

            switch await fetcher.fetchFollowingRedirects(sitemapURL, body: .always(maxBytes: Sitemap.maxBytes)) {
            case .failure(let failure):
                output.records.append(SitemapRecord(url: sitemapURL.absoluteString, kind: nil, entryCount: 0,
                                                    statusCode: nil, error: failure.label))
            case .success(let response):
                guard (200...299).contains(response.statusCode), let body = response.body,
                      let sitemap = SitemapParser.parse(body) else {
                    output.records.append(SitemapRecord(
                        url: sitemapURL.absoluteString, kind: nil, entryCount: 0, statusCode: response.statusCode,
                        error: (200...299).contains(response.statusCode) ? "Couldn't parse this sitemap" : nil
                    ))
                    continue
                }

                output.records.append(SitemapRecord(url: sitemapURL.absoluteString, kind: sitemap.kind.rawValue,
                                                    entryCount: sitemap.entries.count, statusCode: response.statusCode, error: nil))
                for entry in sitemap.entries {
                    guard let url = URLNormalizer.normalize(entry.loc, relativeTo: sitemapURL, stripParameters: stripParameters) else { continue }
                    if sitemap.kind == .index {
                        queue.append(url)
                    } else if seenURLs.insert(url.absoluteString).inserted {
                        output.entries.append(SitemapURLRecord(url: url.absoluteString, sitemap: sitemapURL.absoluteString,
                                                               lastModified: entry.lastModified))
                        output.urls.append(url)
                    }
                }
            }
        }
        return output
    }
}
