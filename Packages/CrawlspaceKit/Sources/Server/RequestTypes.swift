import CrawlCore
import Export
import Foundation
import Scheduling

// Request and response bodies for the routes. They live here rather than inside the route
// closures, where Swift 6.4's compiler crashes on them.

struct ConfigBody: Decodable { var config: CrawlConfig }

struct RowDataBody: Decodable {
    var ids: [Int64]
    var columns: [String]
}

struct LookupResult: Encodable, Sendable { var id: Int64? }

struct ReportBody: Decodable {
    var title: String?
    var clientName: String?
    var preparedBy: String?
    var notes: String?
    var accent: String?
    /// A PNG or JPEG, base64-encoded.
    var logo: String?
    var maxIssues: Int?
    var examplesPerIssue: Int?
    var format: String?
}

struct LighthouseBody: Decodable {
    var top: Int?
    var rowIds: [Int64]?
}

struct AboutDTO: Encodable, Sendable {
    var version: String
    var commit: String
    var update: Updater.State
    var lighthouse: String
    var lighthouseRuntime: String?
    var crawlsFolder: String
    var freeDiskGigabytes: Double?
}

struct SecretBody: Decodable { var value: String }

struct PasswordStatus: Encodable, Sendable { var isSet: Bool }

struct PasswordBody: Decodable {
    var host: String
    var user: String
    var password: String
}

struct ClickUpSpaceChoice: Encodable, Sendable {
    var id: String
    var name: String
    /// Only when there's more than one workspace, to tell two spaces of the same name apart.
    var workspace: String?
}

struct ClickUpListChoice: Encodable, Sendable {
    var id: String
    /// Nil for a list directly in the space.
    var folderName: String?
    var listName: String
}

struct ClickUpDestinationDTO: Encodable, Sendable {
    var site: String
    var destination: ClickUpDestination?
}

struct ClickUpProgress: Encodable, Sendable {
    var title: String
    var fraction: Double
}

struct RobotsFetchBody: Decodable { var site: String }

struct RobotsFetched: Encodable, Sendable {
    var robotsURL: String
    var statusCode: Int
    var text: String
}

struct RobotsTestBody: Decodable {
    var site: String
    var robots: String
    var urls: [String]
    var userAgent: String
}

struct RobotsVerdict: Encodable, Sendable {
    var url: String
    var allowed: Bool
    var rule: String?
    var line: Int?
}

struct ScheduleDTO: Codable, Sendable {
    var schedule: ScheduledCrawl
    var description: String
    var installed: Bool
}
