import ArgumentParser
import Foundation
import ProviderCore

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show provider logs from macOS unified logging.",
        discussion: """
        Streams live logs from macOS unified logging \
        (subsystem: \(subsystem)) by default.

        Use --last to show a historical window (e.g. 1h, 30m, 24h). Combine \
        --last with --follow to print that history first and then keep \
        tailing live output.

        Use --debug to include debug-level messages (excluded by default), \
        or --file to read the legacy log file at \(LaunchAgent.logPath().path).
        """
    )

    @Flag(name: [.long], help: "Read from the legacy log file instead of unified logging.")
    var file = false

    @Flag(name: [.short, .long], help: "Stream new log lines as they appear.")
    var follow = false

    @Option(name: [.long], help: "Show historical logs for the given duration (e.g. 1h, 30m, 24h).")
    var last: String?

    @Flag(name: [.long], help: "Include debug-level log messages (unified logging only).")
    var debug = false

    @Option(name: [.short, .long], help: "Number of lines to show (only applies with --file).")
    var lines: Int = 50

    private static let subsystem = "dev.darkbloom.provider"
    private static let predicate = #"subsystem == "\#(subsystem)""#

    mutating func run() async throws {
        await runUpdateBannerIfEnabled()

        if file {
            try runFileMode()
        } else if let duration = last {
            if follow {
                try execLogShowThenStream(duration: duration)
            } else {
                try execLogShow(duration: duration)
            }
        } else {
            try execLogStream()
        }
    }

    // MARK: - Unified Logging argv (pure, testable)

    /// Builds the argv for a historical `log show` invocation. Pure with no
    /// side effects so it can be unit tested. argv[0] is the program name
    /// (`log`) as required by `execv`. Passing `debug: true` appends `--debug`
    /// so debug-level messages are included alongside `--info`.
    static func showArgv(predicate: String, duration: String, debug: Bool) -> [String] {
        var argv = [
            "log", "show",
            "--predicate", predicate,
            "--style", "ndjson",
            "--info",
            "--last", duration,
        ]
        if debug {
            argv.append("--debug")
        }
        return argv
    }

    /// Builds the argv for a live `log stream` invocation. Pure with no side
    /// effects so it can be unit tested. `log stream` has no `--last`; the
    /// level gates verbosity instead — `--level debug` includes info+debug,
    /// `--level info` is the non-debug default. argv[0] is the program name
    /// (`log`) as required by `execv`.
    static func streamArgv(predicate: String, debug: Bool) -> [String] {
        [
            "log", "stream",
            "--predicate", predicate,
            "--style", "ndjson",
            "--level", debug ? "debug" : "info",
        ]
    }

    // MARK: - Unified Logging exec

    private func execLogStream() throws {
        try execLog(argv: Self.streamArgv(predicate: Self.predicate, debug: debug))
    }

    private func execLogShow(duration: String) throws {
        try execLog(
            argv: Self.showArgv(predicate: Self.predicate, duration: duration, debug: debug)
        )
    }

    /// `--last` + `--follow`: emit the historical window first (a finite
    /// `log show`), then exec into a live `log stream`. `log stream` does not
    /// support `--last`, so the two phases must run as separate processes.
    ///
    /// Default signal handling is restored up front: SIG_IGN (set by
    /// ArgumentParser's async runtime) is inherited across spawn and exec,
    /// which would otherwise make both the historical `log show` child and the
    /// final streamed exec ignore Ctrl-C.
    private func execLogShowThenStream(duration: String) throws {
        restoreDefaultSignalHandling()
        try runLogToCompletion(
            argv: Self.showArgv(predicate: Self.predicate, duration: duration, debug: debug)
        )
        try execLogStream()
    }

    /// Runs `/usr/bin/log` to completion with stdout/stderr/stdin inherited so
    /// the user sees output directly. Used for the historical phase of
    /// `--last --follow` before switching to the live stream.
    private func runLogToCompletion(argv: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        // argv[0] is the program name; Process wants only the trailing args.
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput

        do {
            try process.run()
        } catch {
            printError("failed to run log: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        process.waitUntilExit()

        // Mirror `--last` alone: if the historical `log show` failed (e.g. a
        // malformed duration), surface its exit status instead of silently
        // proceeding to the live stream.
        if process.terminationStatus != 0 {
            throw ExitCode(process.terminationStatus)
        }
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
