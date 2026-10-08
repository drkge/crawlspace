import Compare
import CrawlCore
import Crawler
import Export
import Foundation
import Lighthouse
import Rendering
import Storage

/// Runs one scheduled crawl start to finish: crawl, compare with the previous run, export, and
/// record what happened.
public enum ScheduleRunner {
    public struct Result: Sendable {
        public var packageURL: URL
        public var summary: String
        public var comparison: CrawlComparison?
        public var exports: [URL] = []
    }

    public static func crawlsDirectory() -> URL {
        CrawlspacePaths.crawls
    }

    public static func run(scheduleID: UUID, in directory: URL? = nil) async throws -> Result {
        guard var schedule = ScheduleStore.load(id: scheduleID) else {
            throw RunError.noSuchSchedule(scheduleID)
        }
        let crawls = directory ?? crawlsDirectory()
        try FileManager.default.createDirectory(at: crawls, withIntermediateDirectories: true)

        let previous = previousPackage(for: schedule, in: crawls)
        let packageURL = uniquePackageURL(name: schedule.name, in: crawls)

        let config = await PlatformDetector.tailor(schedule.config)
        let store = try CrawlStore.create(at: packageURL, config: config)
        let engine = try CrawlEngine(store: store, config: config)
        await engine.run()

        let overview = try store.overview()
        var summary = "\(overview.crawled.formatted()) URLs crawled"

        // Speed, before the comparison and exports so they include it. A Mac without the runtime
        // yet still gets its crawl; the summary says what was skipped.
        let pages = config.lighthouseTopPages > 0 ? try LighthousePages.choose(store: store, config: config) : []
        if !pages.isEmpty {
            if case .ready(let toolchain) = LighthouseToolchain.locate() {
                let batch = LighthouseBatch(store: store, runner: LighthouseRunner(toolchain: toolchain),
                                            pages: pages,
                                            headers: LighthouseBatch.headers(for: config))
                let measured = try await batch.run()
                summary += " · Lighthouse on \(pages.count) page\(pages.count == 1 ? "" : "s")"
                if !measured.failures.isEmpty { summary += " (\(measured.failures.count) runs failed)" }
            } else {
                summary += " · Lighthouse skipped: not set up yet"
            }
        }
        var result = Result(packageURL: packageURL, summary: summary)

        if schedule.compareWithPrevious, let previous {
            let comparison = try CrawlComparer.compare(baseline: previous, current: store)
            result.comparison = comparison
            summary += " · \(comparison.headline)"
        }

        if schedule.exportCSV {
            let url = packageURL.deletingPathExtension().appendingPathExtension("csv")
            let ids = try store.rowIDs(for: URLListQuery(filter: .internalHTML, sortColumn: .address))
            try TableExport.export(store: store, ids: ids, columns: URLFilter.internalHTML.defaultColumns,
                                   format: .csv, to: url)
            result.exports.append(url)
        }
        if schedule.exportReport {
            let url = packageURL.deletingPathExtension().appendingPathExtension("pdf")
            let html = try ReportBuilder.html(store: store, options: ReportOptions(title: schedule.name))
            let pdf = try await PDFRenderer.pdf(html: html)
            try pdf.write(to: url)
            result.exports.append(url)
        }

        result.summary = summary
        schedule.lastRun = Date()
        schedule.lastSummary = summary
        try ScheduleStore.save(schedule)
        return result
    }

    /// The most recent crawl this schedule produced, used as the comparison baseline.
    static func previousPackage(for schedule: ScheduledCrawl, in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == CrawlStore.packageExtension }
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(schedule.name + " ") }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }

    /// Two runs in the same minute would otherwise collide on the name.
    static func uniquePackageURL(name: String, in directory: URL) -> URL {
        let base = "\(name) \(timestamp())"
        var candidate = directory.appending(path: base).appendingPathExtension(CrawlStore.packageExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base) (\(suffix))").appendingPathExtension(CrawlStore.packageExtension)
            suffix += 1
        }
        return candidate
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: Date())
    }

    public enum RunError: LocalizedError {
        case noSuchSchedule(UUID)
        public var errorDescription: String? {
            switch self {
            case .noSuchSchedule(let id): "No schedule with the id \(id.uuidString)."
            }
        }
    }
}
