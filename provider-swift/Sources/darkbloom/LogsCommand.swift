import ArgumentParser
import Foundation
import ProviderCore

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show recent provider logs.",
        discussion: """
        Reads the launchd log file at \(LaunchAgent.logPath().path).
        Use --watch to tail in real time (delegates to /usr/bin/tail).
        """
    )

    @Option(name: [.short, .long], help: "Number of lines to show.")
    var lines: Int = 50

    @Flag(name: [.short, .long], help: "Stream new log lines as they appear (like tail -f).")
    var watch = false

    mutating func run() async throws {
        await runUpdateBannerIfEnabled()

        let path = LaunchAgent.logPath()
        let fm = FileManager.default

        guard fm.fileExists(atPath: path.path) else {
            print("No log file at \(path.path)")
            print("Start the provider first: darkbloom start")
            return
        }

        if watch {
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

    /// Replace the current process with `tail -f`. Restores default signal
    /// handling before exec because ArgumentParser's async infrastructure
    /// sets SIG_IGN on SIGINT (via GCD signal sources), and SIG_IGN is
    /// preserved across execv — causing tail to ignore Ctrl-C.
    private func execTail(path: URL, lines: Int) throws {
        let argv: [String] = [
            "tail",
            "-f",
            "-n", "\(lines)",
            path.path,
        ]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

        // Restore default signal dispositions. SIG_IGN (set by GCD signal
        // sources in ArgumentParser's async runtime) is preserved across
        // exec, unlike custom handlers which are reset to SIG_DFL.
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)

        // Unblock signals in case the Swift concurrency runtime masked them.
        var mask = sigset_t()
        sigemptyset(&mask)
        sigaddset(&mask, SIGINT)
        sigaddset(&mask, SIGTERM)
        pthread_sigmask(SIG_UNBLOCK, &mask, nil)

        // execv replaces the current image; if it returns at all it failed.
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
}
