import Audit
import CrawlCore
import Crawler
import Export
import Foundation
import Hummingbird
import Integrations
import Lighthouse
import Scheduling
import Storage

/// Everything that isn't one crawl: ClickUp, the robots.txt tester, schedules, settings,
/// Lighthouse's runtime and updates.
struct MiscRoutes {
    let library: Library
    let updater: Updater
    /// The binary launchd runs for scheduled crawls: the installed app's, which survives updates.
    let scheduleExecutable: String

    func register(on router: Router<AppContext>) {
        router.get("api/health") { _, _ in
            JSON(["status": "ok", "version": AppVersion.current])
        }

        router.get("api/defaults") { _, _ in
            JSON(CrawlConfig())
        }

        router.get("api/events") { _, _ in
            eventStream(library.events)
        }

        router.get("api/about") { _, _ in
            return JSON(AboutDTO(version: AppVersion.current, commit: AppVersion.commit, update: await updater.state,
                              lighthouse: Self.describe(LighthouseToolchain.locate()),
                              lighthouseRuntime: LighthouseToolchain.installedVersion,
                              crawlsFolder: library.directory.path,
                              freeDiskGigabytes: Self.freeDiskGigabytes(at: library.directory)))
        }

        // Settings and secrets. Secrets are write-only: the browser learns whether one is set, never what it is.
        router.get("api/settings") { _, _ in
            JSON(SettingsResponse(settings: SettingsStore.load()))
        }
        router.put("api/settings") { request, context in
            let settings = try await request.decodeJSON(Settings.self, context: context)
            try SettingsStore.save(settings)
            return JSON(SettingsResponse(settings: settings))
        }

        // API tokens for other services: one each, so adding one replaces the last.
        router.put("api/tokens/:kind") { request, context in
            let body = try await request.decodeJSON(SecretBody.self, context: context)
            guard let kind = AppTokens.Kind(rawValue: try context.parameters.string("kind")) else {
                throw ServerError.notFound("Unknown token.")
            }
            let value = body.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw ServerError.badRequest("Paste the token first.") }
            try AppTokens.save(value, as: kind)
            return JSON(SettingsResponse(settings: SettingsStore.load()))
        }
        router.post("api/tokens/:kind/check") { _, context in
            guard let kind = AppTokens.Kind(rawValue: try context.parameters.string("kind")) else {
                throw ServerError.notFound("Unknown token.")
            }
            return JSON(await AppTokens.check(kind))
        }
        router.delete("api/tokens/:kind") { _, context in
            guard let kind = AppTokens.Kind(rawValue: try context.parameters.string("kind")) else {
                throw ServerError.notFound("Unknown token.")
            }
            AppTokens.remove(kind)
            return JSON(SettingsResponse(settings: SettingsStore.load()))
        }

        // Basic-auth passwords for crawls, stored apart from the crawl's settings.
        router.get("api/crawl-password") { request, _ in
            guard let host = request.query("host"), let user = request.query("user") else {
                throw ServerError.badRequest("Which site and user?")
            }
            return JSON(PasswordStatus(isSet: CredentialStore.password(account: CredentialStore.account(host: host, username: user)) != nil))
        }
        router.put("api/crawl-password") { request, context in
            let body = try await request.decodeJSON(PasswordBody.self, context: context)
            let account = CredentialStore.account(host: body.host, username: body.user)
            if body.password.isEmpty {
                CredentialStore.delete(account: account)
            } else {
                try CredentialStore.save(password: body.password, account: account)
            }
            return Response(status: .noContent)
        }

        registerClickUp(on: router)
        registerRobots(on: router)
        registerSchedules(on: router)

        router.get("api/update") { _, _ in JSON(await updater.state) }
        router.post("api/update/check") { _, _ in
            await updater.check(userInitiated: true)
            return JSON(await updater.state)
        }
        router.post("api/update/apply") { _, _ in
            try await updater.applyIfIdle(force: true)
            return JSON(await updater.state)
        }
    }

    struct SettingsResponse: Encodable, Sendable {
        var settings: Settings
        /// Every service's token, masked so the token itself never reaches the browser.
        var tokens: [AppTokens.Entry]

        init(settings: Settings) {
            self.settings = settings
            tokens = AppTokens.entries()
        }
    }

    /// Big crawls take a lot of room, so the start page warns when it's short.
    static func freeDiskGigabytes(at url: URL) -> Double? {
        let folder = FileManager.default.fileExists(atPath: url.path) ? url : FileManager.default.homeDirectoryForCurrentUser
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Double($0) / 1_000_000_000 }
    }

    static func describe(_ status: LighthouseToolchain.Status) -> String {
        switch status {
        case .ready(let toolchain): toolchain.chromeIsHeadlessShell ? "Ready (Chrome for Testing)" : "Ready (\(toolchain.chrome.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent))"
        case .missingRuntime: "Not set up yet: Node and Lighthouse arrive with the next update check"
        case .missingChrome: "Waiting for a headless Chrome, which downloads with the next update check"
        }
    }

    // MARK: - ClickUp

    private func registerClickUp(on router: Router<AppContext>) {
        // Every space in every workspace, for choosing where a site's issues go.
        router.get("api/clickup/spaces") { _, _ in
            let client = try clickUp()
            var spaces: [ClickUpSpaceChoice] = []
            let workspaces = try await client.workspaces()
            for workspace in workspaces {
                for space in try await client.spaces(workspace: workspace.id) {
                    spaces.append(ClickUpSpaceChoice(id: space.id, name: space.name,
                                                     workspace: workspaces.count > 1 ? workspace.name : nil))
                }
            }
            return JSON(spaces)
        }

        // Every list in a space, in its folder or directly in the space, for each severity's picker.
        router.get("api/clickup/spaces/:space/lists") { _, context in
            let client = try clickUp()
            let space = try context.parameters.string("space")
            var choices: [ClickUpListChoice] = []
            for folder in try await client.folders(space: space) {
                var lists = folder.lists ?? []
                if lists.isEmpty { lists = try await client.lists(folder: folder.id) }
                choices += lists.map { ClickUpListChoice(id: $0.id, folderName: folder.name, listName: $0.name) }
            }
            choices += try await client.lists(space: space).map { ClickUpListChoice(id: $0.id, folderName: nil, listName: $0.name) }
            return JSON(choices)
        }

        // Where this crawl's site last went, so a rescan goes to the same place.
        router.get("api/crawls/:id/clickup/destination") { _, context in
            let store = try await library.session(context.parameters.string("id")).store
            let site = Self.site(of: try store.loadConfig())
            return JSON(ClickUpDestinationDTO(site: site, destination: SettingsStore.load().clickUpDestinations[site]))
        }

        router.post("api/crawls/:id/clickup/plan") { request, context in
            let options = try await request.decodeJSON(ClickUpRequest.self, context: context)
            let store = try await library.session(context.parameters.string("id")).store
            return JSON(MessageDTO(message: ClickUpPlan.describe(counts: try store.issueCounts(), request: options)))
        }

        router.post("api/crawls/:id/clickup/export") { request, context in
            let body = try await request.decodeJSON(ClickUpRequest.self, context: context)
            let destination = body.destination
            guard !destination.spaceID.isEmpty else { throw ServerError.badRequest("Choose a space to file into.") }
            for severity in Settings.severities(body.severities)
            where destination.target(for: severity).listName.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ServerError.badRequest("Give the \(severity.label.lowercased()) a list to go into.")
            }
            let client = try clickUp()
            let session = try await library.session(context.parameters.string("id"))
            let site = Self.site(of: try session.store.loadConfig())
            _ = try SettingsStore.update {
                $0.clickUpDestinations[site] = destination
                $0.clickUpSeverities = body.severities
                $0.clickUpTableSeverities = body.tableSeverities
                $0.clickUpSubtaskLimit = body.subtaskLimit
            }
            let options = ClickUpExportOptions(
                listID: "",
                severities: Settings.severities(body.severities),
                subtaskLimit: body.subtaskLimit,
                attachFullList: body.attachFullList,
                extraTags: body.extraTag.isEmpty ? [] : [body.extraTag],
                tableSeverities: Settings.severities(body.tableSeverities)
            )
            let store = session.store
            let events = session.events
            let (result, resolved) = try await session.runExport("to ClickUp") {
                try await ClickUpFolderExport.export(store: store, destination: destination, options: options,
                                                     client: client) { title, fraction in
                    events.publish("clickup", ClickUpProgress(title: title, fraction: fraction))
                }
            }
            let places = IssueSeverity.allCases.compactMap { resolved.paths[$0] }.joined(separator: ", ")
            var message = "Filed into \(destination.spaceName) (\(places)): \(result.summary)."
            if !resolved.created.isEmpty {
                message += " Made " + ListFormatter.localizedString(byJoining: resolved.created) + "."
            }
            return JSON(MessageDTO(message: message))
        }
    }

    /// A crawl's site, as ClickUp destinations are remembered by: its start URL's host.
    static func site(of config: CrawlConfig) -> String {
        URL(string: config.startURL)?.host() ?? config.startURL
    }

    private func clickUp() throws -> ClickUpClient {
        guard let token = ClickUpClient.storedToken() else {
            throw ServerError.badRequest("Add your ClickUp API token in Settings first.")
        }
        return ClickUpClient(token: token)
    }

    // MARK: - Robots.txt tester

    private func registerRobots(on router: Router<AppContext>) {
        router.post("api/robots/fetch") { request, context in
            let body = try await request.decodeJSON(RobotsFetchBody.self, context: context)
            guard let base = URLNormalizer.normalize(body.site),
                  let origin = RobotsCache.origin(of: base),
                  let robotsURL = URL(string: origin + "/robots.txt") else {
                throw ServerError.badRequest("Enter a valid http:// or https:// URL.")
            }
            let fetcher = Fetcher(userAgent: "Crawlspace/2.0", timeout: 20, maxConnectionsPerHost: 2, authentication: nil)
            switch await fetcher.fetchFollowingRedirects(robotsURL, body: .always(maxBytes: RobotsTxt.maxBytes)) {
            case .success(let response):
                return JSON(RobotsFetched(robotsURL: robotsURL.absoluteString, statusCode: response.statusCode,
                                    text: response.body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
            case .failure(let failure):
                throw ServerError.unavailable("Couldn't fetch robots.txt: \(failure.label)")
            }
        }

        router.post("api/robots/test") { request, context in
            let body = try await request.decodeJSON(RobotsTestBody.self, context: context)
            let robots = RobotsTxt(body.robots)
            let base = URLNormalizer.normalize(body.site)
            let agent = body.userAgent.isEmpty ? "Crawlspace" : body.userAgent
            let verdicts = body.urls
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { line -> RobotsVerdict in
                    guard let url = URLNormalizer.normalize(line, relativeTo: base) else {
                        return RobotsVerdict(url: line, allowed: true)
                    }
                    let verdict = robots.verdict(for: url, productToken: agent)
                    return RobotsVerdict(url: url.absoluteString, allowed: verdict.allowed,
                                   rule: verdict.rule.map { "\($0.allow ? "Allow" : "Disallow"): \($0.pattern)" },
                                   line: verdict.rule?.line)
                }
            return JSON(verdicts)
        }
    }

    // MARK: - Schedules

    private func registerSchedules(on router: Router<AppContext>) {
        @Sendable func dto(_ schedule: ScheduledCrawl) -> ScheduleDTO {
            ScheduleDTO(schedule: schedule, description: schedule.scheduleDescription,
                        installed: LaunchAgent.isInstalled(schedule))
        }

        router.get("api/schedules") { _, _ in
            JSON(ScheduleStore.load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(dto))
        }

        router.put("api/schedules/:sid") { request, context in
            var schedule = try await request.decodeJSON(ScheduledCrawl.self, context: context)
            guard let id = UUID(uuidString: try context.parameters.string("sid")) else {
                throw ServerError.badRequest("That isn't a schedule id.")
            }
            schedule.id = id
            let errors = schedule.validationErrors()
            guard errors.isEmpty else { throw ServerError.badRequest(errors.joined(separator: " ")) }
            // Keep the run history the browser doesn't send back.
            if let existing = ScheduleStore.load(id: id) {
                schedule.lastRun = existing.lastRun
                schedule.lastSummary = existing.lastSummary
            }
            try ScheduleStore.save(schedule)
            if schedule.isEnabled {
                try LaunchAgent.install(schedule, executable: scheduleExecutable)
            } else {
                LaunchAgent.uninstall(schedule)
            }
            return JSON(dto(schedule))
        }

        router.delete("api/schedules/:sid") { _, context in
            guard let id = UUID(uuidString: try context.parameters.string("sid")),
                  let schedule = ScheduleStore.load(id: id) else { throw ServerError.notFound("No such schedule.") }
            LaunchAgent.uninstall(schedule)
            try ScheduleStore.delete(id: id)
            return Response(status: .noContent)
        }

        router.post("api/schedules/:sid/run") { _, context in
            guard let id = UUID(uuidString: try context.parameters.string("sid")),
                  let schedule = ScheduleStore.load(id: id) else { throw ServerError.notFound("No such schedule.") }
            if !LaunchAgent.isInstalled(schedule) {
                try LaunchAgent.install(schedule, executable: scheduleExecutable)
            }
            try LaunchAgent.runNow(schedule)
            return JSON(MessageDTO(message: "Started \(schedule.name). It runs in the background, and the crawl appears in Recent Crawls."))
        }
    }
}

/// What the ClickUp panel sends: where to file, and how.
struct ClickUpRequest: Decodable, Sendable {
    var destination: ClickUpDestination
    var severities: [String]
    var tableSeverities: [String]
    var subtaskLimit: Int
    var attachFullList: Bool
    var extraTag: String
}

/// How much an export is about to create and how long ClickUp will take to accept it, so nobody
/// finds out afterwards. The same split the exporter makes.
enum ClickUpPlan {
    static func describe(counts: [String: Int], request: ClickUpRequest) -> String {
        let severities = Settings.severities(request.severities)
        let tableSeverities = Settings.severities(request.tableSeverities)
        let limit = request.subtaskLimit
        let chosen = IssueCatalogue.all.filter { severities.contains($0.severity) && (counts[$0.code] ?? 0) > 0 }
        guard !chosen.isEmpty else { return "Nothing to file at these severities." }

        let affected = chosen.reduce(0) { $0 + (counts[$1.code] ?? 0) }
        // Tables for the chosen severities and for anything too big for ClickUp's 1,000 subtasks.
        let isTable = { (definition: IssueDefinition) in
            tableSeverities.contains(definition.severity) || (counts[definition.code] ?? 0) > 1_000
        }
        let tables = chosen.filter(isTable).count
        let subtasks = chosen.filter { !isTable($0) }.reduce(0) { total, definition in
            let count = counts[definition.code] ?? 0
            return total + (limit <= 0 ? count : min(limit, count))
        }
        let csvs = chosen.filter { definition in
            let count = counts[definition.code] ?? 0
            return isTable(definition) ? count > 200 : (limit > 0 && count > limit)
        }.count

        var parts = ["\(chosen.count) tasks"]
        if subtasks > 0 { parts.append("\(subtasks.formatted()) subtasks") }
        if tables > 0 { parts.append("\(tables) as \(tables == 1 ? "a table" : "tables")") }
        if request.attachFullList, csvs > 0 { parts.append("\(csvs) CSV \(csvs == 1 ? "attachment" : "attachments")") }
        var text = parts.joined(separator: ", ") + " — covering \(affected.formatted()) affected URLs."
        if let duration = estimate(requests: chosen.count + subtasks + csvs + 2) {
            text += " About \(duration) on ClickUp's smallest plan, quicker on the larger ones."
        }
        return text
    }

    /// ClickUp allows 100 requests a minute on its smaller plans; Crawlspace paces a little under.
    private static func estimate(requests: Int) -> String? {
        let seconds = Double(requests) / 1.5
        guard seconds >= 60 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        return String(format: "%.1f hours", Double(minutes) / 60)
    }
}
