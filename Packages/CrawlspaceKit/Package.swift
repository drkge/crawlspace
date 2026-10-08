// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The test suites and the fixture site they crawl are kept on the maintainer's Mac, not in the
// repository, so the test targets only exist where the Tests folder does.
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests")
let testTargets: [Target] = hasTests ? [
    .testTarget(name: "CrawlCoreTests", dependencies: ["CrawlCore"]),
    .testTarget(name: "ParsingTests", dependencies: ["Parsing"]),
    .testTarget(name: "CrawlerTests", dependencies: ["Crawler", "Storage", "Audit", "Export"]),
    .testTarget(name: "ExportTests", dependencies: ["Export", "Storage", "Rendering", "Integrations"]),
    .testTarget(name: "CompareTests", dependencies: ["Compare", "Storage", "Crawler"]),
    .testTarget(name: "SchedulingTests", dependencies: ["Scheduling"]),
    .testTarget(name: "ServerTests", dependencies: [
        "Server", "Storage", "CrawlCore", .product(name: "HummingbirdTesting", package: "hummingbird"),
    ]),
    .testTarget(name: "LighthouseTests", dependencies: ["Lighthouse", "Storage", "Audit"],
                resources: [.copy("Fixtures")]),
] : []

let package = Package(
    name: "CrawlspaceKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "CrawlspaceKit",
            targets: ["CrawlCore", "Parsing", "Storage", "Audit", "Rendering", "Crawler", "Export", "Integrations", "Compare",
                      "Scheduling", "Lighthouse"]
        ),
        .executable(name: "crawlspace", targets: ["crawlspace"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/tid-kijyun/Kanna.git", from: "6.1.0"),
        .package(url: "https://github.com/jmcnamara/libxlsxwriter.git", from: "1.2.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
    ],
    targets: [
        // Foundation-only building blocks: config, URL normalisation, robots.txt, fetching.
        .target(name: "CrawlCore"),

        // HTML extraction (libxml2 via Kanna) and SERP pixel-width measurement.
        .target(
            name: "Parsing",
            dependencies: ["CrawlCore", .product(name: "Kanna", package: "Kanna")]
        ),

        // SQLite crawl packages, batched writer, table/overview queries.
        .target(
            name: "Storage",
            dependencies: ["CrawlCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),

        // Issue catalogue, per-page rules and post-crawl SQL analysis.
        .target(
            name: "Audit",
            dependencies: [
                "CrawlCore", "Parsing", "Storage",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Comparing one crawl with another.
        .target(
            name: "Compare",
            dependencies: ["Storage", "Audit", .product(name: "GRDB", package: "GRDB.swift")]
        ),

        // Scheduled crawls, installed as launchd user agents.
        .target(
            name: "Scheduling",
            dependencies: ["CrawlCore", "Storage", "Crawler", "Compare", "Export", "Rendering", "Lighthouse"]
        ),

        // ClickUp.
        .target(
            name: "Integrations",
            dependencies: ["CrawlCore", "Storage", "Audit", .product(name: "GRDB", package: "GRDB.swift")]
        ),

        // JavaScript rendering with a pool of offscreen WKWebViews.
        .target(name: "Rendering", dependencies: ["CrawlCore"]),

        // Crawl orchestration: frontier, scheduling, robots cache, page processing.
        .target(
            name: "Crawler",
            dependencies: [
                "CrawlCore", "Parsing", "Storage", "Audit", "Rendering",
                .product(name: "DequeModule", package: "swift-collections"),
            ]
        ),

        // Lighthouse speed reports, run locally with a bundled Node and the Mac's own Chrome.
        .target(name: "Lighthouse", dependencies: ["CrawlCore", "Storage", "Audit"]),

        // CSV and XLSX exports.
        .target(
            name: "Export",
            dependencies: [
                "Storage", "Audit", "Rendering", "Integrations",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "libxlsxwriter", package: "libxlsxwriter"),
            ]
        ),

        // The local web server behind the browser UI, the menu-bar item and the self-updater.
        .target(
            name: "Server",
            dependencies: [
                "CrawlCore", "Storage", "Audit", "Crawler", "Export", "Integrations", "Compare", "Scheduling",
                "Rendering", "Lighthouse", "WebAssets",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // The built web UI, embedded so the app is one self-contained binary. Regenerated from
        // Web/dist by Tools/Release/embed-web.swift; the committed copy is a placeholder page.
        .target(name: "WebAssets"),

        // The one executable: the menu-bar app and server by default, and every command-line tool.
        .executableTarget(
            name: "crawlspace",
            dependencies: [
                "Crawler", "Export", "Audit", "Integrations", "Compare", "Scheduling", "Lighthouse", "Server",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ] + testTargets
)
