import Foundation
import Testing

/// Regression test for the v0.6.0 interactive-CLI dispatch bug (#286): every
/// AsyncParsableCommand subcommand printed its own help instead of running, because
/// top-level `main.swift` bound `run()` to the synchronous witness (whose default
/// throws a help request). The bug only manifests in top-level executable scope, so
/// this exercises the REAL built binary rather than calling `run()` directly.
/// Anchor for `Bundle(for:)` — under swift-testing the host process is SwiftPM's
/// testing helper, so `Bundle.main`/`Bundle.allBundles` do not locate the test
/// bundle; resolving via a class in this image does.
private final class BundleAnchor {}

@Suite struct CLIDispatchTests {
    /// Path to the `darkbloom` executable built alongside this test bundle.
    private var binary: URL {
        let anchor = Bundle(for: BundleAnchor.self).bundleURL
        let productsDir = anchor.pathExtension == "xctest"
            ? anchor.deletingLastPathComponent()
            : anchor
        return productsDir.appendingPathComponent("darkbloom")
    }

    /// Runs the built binary hermetically: HOME points at a throwaway directory so
    /// the subprocess can never read or write a real provider config
    /// on the host, and the update banner is disabled to keep the run offline.
    private func run(_ args: [String], home: URL) throws -> String {
        try runWithStatus(args, home: home).output
    }

    private func runWithStatus(_ args: [String], home: URL) throws -> (output: String, status: Int32) {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), proc.terminationStatus)
    }

    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// `darkbloom status` must produce a status report, not degenerate to its help.
    @Test func statusSubcommandRunsInsteadOfPrintingHelp() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Explicit --config under the temp home as a second isolation layer.
        let config = home.appendingPathComponent("provider.toml").path
        let out = try run(["status", "--config", config], home: home)
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
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let out = try run([], home: home)
        #expect(out.contains("SUBCOMMANDS"))
        #expect(out.contains("status"))
    }

    /// `darkbloom --help` is the root help, with a line for each tool shortcut.
    @Test func rootHelpNamesTheToolShortcuts() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let out = try run(["--help"], home: home)
        #expect(out.contains("USAGE: darkbloom <subcommand>"), "Got:\n\(out)")
        #expect(out.contains("  darkbloom --opencode ") && out.contains("  darkbloom --hermes "), "Got:\n\(out)")
    }

    /// `main` makes `darkbloom --opencode` `start --opencode` before it parses: with `--help`, start's help prints,
    /// and nothing starts.
    @Test func toolShortcutParsesAsStart() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (out, status) = try runWithStatus(["--opencode", "--help"], home: home)
        #expect(status == 0)
        #expect(out.contains("USAGE: darkbloom start"), "Got:\n\(out)")
    }

    /// A mistyped tool flag is the root command's usual unknown-option error.
    @Test func mistypedToolFlagIsTheUsualError() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (out, status) = try runWithStatus(["--opencod"], home: home)
        #expect(status == 64)
        #expect(out.contains("Error: Unknown option '--opencod'\nUsage: darkbloom <subcommand>"), "Got:\n\(out)")
    }

    /// Journey 1 (J-10): a refusal a command makes once it runs ended with the root's "Usage: darkbloom <subcommand> /
    /// See 'darkbloom --help'…", which names no step. It ends with its own words, exit 64 as before.
    @Test func aRefusalAfterTheParseEndsWithItsOwnWords() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("provider.toml").path
        let (out, status) = try runWithStatus(["start", "--network", "--opencode", "--config", config], home: home)
        #expect(status == 64)
        #expect(out.contains("Error: This Mac serves only the Darkbloom network, so OpenCode has no local address"), "Got:\n\(out)")
        #expect(!out.contains("Usage: darkbloom <subcommand>") && !out.contains("See 'darkbloom --help'"), "Got:\n\(out)")
    }
}
