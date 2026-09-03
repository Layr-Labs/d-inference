import Foundation
import Darwin
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

private let cliIntegrationTestsEnabled: Bool = {
    guard let value = ProcessInfo.processInfo.environment[
        "DARKBLOOM_CLI_INTEGRATION_TESTS"
    ] else {
        return false
    }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
}()

@Suite(
    "CLI dispatch (integration)",
    .enabled(
        if: cliIntegrationTestsEnabled,
        "set DARKBLOOM_CLI_INTEGRATION_TESTS=1 to run real-binary CLI tests"))
struct CLIDispatchTests {
    /// Path to the `darkbloom` executable built alongside this test bundle.
    private var binary: URL {
        let anchor = Bundle(for: BundleAnchor.self).bundleURL
        let productsDir = anchor.pathExtension == "xctest"
            ? anchor.deletingLastPathComponent()
            : anchor
        return productsDir.appendingPathComponent("darkbloom")
    }

    /// Runs the built binary hermetically: HOME points at a throwaway directory so
    /// the subprocess can never read — or migrate/rewrite — a real provider config
    /// on the host, and the update banner is disabled to keep the run offline.
    private func run(_ args: [String], home: URL) throws -> CLIInvocation {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw CLIIntegrationTestError.missingBinary(binary)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        try process.run()
        guard completion.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw CLIIntegrationTestError.timedOut(arguments: args, seconds: 15)
        }
        process.waitUntilExit()

        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        return CLIInvocation(
            output: output,
            terminationReason: process.terminationReason,
            terminationStatus: process.terminationStatus)
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
        let invocation = try run(["status", "--config", config], home: home)
        #expect(invocation.terminationReason == .exit)
        #expect(
            invocation.terminationStatus == 0,
            "`status` exited with \(invocation.terminationStatus). Got:\n\(invocation.output)")
        #expect(
            !invocation.output.contains("USAGE: darkbloom status"),
            Comment(rawValue:
                "`status` printed its help instead of running — async-dispatch regression "
                    + "(main.swift). Got:\n\(invocation.output)"))
        #expect(
            invocation.output.contains("Coordinator:"),
            "`status` did not produce a status report. Got:\n\(invocation.output)"
        )
    }

    /// A bare invocation should still show the root help with the subcommand list.
    @Test func bareInvocationShowsRootHelp() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let invocation = try run([], home: home)
        #expect(invocation.terminationReason == .exit)
        #expect(
            invocation.terminationStatus == 0,
            Comment(rawValue:
                "bare invocation exited with \(invocation.terminationStatus). Got:\n"
                    + invocation.output))
        #expect(invocation.output.contains("SUBCOMMANDS"))
        #expect(invocation.output.contains("status"))
    }
}

private struct CLIInvocation {
    let output: String
    let terminationReason: Process.TerminationReason
    let terminationStatus: Int32
}

private enum CLIIntegrationTestError: Error {
    case missingBinary(URL)
    case timedOut(arguments: [String], seconds: Int)
}
