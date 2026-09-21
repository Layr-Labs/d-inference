import Foundation
import Testing
@testable import ProviderCore

@Suite("Security command execution")
struct SecurityCommandRunnerTests {
    @Test("Both output streams are drained beyond pipe capacity")
    func capturesVerboseChild() throws {
        let result = try SecurityCommandRunner.live.run("/bin/sh", ["-c", """
            /usr/bin/head -c 131072 /dev/zero
            /usr/bin/head -c 131072 /dev/zero >&2
            exit 7
            """])
        #expect(result.terminationStatus == 7)
        #expect(result.stdout == String(repeating: "\0", count: 131072))
        #expect(result.stderr == String(repeating: "\0", count: 131072))
    }

    @Test("Launch errors remain errors")
    func launchFailure() {
        #expect(throws: (any Error).self) {
            try SecurityCommandRunner.live.run("/nonexistent/darkbloom-test-command", [])
        }
    }

    @Test("MDM keeps its nonzero-with-output and configured-host policies")
    func enrollmentStatus() {
        let output = "MDM enrollment: Yes\nMDM server: https://coordinator.example/mdm/connect\n"
        let runner = SecurityCommandRunner { path, arguments in
            #expect(path == "/usr/bin/profiles")
            #expect(arguments == ["status", "-type", "enrollment"])
            return SecurityCommandResult(terminationStatus: 1, stdout: output)
        }
        #expect(checkMDMEnrollment(coordinatorURL: "wss://coordinator.example/ws", runner: runner)
            == .enrolledDarkbloom(serverURL: "https://coordinator.example/mdm/connect"))
        #expect(checkMDMEnrollment(runner: runner)
            == .enrolledOtherMDM(serverURL: "https://coordinator.example/mdm/connect"))
        #expect(checkMDMEnrollment(runner: result(status: 1)) == .checkFailed)
        #expect(checkMDMEnrollment(runner: result(status: 0)) == .notEnrolled)
    }

    @Test("Security probes retain their existing output and launch-failure policies")
    func probePolicies() {
        // These diagnostic probes inspect output even when the tool exits nonzero.
        #expect(checkRDMADisabled(runner: result(status: 1, stdout: "disabled\n")))
        #expect(!checkRDMADisabled(runner: result(status: 0, stdout: "enabled")))
        #expect(checkHardenedRuntimeEnabled(runner: result(status: 1, stderr: "flags=0x10000(runtime)")))
        #expect(!checkHardenedRuntimeEnabled(runner: result(status: 0, stdout: "runtime")))
        #expect(systemVolumeHash(runner: result(status: 1,
            stdout: "APFS Snapshot Name: com.apple.os.update-ABC123\n")) == "ABC123")
        let unavailable = SecurityCommandRunner { _, _ in throw CocoaError(.fileNoSuchFile) }
        #expect(checkRDMADisabled(runner: unavailable))
        #expect(!checkHardenedRuntimeEnabled(runner: unavailable))
        #expect(systemVolumeHash(runner: unavailable) == nil)
        #expect(checkMDMEnrollment(runner: unavailable) == .checkFailed)
    }

    @Test("GPU discovery keeps exit-status, fallback and first-named-display policies")
    func gpuDiscoveryPolicies() throws {
        let output = #"{"SPDisplaysDataType":[{"sppci_model":""},{"sppci_model":"Apple M5 Max","sppci_cores":"40","sppci_gpu_core_count":"32"},{"sppci_model":"External GPU","sppci_cores":"99"}]}"#
        let runner = SecurityCommandRunner { path, arguments in
            #expect(path == "/usr/sbin/system_profiler")
            #expect(arguments == ["SPDisplaysDataType", "-json"])
            return SecurityCommandResult(terminationStatus: 0, stdout: output)
        }
        let gpu = try detectGPUInfo(runner: runner, fallback: { "fallback" })
        #expect(gpu.chipName == "Apple M5 Max")
        #expect(gpu.gpuCores == 40)
        for runner in [result(status: 1, stdout: output), result(status: 0, stdout: "invalid"),
                       result(status: 0, stdout: #"{"SPDisplaysDataType":[]}"#)] {
            let gpu = try detectGPUInfo(runner: runner, fallback: { "fallback" })
            #expect(gpu.chipName == "fallback")
            #expect(gpu.gpuCores == 0)
        }
        let legacy = try detectGPUInfo(runner: result(status: 0,
            stdout: #"{"SPDisplaysDataType":[{"sppci_model":"Apple M1","sppci_cores":"invalid","sppci_gpu_core_count":"8"}]}"#),
            fallback: { "fallback" })
        #expect(legacy.gpuCores == 8)
        let unavailable = SecurityCommandRunner { _, _ in throw CocoaError(.fileNoSuchFile) }
        #expect(throws: (any Error).self) {
            try detectGPUInfo(runner: unavailable, fallback: { "fallback" })
        }
    }

    private func result(status: Int32, stdout: String = "", stderr: String = "") -> SecurityCommandRunner {
        SecurityCommandRunner { _, _ in
            SecurityCommandResult(terminationStatus: status, stdout: stdout, stderr: stderr)
        }
    }
}
