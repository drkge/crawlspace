import Audit
import CrawlCore
import Foundation
import Storage

/// Runs the Lighthouse CLI on one page at a time.
///
/// Lighthouse measures timing, so two runs side by side slow each other down and both report a
/// worse score than the page deserves. Pages are measured one after another.
public struct LighthouseRunner: Sendable {
    public let toolchain: LighthouseToolchain
    public var timeoutSeconds: Int

    public init(toolchain: LighthouseToolchain, timeoutSeconds: Int = 120) {
        self.toolchain = toolchain
        self.timeoutSeconds = timeoutSeconds
    }

    public struct Output: Sendable {
        public var report: LighthouseReport
        public var html: Data?
    }

    /// Measures one page as one device. `headers` go with every request the page makes — the
    /// crawl's cookie, custom headers and basic auth — so authenticated sites can be measured.
    public func run(url: String, device: LighthouseDevice, headers: [String: String] = [:]) async throws -> Output {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(path: "crawlspace-lighthouse-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: folder) }

        var chromeFlags = ["--no-first-run", "--no-default-browser-check", "--disable-extensions",
                           "--user-data-dir=\(folder.appending(path: "profile").path)"]
        if !toolchain.chromeIsHeadlessShell { chromeFlags.insert("--headless=new", at: 0) }

        var arguments = [
            toolchain.cli.path, url,
            "--only-categories=performance",
            "--output=json", "--output=html",
            "--output-path=\(folder.appending(path: "report").path)",
            "--quiet",
            "--max-wait-for-load=45000",
            "--chrome-flags=\(chromeFlags.joined(separator: " "))",
        ]
        if device == .desktop { arguments.append("--preset=desktop") }
        if !headers.isEmpty {
            // A file rather than the command line, which anyone on the Mac can read with ps.
            let headersFile = folder.appending(path: "headers.json")
            fileManager.createFile(atPath: headersFile.path, contents: try JSONEncoder().encode(headers),
                                   attributes: [.posixPermissions: 0o600])
            arguments.append("--extra-headers=\(headersFile.path)")
        }

        let process = Process()
        process.executableURL = toolchain.node
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CHROME_PATH"] = toolchain.chrome.path
        process.environment = environment
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let status = try await Self.runToCompletion(process, timeoutSeconds: timeoutSeconds)
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        let jsonURL = folder.appending(path: "report.report.json")
        guard let json = try? Data(contentsOf: jsonURL) else {
            let lastLine = stderr.split(whereSeparator: \.isNewline).last.map(String.init)
            throw LighthouseError.failed(lastLine ?? "Lighthouse exited with code \(status) and wrote no report.")
        }
        let report = try LighthouseReport(json: json)
        let html = try? Data(contentsOf: folder.appending(path: "report.report.html"))
        return Output(report: report, html: html)
    }

    /// Waits for the process, stopping it on timeout or when the task is cancelled.
    private static func runToCompletion(_ process: Process, timeoutSeconds: Int) async throws -> Int32 {
        let state = ProcessState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { finished in
                    state.finish(continuation, with: state.reason.map { .failure($0) }
                                 ?? .success(finished.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    state.finish(continuation, with: .failure(LighthouseError.failed(error.localizedDescription)))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                    if process.isRunning {
                        state.reason = .timedOut(timeoutSeconds)
                        stop(process)
                    }
                }
            }
        } onCancel: {
            state.reason = .cancelled
            stop(process)
        }
    }

    /// SIGINT first: Lighthouse catches it and closes the Chrome it launched. SIGTERM would leave
    /// that Chrome running.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Shared between the process's termination handler, the timeout and cancellation.
private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var _reason: LighthouseError?

    var reason: LighthouseError? {
        get { lock.withLock { _reason } }
        set { lock.withLock { _reason = newValue } }
    }

    func finish(_ continuation: CheckedContinuation<Int32, any Error>, with result: Result<Int32, any Error>) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        if first { continuation.resume(with: result) }
    }
}
