import CryptoKit
import Foundation
import HostRuntimeCoordination
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeInstallerBootTests: XCTestCase {
    func testNativeExitAndFreshRuntimeReplayNeverStartTwiceOrUseSSH() async throws {
        let f = try fixture(); defer { f.remove() }
        let authority = try f.vm.makeTestHostRuntimeAuthority()
        var lease: HostRuntimeLease? = try authority.acquireSandbox()
        var runtime: LumeVirtualMachineRuntime? = try f.vm.makeRuntime(hostRuntimeLease: lease)
        let request = try request(f)
        let first = try await runtime!.runInstaller(request)
        XCTAssertFalse(first.replayed); XCTAssertEqual(first.nativeExitCode, 0); XCTAssertTrue(first.sourceStopped)
        XCTAssertEqual(try String(contentsOf: f.vm.directory.appendingPathComponent("run-env"), encoding: .utf8), "installer-v1\n4\n3\n")
        let arguments = try String(contentsOf: f.vm.directory.appendingPathComponent("run-args"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("--display\nnone\n--vnc\ndisabled"))
        for argument in ["--mount", "--disk", "--shared-dir", "--network", "--detach"] { XCTAssertFalse(arguments.contains(argument)) }
        runtime = nil; lease = nil
        let recovered = try f.vm.makeRuntime(hostRuntimeLease: authority.acquireSandbox())
        let replay = try await recovered.runInstaller(request)
        XCTAssertTrue(replay.replayed); XCTAssertNil(replay.nativeExitCode); XCTAssertTrue(replay.sourceStopped)
        XCTAssertEqual(try String(contentsOf: f.vm.directory.appendingPathComponent("spawn-count"), encoding: .utf8), "x\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.directory.appendingPathComponent("ssh-called").path))
    }

    func testClaimBeforeSpawnIsConsumedAndBlocksLegacyStartAndNewStaging() async throws {
        let f = try fixture(); defer { f.remove() }
        let request = try request(f)
        try LumeInstallerBootClaim.publish(request, name: f.vm.virtualMachineName, storage: f.vm.storage)
        let runtime = try f.vm.makeRuntime(hostRuntimeLease: f.vm.makeTestHostRuntimeAuthority().acquireSandbox())
        let outcome = try await runtime.runInstaller(request)
        XCTAssertTrue(outcome.replayed); XCTAssertFalse(outcome.observedRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.directory.appendingPathComponent("spawn-count").path))
        do { try await runtime.start(name: f.vm.virtualMachineName); XCTFail("legacy start must not restart the installer") }
        catch { XCTAssertTrue(String(describing: error).contains("recovery path")) }
        XCTAssertThrowsError(try f.acquire(), "new root staging must refuse a claimed installer attempt")
    }

    func testCancellationStopsOwnerAndPreservesConsumedClaim() async throws {
        let f = try fixture(behavior: "block"); defer { f.remove() }
        let runtime = try f.vm.makeRuntime(hostRuntimeLease: f.vm.makeTestHostRuntimeAuthority().acquireSandbox())
        let request = try request(f)
        let task = Task { try await runtime.runInstaller(request) }
        let started = await waitForSpawn(f)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must remain visible") } catch {}
        XCTAssertTrue(started)
        XCTAssertTrue(try LumeInstallerBootClaim.existsMatching(request, name: f.vm.virtualMachineName, storage: f.vm.storage))
        let state = try await runtime.inspect(name: f.vm.virtualMachineName)
        XCTAssertEqual(state?.state, .stopped)
        let replay = try await runtime.runInstaller(request)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(try String(contentsOf: f.vm.directory.appendingPathComponent("spawn-count"), encoding: .utf8), "x\n")
    }

    func testChangedDiskOrRuntimeCannotClaimOrStart() async throws {
        for changedDisk in [false, true] {
            let f = try fixture(); defer { f.remove() }
            let request = try request(f, runtimeSHA: changedDisk ? nil : String(repeating: "a", count: 64))
            if changedDisk {
                let file = try FileHandle(forWritingTo: f.image)
                try file.write(contentsOf: Data("changed".utf8)); try file.close()
            }
            let runtime = try f.vm.makeRuntime(hostRuntimeLease: f.vm.makeTestHostRuntimeAuthority().acquireSandbox())
            do { _ = try await runtime.runInstaller(request); XCTFail("changed inputs must be rejected") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.virtualMachineDirectory.appendingPathComponent(LumeInstallerBootClaim.fileName).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.directory.appendingPathComponent("spawn-count").path))
        }
    }

    func testNativeFailureAndDifferentPermitCannotTriggerRetry() async throws {
        let f = try fixture(behavior: "fail"); defer { f.remove() }
        let runtime = try f.vm.makeRuntime(hostRuntimeLease: f.vm.makeTestHostRuntimeAuthority().acquireSandbox())
        let request = try request(f)
        do { _ = try await runtime.runInstaller(request); XCTFail("failed native owner must fail") }
        catch let error as SandboxRuntimeError {
            guard case .commandFailed(_, let status, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(status, 42)
        }
        let different = LumeInstallerBootRequest(reservationData: request.reservationData, stagedDisk: request.stagedDisk,
            runtimeSHA256: request.runtimeSHA256, maximumBootSeconds: 300, permitSHA256: String(repeating: "c", count: 64))
        do { _ = try await runtime.runInstaller(different); XCTFail("a changed permit must not reuse this attempt") } catch {}
        let replay = try await runtime.runInstaller(request)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(try String(contentsOf: f.vm.directory.appendingPathComponent("spawn-count"), encoding: .utf8), "x\n")
    }

    private func fixture(behavior: String = "normal") throws -> LumeRootSourceTestFixture {
        try .init(scriptOverride: Self.script, behavior: behavior)
    }
    private func request(_ f: LumeRootSourceTestFixture, runtimeSHA: String? = nil) throws -> LumeInstallerBootRequest {
        let sha = try runtimeSHA ?? SHA256.hash(data: Data(contentsOf: f.vm.executable)).map { String(format: "%02x", $0) }.joined()
        return .init(reservationData: f.reservation, stagedDisk: f.disk, runtimeSHA256: sha,
            maximumBootSeconds: 300, permitSHA256: String(repeating: "b", count: 64))
    }
    private func waitForSpawn(_ f: LumeRootSourceTestFixture) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: f.vm.directory.appendingPathComponent("run-started").path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static let script = #"""
    #!/bin/sh
    set -eu
    root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    state="$root/state"
    case "$1" in
      --version) printf '0.5.3\n' ;;
      ls) printf '[{"name":"sandbox-failure-test","os":"macOS","cpuCount":4,"memorySize":8589934592,"diskSize":{"total":107374182400},"status":"%s"}]\n' "$(cat "$state")" ;;
      run)
        test -f "$root/vms/sandbox-failure-test/.darkbloom-installer-boot.json" || exit 78
        printf '%s\n' "$@" > "$root/run-args"
        printf '%s\n' "${DARKBLOOM_VM_PROFILE-}" "${DARKBLOOM_HOST_RUNTIME_FD-}" "${DARKBLOOM_LUME_LIFECYCLE_FD-}" > "$root/run-env"
        test "${DARKBLOOM_VM_PROFILE-}" = installer-v1 || exit 79
        test -r /dev/fd/4 && test -r /dev/fd/3 || exit 80
        printf 'x\n' >> "$root/spawn-count"
        trap 'printf "stopped\n" > "$state"' EXIT
        printf 'running\n' > "$state"
        : > "$root/run-started"
        case "$(cat "$root/behavior")" in
          fail) exit 42 ;;
          block) cat <&3 >/dev/null ;;
          *) sleep 0.4 ;;
        esac
        ;;
      stop) printf 'stopped\n' > "$state" ;;
      ssh) : > "$root/ssh-called"; exit 81 ;;
      *) exit 64 ;;
    esac
    """#
}
