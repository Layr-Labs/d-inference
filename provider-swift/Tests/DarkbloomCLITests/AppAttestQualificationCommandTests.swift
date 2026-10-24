import Foundation
import Testing

private final class QualificationBundleAnchor {}

@Suite struct AppAttestQualificationCommandTests {
    @Test func qualificationRequiresBothExplicitOptInsBeforeTouchingInputs() throws {
        for environment in [[:], ["DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION": "1"],
                            ["DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION": "1"]] {
            let result = try run(["--app-attest-qualification-v1", "ws://127.0.0.1:8080/ws/provider", "/must-not-read", "worker-recovery"], environment: environment)
            #expect(result.status == 78)
            #expect(result.output.contains("optInRequired"))
            #expect(!result.output.contains("qualification_started"))
        }
    }

    @Test func qualificationRejectsNonliteralLoopbackAndURLOverrides() throws {
        for url in ["wss://api.darkbloom.dev/ws/provider", "ws://localhost:8080/ws/provider",
                    "ws://127.0.0.1.evil.invalid:8080/ws/provider", "ws://127.0.0.1:8080/other",
                    "ws://user:secret@127.0.0.1:8080/ws/provider", "ws://127.0.0.1:8080/ws/provider?endpoint=other",
                    "ws://127.0.0.1:8080/ws/provider#fragment", "ws://127.0.0.1:80/ws/provider",
                    "ws://2130706433:8080/ws/provider", "ws://[::1]:8080/ws/provider"] {
            let result = try run(["--app-attest-qualification-v1", url, "/must-not-read", "worker-recovery"], environment: enabled)
            #expect(result.status == 78)
            #expect(result.output.contains("loopbackRequired"))
            #expect(!result.output.contains("qualification_started"))
            #expect(!result.output.contains("secret"))
        }
    }

    @Test func qualificationCannotAcceptEndpointKeysPIDsOrSigningHashes() throws {
        for arguments in [
            ["--app-attest-qualification-v1"],
            ["--app-attest-qualification-v1", "ws://127.0.0.1:8080/ws/provider", "/must-not-read", "sign"],
            ["--app-attest-qualification-v1", "ws://127.0.0.1:8080/ws/provider", "/must-not-read", "transport-resumption"],
            ["--app-attest-qualification-v1", "ws://127.0.0.1:8080/ws/provider", "/must-not-read", "worker-recovery", "--pid", "1"],
            ["--app-attest-qualification-v1", "ws://127.0.0.1:8080/ws/provider", "/must-not-read", "worker-recovery", "--endpoint", "anything"],
        ] {
            let result = try run(arguments, environment: enabled)
            #expect(result.status == 78)
            #expect(result.output.contains("invalidArguments"))
        }
    }

    @Test func appKitHostPreservesPreflightBeforeApplicationStartup() throws {
        let arguments = ["--app-attest-qualification-v1", "ws://127.0.0.1:8080/ws/provider", "/must-not-read", "worker-recovery"]
        let absent = try run(arguments, environment: ["DARKBLOOM_NATIVE_APPKIT_QUALIFICATION": "1"])
        #expect(absent.status == 78)
        #expect(absent.output.contains("optInRequired"))
        var environment = enabled
        environment["DARKBLOOM_NATIVE_APPKIT_QUALIFICATION"] = "1"
        let missing = try run(arguments, environment: environment)
        #expect(missing.status == 78)
        #expect(missing.output.contains("privateDirectoryRequired"))
        #expect(!missing.output.contains("appkit_did_finish_launching"))
        #expect(!missing.output.contains("parent_runtime_diagnostics"))
        var remote = arguments
        remote[1] = "wss://api.darkbloom.dev/ws/provider"
        let rejected = try run(remote, environment: environment)
        #expect(rejected.status == 78)
        #expect(rejected.output.contains("loopbackRequired"))
        #expect(!rejected.output.contains("appkit_did_finish_launching"))
    }

    private var enabled: [String: String] {
        ["DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION": "1", "DARKBLOOM_APP_ATTEST_WORKER_QUALIFICATION": "1"]
    }

    private func run(_ arguments: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
        let bundle = Bundle(for: QualificationBundleAnchor.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        let process = Process()
        process.executableURL = products.appendingPathComponent("darkbloom")
        process.arguments = arguments
        process.environment = environment.merging(["PATH": "/usr/bin:/bin", "DARKBLOOM_NO_UPDATE_CHECK": "1"]) { value, _ in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
