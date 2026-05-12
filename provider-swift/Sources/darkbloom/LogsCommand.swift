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

    /// Replace the current process with `tail -f`. Uses execv so Ctrl-C
    /// behaves like tail rather than passing through Swift's signal layer.
    private func execTail(path: URL, lines: Int) throws {
        let argv: [String] = [
            "tail",
            "-f",
            "-n", "\(lines)",
            path.path,
        ]
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

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
