import Foundation
import Testing

/// Regression test for the v0.6.0 interactive-CLI dispatch bug (#286): every
/// AsyncParsableCommand subcommand printed its own help instead of running, because
/// top-level `main.swift` bound `run()` to the synchronous witness (whose default
/// throws a help request). The bug only manifests in top-level executable scope, so
/// this exercises the REAL built binary rather than calling `run()` directly.
@Suite struct CLIDispatchTests {
    /// Path to the `darkbloom` executable built alongside this test bundle.
    private var binary: URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("darkbloom")
        }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("darkbloom")
    }

    private func run(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DARKBLOOM_NO_UPDATE_CHECK"] = "1" // keep it offline + deterministic
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `darkbloom status` must produce a status report, not degenerate to its help.
    @Test func statusSubcommandRunsInsteadOfPrintingHelp() throws {
        let out = try run(["status"])
        #expect(
            !out.contains("USAGE: darkbloom status"),
            "`status` printed its help instead of running — async-dispatch regression (main.swift). Got:\n\(out)"
        )
        #expect(
            out.contains("Coordinator:"),
            "`status` did not produce a status report. Got:\n\(out)"
        )
    }

    /// A bare invocation should still show the root help with the subcommand list.
    @Test func bareInvocationShowsRootHelp() throws {
        let out = try run([])
        #expect(out.contains("SUBCOMMANDS"))
        #expect(out.contains("status"))
    }
}
