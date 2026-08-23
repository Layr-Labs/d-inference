import CryptoKit
import Darwin
import Foundation
import SandboxRuntime
import SandboxRuntimeLume
import XCTest

final class LumeRuntimeFailureTests: XCTestCase {
    func testRejectsRuntimeWithoutAuditedProvenance() async throws {
        let fixture = try FakeLumeFixture(writeProvenance: false)
        defer { fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            _ = try await runtime.capabilities()
            XCTFail("runtime without provenance should be rejected")
        } catch let error as SandboxRuntimeError {
            guard case .unsupported(let detail) = error else {
                return XCTFail("expected unsupported runtime, got \(error)")
            }
            XCTAssertTrue(detail.contains("provenance"))
        }
    }

    func testRejectsRuntimeChangedAfterValidation() async throws {
        let fixture = try FakeLumeFixture()
        defer { fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let capabilities = try await runtime.capabilities()
        XCTAssertEqual(
            capabilities.version,
            LumeRuntimeConfiguration.pinnedVersion
        )
        let handle = try FileHandle(forWritingTo: fixture.executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        do {
            _ = try await runtime.capabilities()
            XCTFail("changed runtime should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume runtime changed after validation")
            )
        }
    }

    func testFailedReadinessStopsNewlyStartedVirtualMachine() async throws {
        let fixture = try FakeLumeFixture()
        defer { fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.start(name: fixture.virtualMachineName)
            XCTFail("guest that never becomes ready should time out")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationTimedOut(
                    "\(fixture.virtualMachineName) guest readiness"
                )
            )
        }
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(
            state,
            .stopped
        )
    }

    func testCancelledStartStopsNewlyStartedVirtualMachine() async throws {
        let fixture = try FakeLumeFixture()
        defer { fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let start = Task {
            try await runtime.start(name: fixture.virtualMachineName)
        }
        try await fixture.waitForState("running")
        start.cancel()

        do {
            try await start.value
            XCTFail("cancelled start should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        let state = try await runtime.inspect(
            name: fixture.virtualMachineName
        )?.state
        XCTAssertEqual(
            state,
            .stopped
        )
    }
}

private struct FakeLumeFixture {
    let directory: URL
    let executable: URL
    let storage: URL
    let state: URL
    let virtualMachineName = "sandbox-failure-test"

    init(writeProvenance: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-fake-lume-\(UUID().uuidString)",
            isDirectory: true
        )
        executable = directory.appendingPathComponent("lume")
        storage = directory.appendingPathComponent("vms", isDirectory: true)
        state = directory.appendingPathComponent("state")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("stopped\n".utf8).write(to: state)
        try Data(Self.script.utf8).write(to: executable)
        guard chmod(executable.path, 0o755) == 0 else {
            throw POSIXError(.EACCES)
        }
        if writeProvenance {
            try Self.writeProvenance(
                beside: executable,
                binaryDigest: Self.sha256(of: executable)
            )
        }
    }

    func makeRuntime(
        commandTimeoutSeconds: UInt32 = 1
    ) throws -> LumeVirtualMachineRuntime {
        LumeVirtualMachineRuntime(configuration: try LumeRuntimeConfiguration(
            executable: executable,
            storageDirectory: storage,
            commandTimeoutSeconds: commandTimeoutSeconds,
            createTimeoutSeconds: commandTimeoutSeconds
        ))
    }

    func waitForState(_ expected: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            let contents = try? String(contentsOf: state, encoding: .utf8)
            let value = contents?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if value == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.stateTimeout(expected)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeProvenance(
        beside executable: URL,
        binaryDigest: String
    ) throws {
        let object: [String: Any] = [
            "schema_version": 1,
            "repository": LumeRuntimeConfiguration.pinnedRepository,
            "commit": LumeRuntimeConfiguration.pinnedCommit,
            "source_path": LumeRuntimeConfiguration.pinnedSourcePath,
            "version": LumeRuntimeConfiguration.pinnedVersion,
            "binary_sha256": binaryDigest,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try data.write(
            to: executable
                .deletingLastPathComponent()
                .appendingPathComponent("lume.provenance.json")
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let script = """
    #!/bin/sh
    set -eu
    root="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
    state_file="$root/state"
    state="$(tr -d '\\n' < "$state_file")"
    command="${1:-}"
    case "$command" in
      --version)
        printf '%s\\n' "0.5.3"
        ;;
      ls)
        ready=false
        if [ "$state" = "ready" ]; then
          ready=true
          state=running
        fi
        printf '[{"name":"sandbox-failure-test","cpuCount":4,'
        printf '"memorySize":8589934592,"diskSize":{"total":107374182400},'
        printf '"status":"%s","sshAvailable":%s}]\\n' "$state" "$ready"
        ;;
      run)
        printf '%s\\n' "running" > "$state_file"
        ;;
      stop)
        printf '%s\\n' "stopped" > "$state_file"
        ;;
      delete)
        rm -f "$state_file"
        ;;
      *)
        printf '%s\\n' "unsupported fake Lume command: $command" >&2
        exit 64
        ;;
    esac
    """
}

private enum FakeLumeFixtureError: Error {
    case stateTimeout(String)
}
