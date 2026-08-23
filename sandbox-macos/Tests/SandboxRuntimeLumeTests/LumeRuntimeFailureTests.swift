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
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            _ = try await runtime.capabilities()
            XCTFail("runtime without provenance should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume provenance cannot be opened")
            )
        }
    }

    func testValidatesAuditedRuntimeInSystemTemporaryDirectory() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }

        let capabilities = try await fixture.makeRuntime().capabilities()

        XCTAssertEqual(
            capabilities.version,
            LumeRuntimeConfiguration.pinnedVersion
        )
    }

    func testProductionRejectsSelfAuthenticatedAdHocRuntime() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = LumeVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: fixture.executable,
                storageDirectory: fixture.storage,
                commandTimeoutSeconds: 1,
                createTimeoutSeconds: 1,
                trustPolicy: .production
            )
        )

        do {
            _ = try await runtime.capabilities()
            XCTFail("production must reject an ad-hoc self-authenticated runtime")
        } catch let error as SandboxRuntimeError {
            guard case .unsupported(let detail) = error else {
                XCTFail("expected unsupported signature error, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("production signature"))
        }
    }

    func testRejectsProvenanceWithUnpinnedPatchDigest() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        try fixture.replacePatchDigest(String(repeating: "0", count: 64))

        do {
            _ = try await fixture.makeRuntime().capabilities()
            XCTFail("runtime with an unpinned patch digest should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume provenance does not match the audited pin")
            )
        }
    }

    func testSuppressesDependencyDiagnosticsForMachineReadableOutput() async throws {
        let fixture = try FakeLumeFixture(behavior: "log-info-on-list")
        defer { try? fixture.remove() }

        let records = try await fixture.makeRuntime().list()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.name, fixture.virtualMachineName)
        XCTAssertEqual(records.first?.state, .stopped)
    }

    func testFixtureCleanupRemovesReadOnlyRuntimeTree() throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let directory = fixture.directory

        try fixture.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRejectsRuntimeChangedAfterValidation() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let capabilities = try await runtime.capabilities()
        XCTAssertEqual(
            capabilities.version,
            LumeRuntimeConfiguration.pinnedVersion
        )
        guard chmod(fixture.executable.path, 0o755) == 0 else {
            throw POSIXError(.EACCES)
        }
        let handle = try FileHandle(forWritingTo: fixture.executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        guard chmod(fixture.executable.path, 0o555) == 0 else {
            throw POSIXError(.EACCES)
        }

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

    func testRejectsRuntimeTreeEntryAddedAfterValidation() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()
        _ = try await runtime.capabilities()

        guard chmod(fixture.runtimeDirectory.path, 0o755) == 0 else {
            throw POSIXError(.EACCES)
        }
        let injected = fixture.runtimeDirectory.appendingPathComponent(
            "injected-resource"
        )
        try Data("untrusted".utf8).write(to: injected)
        guard chmod(injected.path, 0o444) == 0,
              chmod(fixture.runtimeDirectory.path, 0o555) == 0
        else {
            throw POSIXError(.EACCES)
        }

        do {
            _ = try await runtime.capabilities()
            XCTFail("an added runtime tree entry should be rejected")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported("Lume runtime changed after validation")
            )
        }
    }

    func testFailedReadinessStopsNewlyStartedVirtualMachine() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
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
        defer { try? fixture.remove() }
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
        defer { try? fixture.remove() }
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

    func testDeleteRemovesStoppedOwnedVirtualMachine() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        try await runtime.delete(name: fixture.virtualMachineName)

        let record = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertNil(record)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testDeleteMissingVirtualMachineIsIdempotent() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        try await runtime.delete(name: fixture.virtualMachineName)
        try await runtime.delete(name: fixture.virtualMachineName)

        let record = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertNil(record)
    }

    func testDeleteRefusesRunningVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.delete(name: fixture.virtualMachineName)
            XCTFail("a running VM must not be deleted")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "refusing to delete VM \(fixture.virtualMachineName) while state is running"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testDeleteRequiresOwnershipMarker() async throws {
        let fixture = try FakeLumeFixture()
        defer { try? fixture.remove() }
        try FileManager.default.removeItem(at: fixture.ownershipMarker)
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.delete(name: fixture.virtualMachineName)
            XCTFail("an unowned VM must not be deleted")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .unsupported(
                    "VM \(fixture.virtualMachineName) is not owned by Darkbloom"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testDeleteFailsClosedWhenVirtualMachineRemainsListed() async throws {
        let fixture = try FakeLumeFixture(behavior: "delete-noop")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        do {
            try await runtime.delete(name: fixture.virtualMachineName)
            XCTFail("delete must verify the VM disappeared")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .malformedOutput(
                    "Lume delete completed but VM still exists"
                )
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    func testSeparateRuntimesCannotCreateSameVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(
            initialState: nil,
            behavior: "block-create"
        )
        defer { try? fixture.remove() }
        let firstRuntime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let secondRuntime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let specification = try SandboxVirtualMachineSpecification(
            name: fixture.virtualMachineName,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .restoreImage(
                url: fixture.restoreImage,
                unattendedPreset: "tahoe"
            ),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )
        let firstCreate = Task {
            try await firstRuntime.create(specification)
        }
        try await fixture.waitForCreateToStart()

        do {
            try await secondRuntime.create(specification)
            XCTFail("a second runtime must not enter the same VM operation")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(
                error,
                .operationInProgress(
                    name: fixture.virtualMachineName,
                    operation: "create"
                )
            )
        }

        firstCreate.cancel()
        do {
            try await firstCreate.value
            XCTFail("cancelled create should throw")
        } catch is CancellationError {
        }
    }

    func testOwnershipWriteReplacesMarkerInheritedFromClone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-ownership-replacement-\(UUID().uuidString)",
            isDirectory: true
        )
        let name = "sandbox-clone"
        let virtualMachineDirectory = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: virtualMachineDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineOwnership.fileName
        )
        try Data("inherited-template-marker".utf8).write(to: marker)
        let specification = try SandboxVirtualMachineSpecification(
            name: name,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: .localTemplate(name: "sandbox-base"),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )

        try LumeVirtualMachineOwnership.write(
            specification: specification,
            to: virtualMachineDirectory
        )

        XCTAssertTrue(
            LumeVirtualMachineOwnership.matches(
                specification: specification,
                in: root
            )
        )
    }
}

private struct FakeLumeFixture {
    let directory: URL
    let runtimeDirectory: URL
    let executable: URL
    let storage: URL
    let state: URL
    let behavior: URL
    let createStarted: URL
    let restoreImage: URL
    let virtualMachineName = "sandbox-failure-test"

    var virtualMachineDirectory: URL {
        storage.appendingPathComponent(
            virtualMachineName,
            isDirectory: true
        )
    }

    var ownershipMarker: URL {
        virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineOwnership.fileName
        )
    }

    var provenanceFile: URL {
        runtimeDirectory.appendingPathComponent("lume.provenance.json")
    }

    init(
        writeProvenance: Bool = true,
        initialState: String? = "stopped",
        behavior: String = "normal"
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-fake-lume-\(UUID().uuidString)",
            isDirectory: true
        )
        runtimeDirectory = directory.appendingPathComponent(
            "runtime",
            isDirectory: true
        )
        executable = runtimeDirectory.appendingPathComponent("lume")
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
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if let initialState {
            try Data("\(initialState)\n".utf8).write(to: state)
            let virtualMachineDirectory = storage.appendingPathComponent(
                virtualMachineName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: virtualMachineDirectory,
                withIntermediateDirectories: false
            )
            try Self.writeOwnershipMarker(
                to: virtualMachineDirectory,
                name: virtualMachineName
            )
        }
        try Data("\(behavior)\n".utf8).write(to: self.behavior)
        try Data().write(to: restoreImage)
        try Data(Self.script.utf8).write(to: executable)
        guard chmod(executable.path, 0o555) == 0 else {
            throw POSIXError(.EACCES)
        }
        if writeProvenance {
            try Self.writeProvenance(
                beside: executable,
                binaryDigest: Self.sha256(of: executable)
            )
        }
        guard chmod(runtimeDirectory.path, 0o555) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    func makeRuntime(
        commandTimeoutSeconds: UInt32 = 1
    ) throws -> LumeVirtualMachineRuntime {
        LumeVirtualMachineRuntime(configuration: try LumeRuntimeConfiguration(
            executable: executable,
            storageDirectory: storage,
            commandTimeoutSeconds: commandTimeoutSeconds,
            createTimeoutSeconds: commandTimeoutSeconds,
            trustPolicy: .developmentAdHoc
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

    func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtimeDirectory.path
        )
        try FileManager.default.removeItem(at: directory)
    }

    func replacePatchDigest(_ digest: String) throws {
        let data = try Data(contentsOf: provenanceFile)
        guard var object = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any]
        else {
            throw POSIXError(.EINVAL)
        }
        object["patches"] = [
            LumeRuntimeConfiguration.pinnedPatchPath: digest
        ]
        let replacement = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard chmod(provenanceFile.path, 0o644) == 0 else {
            throw POSIXError(.EACCES)
        }
        let handle = try FileHandle(forWritingTo: provenanceFile)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()
        guard chmod(provenanceFile.path, 0o444) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    private static func writeProvenance(
        beside executable: URL,
        binaryDigest: String
    ) throws {
        let object: [String: Any] = [
            "schema_version": 3,
            "repository": LumeRuntimeConfiguration.pinnedRepository,
            "commit": LumeRuntimeConfiguration.pinnedCommit,
            "source_path": LumeRuntimeConfiguration.pinnedSourcePath,
            "version": LumeRuntimeConfiguration.pinnedVersion,
            "patches": [
                LumeRuntimeConfiguration.pinnedPatchPath:
                    LumeRuntimeConfiguration.pinnedPatchSHA256
            ],
            "directories": [],
            "files": ["lume": binaryDigest],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let destination = executable
            .deletingLastPathComponent()
            .appendingPathComponent("lume.provenance.json")
        try data.write(
            to: destination
        )
        guard chmod(destination.path, 0o444) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    private static func writeOwnershipMarker(
        to virtualMachineDirectory: URL,
        name: String
    ) throws {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "installationID": UUID().uuidString,
            "name": name,
            "cpuCount": 4,
            "memoryBytes": 8 * 1_024 * 1_024 * 1_024,
            "diskBytes": 100 * 1_024 * 1_024 * 1_024,
            "sourceKind": "local_template",
            "sourceReference": "base",
        ]
        let destination = virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineOwnership.fileName
        )
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let script = """
    #!/bin/sh
    set -eu
    root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
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
        if [ "$behavior" = "log-info-on-list" ] && [ "${LUME_LOG_LEVEL:-info}" != "error" ]; then
          printf '%s\\n' '[2026-08-23T02:50:37Z] INFO: dependency diagnostic'
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
        trap 'printf "%s\\n" "stopped" > "$state_file"; exit 0' EXIT HUP INT TERM
        printf '%s\\n' "running" > "$state_file"
        while IFS= read -r current_state < "$state_file"; do
          if [ "$current_state" = "stopped" ]; then
            exit 0
          fi
        done
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
        if [ "$behavior" = "delete-noop" ]; then
          exit 0
        fi
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
