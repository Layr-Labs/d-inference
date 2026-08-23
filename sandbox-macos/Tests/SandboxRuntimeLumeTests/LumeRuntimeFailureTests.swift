import CryptoKit
import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
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

    func testCancelledCreateRemovesNamedAndTemporaryArtifacts() async throws {
        let fixture = try FakeLumeFixture(
            initialState: nil,
            behavior: "block-create"
        )
        defer { fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let specification = try SandboxVirtualMachineSpecification(
            name: fixture.virtualMachineName,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .restoreImage(
                url: fixture.restoreImage,
                unattendedPreset: "tahoe"
            ),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )
        let create = Task {
            try await runtime.create(specification)
        }
        try await fixture.waitForCreateToStart()
        create.cancel()

        do {
            try await create.value
            XCTFail("cancelled create should throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.storage
                    .appendingPathComponent(fixture.virtualMachineName)
                    .path
            )
        )
        let operations = fixture.storage
            .appendingPathComponent(
                LumeRuntimeWorkspace.supportDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                LumeRuntimeWorkspace.operationsDirectoryName,
                isDirectory: true
            )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: operations.path),
            []
        )
    }
}

private struct FakeLumeFixture {
    let directory: URL
    let executable: URL
    let storage: URL
    let state: URL
    let behavior: URL
    let createStarted: URL
    let restoreImage: URL
    let virtualMachineName = "sandbox-failure-test"

    init(
        writeProvenance: Bool = true,
        initialState: String? = "stopped",
        behavior: String = "normal"
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-fake-lume-\(UUID().uuidString)",
            isDirectory: true
        )
        executable = directory.appendingPathComponent("lume")
        storage = directory.appendingPathComponent("vms", isDirectory: true)
        state = directory.appendingPathComponent("state")
        self.behavior = directory.appendingPathComponent("behavior")
        createStarted = directory.appendingPathComponent("create-started")
        restoreImage = directory.appendingPathComponent("restore.ipsw")
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
        if let initialState {
            try Data("\(initialState)\n".utf8).write(to: state)
            try FileManager.default.createDirectory(
                at: storage.appendingPathComponent(
                    virtualMachineName,
                    isDirectory: true
                ),
                withIntermediateDirectories: false
            )
        }
        try Data("\(behavior)\n".utf8).write(to: self.behavior)
        try Data().write(to: restoreImage)
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

    func waitForCreateToStart() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if FileManager.default.fileExists(atPath: createStarted.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.createStartTimeout
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
    behavior="$(tr -d '\\n' < "$root/behavior")"
    command="${1:-}"
    case "$command" in
      --version)
        printf '%s\\n' "0.5.3"
        ;;
      ls)
        storage=""
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --storage)
              storage="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        if [ ! -f "$state_file" ] || [ ! -d "$storage/sandbox-failure-test" ]; then
          printf '%s\\n' '[]'
          exit 0
        fi
        state="$(tr -d '\\n' < "$state_file")"
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
      create)
        name="$2"
        shift 2
        storage=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --storage)
              storage="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        test -n "$storage"
        mkdir -p "$storage/$name"
        printf '%s\\n' "provisioning" > "$state_file"
        operation_root="$(dirname "${XDG_CONFIG_HOME:?}")"
        mkdir -p "$operation_root/temporary-vms/fake-install"
        : > "$root/create-started"
        if [ "$behavior" = "block-create" ]; then
          while :; do :; done
        fi
        rm -rf "$operation_root/temporary-vms/fake-install"
        printf '%s\\n' "stopped" > "$state_file"
        ;;
      delete)
        name="$2"
        shift 2
        storage=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --storage)
              storage="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        rm -rf "$storage/$name"
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
    case createStartTimeout
}
