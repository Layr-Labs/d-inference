import ArgumentParser
import Foundation
import ProviderCore

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show provider logs from macOS unified logging.",
        discussion: """
        Streams live logs from macOS unified logging \
        (subsystem: \(subsystem)) by default.

        Use --last to show historical logs, or --file to read the \
        legacy log file at \(LaunchAgent.logPath().path).
        """
    )

    @Flag(name: [.long], help: "Read from the legacy log file instead of unified logging.")
    var file = false

    @Flag(name: [.short, .long], help: "Stream new log lines as they appear.")
    var follow = false

    @Option(name: [.long], help: "Show historical logs for the given duration (e.g. 1h, 30m, 24h).")
    var last: String?

    @Option(name: [.short, .long], help: "Number of lines to show (only applies with --file).")
    var lines: Int = 50

    private static let subsystem = "dev.darkbloom.provider"
    private static let predicate = #"subsystem == "\#(subsystem)""#

    mutating func run() async throws {
        await runUpdateBannerIfEnabled()

        if file {
            try runFileMode()
        } else if let duration = last {
            try execLogShow(duration: duration)
        } else {
            try execLogStream()
        }
    }

    // MARK: - Unified Logging

    private func execLogStream() throws {
        try execLog(argv: [
            "log", "stream",
            "--predicate", Self.predicate,
            "--style", "ndjson",
            "--level", "info",
        ])
    }

    private func execLogShow(duration: String) throws {
        try execLog(argv: [
            "log", "show",
            "--predicate", Self.predicate,
            "--style", "ndjson",
            "--info",
            "--last", duration,
        ])
    }

    /// Replace the current process with `/usr/bin/log`. Restores default
    /// signal handling before exec because ArgumentParser's async
    /// infrastructure sets SIG_IGN on SIGINT, and SIG_IGN is preserved
    /// across execv — causing the child to ignore Ctrl-C.
    private func execLog(argv: [String]) throws {
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

        restoreDefaultSignalHandling()

        let rc = "/usr/bin/log".withCString { execPath in
            cArgs.withUnsafeBufferPointer { argvBuf -> Int32 in
                execv(execPath, argvBuf.baseAddress!)
            }
        }
        if rc == -1 {
            let errnoMsg = String(cString: strerror(errno))
            printError("failed to exec log: \(errnoMsg)")
            throw ExitCode.failure
        }
    }

    // MARK: - Legacy File Mode

    private func runFileMode() throws {
        let path = LaunchAgent.logPath()

        guard FileManager.default.fileExists(atPath: path.path) else {
            print("No log file at \(path.path)")
            print("Start the provider first: darkbloom start")
            return
        }

        if follow {
            try execTail(path: path, lines: lines)
        } else {
            try printLastLines(path: path, lines: lines)
        }
    }

    private func printLastLines(path: URL, lines: Int) throws {
        let content = try String(contentsOf: path, encoding: .utf8)
        let allLines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, allLines.count - lines)
        for line in allLines[start..<allLines.count] {
            print(line)
        }
    }

    private func execTail(path: URL, lines: Int) throws {
        let argv: [String] = [
            "tail", "-f",
            "-n", "\(lines)",
            path.path,
        ]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

        restoreDefaultSignalHandling()

        let rc = "/usr/bin/tail".withCString { execPath in
            cArgs.withUnsafeBufferPointer { argvBuf -> Int32 in
                execv(execPath, argvBuf.baseAddress!)
            }
        }
        if rc == -1 {
            let errnoMsg = String(cString: strerror(errno))
            printError("failed to exec tail: \(errnoMsg)")
            throw ExitCode.failure
        }
    }

    // MARK: - Helpers

    /// Restores default signal dispositions before exec. SIG_IGN (set by
    /// GCD signal sources in ArgumentParser's async runtime) is preserved
    /// across exec, unlike custom handlers which are reset to SIG_DFL.
    private func restoreDefaultSignalHandling() {
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)

        var mask = sigset_t()
        sigemptyset(&mask)
        sigaddset(&mask, SIGINT)
        sigaddset(&mask, SIGTERM)
        pthread_sigmask(SIG_UNBLOCK, &mask, nil)
    }
}
