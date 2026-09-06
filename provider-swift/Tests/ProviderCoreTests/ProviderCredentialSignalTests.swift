import Foundation
import Testing
@testable import ProviderCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// These tests signal a separate test-runner process, never the parent runner
/// or an installed CLI. The child executes the explicit Login signal wrapper
/// and the real publisher with a pause at a real rename boundary; no network or
/// real-home credential access is involved.
@Suite("Credential recovery termination signals", .serialized)
struct ProviderCredentialSignalTests {
    @Test("SIGTERM and SIGINT roll back before exit, including repeated signals during rollback",
          arguments: [SIGTERM, SIGINT], [
              "token-only/after-token-backup", "token-only/before-token-publication",
              "metadata/after-token-backup", "metadata/before-token-publication",
          ])
    func signalsPreserveOriginal(signalNumber: Int32, scenario: String) async throws {
        guard ProcessInfo.processInfo.environment[credentialChildRootKey] == nil else { return }
        try await ProviderCredentialStoreTests().withCredentialFiles { files in
            try AuthTokenStore.save(" original-token\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: files.token.path)
            if scenario.hasPrefix("metadata/") {
                try ProviderAccountStore.save(" original-account\n")
                try ProviderIssuerStore.save(" \n")
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o400], ofItemAtPath: ProviderAccountStore.accountPath().path
                )
            }
            let original = try RecoveryOriginalFiles()
            let child = try launchCredentialRecoveryChild(directory: files.directory, scenario: scenario)
            defer {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }

            try await requireCredentialChildMarker("boundary.ready", in: files.directory, child: child)
            // The pause is after an actual backup/publication rename. The old
            // token really is unpublished here, not merely about to be moved.
            #expect(!FileManager.default.fileExists(atPath: files.token.path))
            #expect(kill(child.processIdentifier, signalNumber) == 0)
            try await requireCredentialChildMarker("rollback.ready", in: files.directory, child: child)
            #expect(!FileManager.default.fileExists(atPath: files.token.path))

            // Keep the wrapper installed while rollback is paused just before
            // restoring the old token. A second signal must not bypass rollback.
            #expect(kill(child.processIdentifier, signalNumber) == 0)
            try Data().write(to: files.directory.appendingPathComponent("rollback.release"))
            try await requireCredentialChildExit(child, in: files.directory)

            #expect(child.terminationReason == .exit)
            #expect(child.terminationStatus == 0)
            #expect(FileManager.default.fileExists(
                atPath: files.directory.appendingPathComponent("cancelled.after-rollback").path
            ))
            #expect(try RecoveryOriginalFiles() == original)
            #expect(throws: ProviderCredentialStoreError.incompleteCredential) {
                try ProviderCredentialStore.authenticationToken(for: "https://fresh.example")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
            #expect(!names.contains { $0.hasSuffix(".pending") || $0.hasSuffix(".original") })
        }
    }

    /// Selected only by the subprocess filter. In normal suite execution this
    /// is a no-op and must not install signal handlers in the parent's process.
    @Test("Child entry for credential signal regression")
    func signaledRecoveryChild() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment[credentialChildRootKey],
              let scenario = environment[credentialChildScenarioKey]
        else { return }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        // Refuse to use fallback credential paths even if the child environment
        // or test filter is accidentally changed.
        try #require(directory.lastPathComponent.hasPrefix("provider-credential-tests-"))
        try #require(AuthTokenStore.tokenPath() == directory.appendingPathComponent("auth_token"))
        try #require(ProviderAccountStore.accountPath() == directory.appendingPathComponent("provider_account"))
        try #require(ProviderIssuerStore.issuerPath() == directory.appendingPathComponent("provider_issuer"))
        if scenario == "concurrent-migration" {
            try Data().write(to: directory.appendingPathComponent("migration.started"))
            let token = AuthTokenStore.load(
                canonicalPath: directory.appendingPathComponent("auth_token"),
                legacyPaths: [directory.appendingPathComponent("retained-legacy-token")]
            )
            try Data((token ?? "<nil>").utf8).write(to: directory.appendingPathComponent("migration.result"))
            return
        }
        let issuer = environment[credentialChildIssuerKey] ?? "https://fresh.example"
        let recovery = try #require(try ProviderCredentialRecovery.prepare(for: issuer))

        do {
            try await DeviceLoginSignalCancellation.run {
                try recovery.publish(token: "fresh-token", accountID: "fresh-account") { source, destination in
                    if source.pathExtension == "original", destination.lastPathComponent == "auth_token" {
                        try Data().write(to: directory.appendingPathComponent("rollback.ready"))
                        // Deliberately ignore task cancellation during rollback,
                        // just as the publisher must, until the parent releases us.
                        try waitForRollbackRelease(in: directory)
                    }
                    guard rename(source.path, destination.path) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    let afterTokenBackup = source.lastPathComponent == "auth_token"
                        && destination.pathExtension == "original"
                    let beforeTokenPublication = source.pathExtension == "pending"
                        && destination.lastPathComponent == "provider_issuer"
                    if (scenario.hasSuffix("after-token-backup") && afterTokenBackup)
                        || ((scenario.hasSuffix("before-token-publication") || scenario == "sigkill-after-metadata")
                            && beforeTokenPublication) {
                        try Data().write(to: directory.appendingPathComponent("boundary.ready"))
                        try waitForSignalCancellation()
                    }
                }
            }
            Issue.record("signalled credential recovery unexpectedly published")
        } catch is CancellationError {
            // This marker is outside the signal wrapper, after it has awaited
            // the publishing task and that task has completed its rollback.
            try Data().write(to: directory.appendingPathComponent("cancelled.after-rollback"))
        }
    }
}

let credentialChildRootKey = "DARKBLOOM_LOGIN_SIGNAL_TEST_ROOT"
let credentialChildScenarioKey = "DARKBLOOM_LOGIN_SIGNAL_TEST_SCENARIO"
let credentialChildIssuerKey = "DARKBLOOM_LOGIN_SIGNAL_TEST_ISSUER"

func launchCredentialRecoveryChild(
    directory: URL, scenario: String, issuer: String = "https://fresh.example"
) throws -> Process {
    let child = Process()
    let arguments = CommandLine.arguments
    let executable = URL(fileURLWithPath: try #require(arguments.first))
    child.executableURL = executable
    var childArguments = [
        "--testing-library", "swift-testing",
        "--filter", "ProviderCredentialSignalTests/signaledRecoveryChild",
    ]
    // Current macOS SwiftPM loads a Mach-O test bundle through this helper;
    // argv[0] is not the test runner itself. Without the bundle argument the
    // helper exits successfully without discovering or executing any tests.
    if executable.lastPathComponent == "swiftpm-testing-helper" {
        let bundleIndex = try #require(arguments.firstIndex(of: "--test-bundle-path"))
        try #require(arguments.indices.contains(bundleIndex + 1))
        childArguments = ["--test-bundle-path", arguments[bundleIndex + 1]] + childArguments
    }
    child.arguments = childArguments
    var environment = ProcessInfo.processInfo.environment
    environment[credentialChildRootKey] = directory.path
    environment[credentialChildScenarioKey] = scenario
    environment[credentialChildIssuerKey] = issuer
    environment["DARKBLOOM_AUTH_TOKEN_PATH"] = directory.appendingPathComponent("auth_token").path
    environment["DARKBLOOM_PROVIDER_ACCOUNT_PATH"] = directory.appendingPathComponent("provider_account").path
    environment["DARKBLOOM_PROVIDER_ISSUER_PATH"] = directory.appendingPathComponent("provider_issuer").path
    environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
    child.environment = environment
    let logPath = directory.appendingPathComponent("child-output.log")
    guard FileManager.default.createFile(atPath: logPath.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let log = try FileHandle(forWritingTo: logPath)
    defer { try? log.close() }
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = log
    child.standardError = log
    try child.run()
    return child
}

func requireCredentialChildMarker(_ name: String, in directory: URL, child: Process) async throws {
    let path = directory.appendingPathComponent(name).path
    for _ in 0..<3_000 {
        if FileManager.default.fileExists(atPath: path) { return }
        guard child.isRunning else {
            throw childFailure(child, in: directory, phase: "before marker \(name)")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw childFailure(child, in: directory, phase: "timed out before marker \(name)")
}

func requireCredentialChildExit(
    _ child: Process, in directory: URL, expectedSignal: Int32? = nil
) async throws {
    for _ in 0..<3_000 {
        if !child.isRunning {
            let expectedReason: Process.TerminationReason = expectedSignal == nil ? .exit : .uncaughtSignal
            guard child.terminationReason == expectedReason, child.terminationStatus == (expectedSignal ?? 0) else {
                throw childFailure(child, in: directory, phase: "after rollback release")
            }
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw childFailure(child, in: directory, phase: "timed out waiting for exit")
}

private func waitForSignalCancellation() throws {
    for _ in 0..<3_000 {
        if Task.isCancelled { return }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw CredentialSignalFailure.timeout("signal cancellation")
}

private func waitForRollbackRelease(in directory: URL) throws {
    let path = directory.appendingPathComponent("rollback.release").path
    for _ in 0..<3_000 {
        if FileManager.default.fileExists(atPath: path) { return }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw CredentialSignalFailure.timeout("rollback release")
}

private func childFailure(_ child: Process, in directory: URL, phase: String) -> CredentialSignalFailure {
    let state = child.isRunning ? "still running"
        : "reason=\(child.terminationReason.rawValue), status=\(child.terminationStatus)"
    let output = (try? String(contentsOf: directory.appendingPathComponent("child-output.log"), encoding: .utf8)) ?? "<no child output>"
    return .subprocess("\(phase): \(state)\nExecutable: \(child.executableURL?.path ?? "<missing>")\nArguments: \(child.arguments ?? [])\nParent arguments: \(CommandLine.arguments)\nChild stdout/stderr:\n\(output)")
}

private enum CredentialSignalFailure: Error, CustomStringConvertible {
    case subprocess(String)
    case timeout(String)

    var description: String {
        switch self {
        case .subprocess(let detail): return detail
        case .timeout(let phase): return "Timed out waiting for \(phase)"
        }
    }
}
