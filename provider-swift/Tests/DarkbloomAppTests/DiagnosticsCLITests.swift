import Foundation
import Testing
@testable import DarkbloomApp

@Suite("diagnostics CLI compatibility")
struct DiagnosticsCLITests {
    private let failedReport = Data(#"{"schema":1,"version":"test","checks":[{"id":"metal","section":"hardware","title":"Metal","status":"fail","detail":"test failure"}],"verdict":{"status":"fail","failures":1,"warnings":0}}"#.utf8)

    @Test("unsupported JSON flag is a software compatibility error, not a hardware result")
    func unsupportedFlagWithTrailingHelp() async throws {
        let fixture = try DiagnosticsScriptFixture(body: #"""
        printf '%s\n' "Error: Unknown option '--json'" >&2
        printf '%s\n' 'Usage: darkbloom doctor [--support]' >&2
        printf '%s\n' 'See darkbloom doctor --help for more information.' >&2
        exit 64
        """#)
        defer { fixture.remove() }
        do {
            _ = try await fixture.runner.runDoctorJSON()
            Issue.record("expected CLI compatibility failure")
        } catch let error as DiagnosticsCLIError {
            #expect(error == .incompatibleCLI)
            #expect(error.localizedDescription.contains("Update the provider"))
            #expect(!error.localizedDescription.contains("--help"))
            #expect(!error.localizedDescription.contains("Apple silicon"))
        }
    }

    @Test("parser diagnostics on either output stream retain typed compatibility", arguments: [
        "Error: Unknown option '--json'",
        "Error: Unrecognized option '--json'",
        "Error: Unexpected argument '--json'",
    ])
    func parserOutputStreams(_ message: String) throws {
        for stdout in [true, false] {
            do {
                _ = try ProcessDiagnosticsCLIRunner.decodeReport(
                    exitStatus: 64,
                    stdout: stdout ? Data(message.utf8) : Data(),
                    stderr: stdout ? Data() : Data(message.utf8))
                Issue.record("expected CLI compatibility failure")
            } catch let error as DiagnosticsCLIError {
                #expect(error == .incompatibleCLI)
            }
        }
    }

    @Test("a valid failing report wins over exit status and incidental stderr")
    func validReportWinsOverExitStatus() throws {
        let report = try ProcessDiagnosticsCLIRunner.decodeReport(
            exitStatus: 1,
            stdout: failedReport,
            stderr: Data("Error: Unknown option '--json'".utf8))
        #expect(report.verdict.failures == 1)
        #expect(report.checks.first?.id == "metal")
    }

    @Test("process errors retain technical details without displaying usage or loader text")
    func processFailureHasActionableCopy() throws {
        let detail = "dyld: Library not loaded: /private/provider/lib.dylib\nSee darkbloom doctor --help"
        do {
            _ = try ProcessDiagnosticsCLIRunner.decodeReport(
                exitStatus: 9, stdout: Data(), stderr: Data(detail.utf8))
            Issue.record("expected a process error")
        } catch let error as DiagnosticsCLIError {
            #expect(error == .exited(9, message: detail))
            #expect(error.localizedDescription.contains("system check"))
            #expect(error.localizedDescription.contains("update the provider"))
            #expect(!error.localizedDescription.contains("dyld"))
            #expect(!error.localizedDescription.contains("--help"))
        }
    }

    @Test("unrelated argument failures are not misclassified as missing JSON support")
    func unrelatedOptionFailure() throws {
        let detail = "Error: Unknown option '--other'\nUsage: darkbloom doctor --json"
        do {
            _ = try ProcessDiagnosticsCLIRunner.decodeReport(
                exitStatus: 64, stdout: Data(), stderr: Data(detail.utf8))
            Issue.record("expected a process error")
        } catch let error as DiagnosticsCLIError {
            #expect(error == .exited(64, message: detail))
        }
    }

    @Test("success without a JSON report asks for a provider update")
    func unreadableSuccessIsNotAHealthReport() throws {
        for stdout in [Data(), Data("Darkbloom doctor\nPASS".utf8)] {
            do {
                _ = try ProcessDiagnosticsCLIRunner.decodeReport(
                    exitStatus: 0, stdout: stdout, stderr: Data())
                Issue.record("expected an unreadable-report error")
            } catch let error as DiagnosticsCLIError {
                #expect(error == .undecodable)
                #expect(error.localizedDescription.contains("Update the provider"))
            }
        }
    }

    @Test("newer report schemas ask for an app update")
    func newerSchemaRequiresAppUpdate() throws {
        let report = String(decoding: failedReport, as: UTF8.self)
            .replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#)
        do {
            _ = try ProcessDiagnosticsCLIRunner.decodeReport(
                exitStatus: 1, stdout: Data(report.utf8), stderr: Data())
            Issue.record("expected an unsupported schema")
        } catch let error as DiagnosticsCLIError {
            #expect(error == .unsupportedSchema(2))
            #expect(error.localizedDescription.contains("Update the Darkbloom app"))
        }
    }

    @Test("launch failures return a typed reinstall action and cleanup reaches EOF")
    func missingExecutableIsLaunchFailure() async throws {
        let fixture = try DiagnosticsScriptFixture(body: "exit 0")
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.executable)
        do {
            _ = try await fixture.runner.runDoctorJSON()
            Issue.record("expected a launch failure")
        } catch let error as DiagnosticsCLIError {
            guard case .launchFailed = error else {
                Issue.record("unexpected diagnostic error: \(error)")
                return
            }
            #expect(error.localizedDescription.contains("reinstall"))
        }
    }
}

private struct DiagnosticsScriptFixture {
    let directory: URL
    let executable: URL

    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-cli-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("darkbloom")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    var runner: ProcessDiagnosticsCLIRunner {
        ProcessDiagnosticsCLIRunner(locator: DiagnosticsScriptLocator(url: executable))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct DiagnosticsScriptLocator: DarkbloomCLILocating {
    let url: URL
    func locate() -> URL? { url }
}
