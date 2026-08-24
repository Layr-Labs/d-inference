import CryptoKit
import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

struct FakeLumeFixture {
    static let startHolderFixtureEnvironmentKey =
        "DARKBLOOM_LUME_START_HOLDER_FIXTURE"
    static let startHolderNowEnvironmentKey =
        "DARKBLOOM_LUME_START_HOLDER_NOW"

    private let paths: FakeLumeFixturePaths
    let virtualMachineName = "sandbox-failure-test"

    var directory: URL { paths.directory }
    var runtimeDirectory: URL { paths.runtimeDirectory }
    var executable: URL { paths.executable }
    var storage: URL { paths.storage }
    var state: URL { paths.state }
    var behavior: URL { paths.behavior }
    var createStarted: URL { paths.createStarted }
    var listStarted: URL { paths.listStarted }
    var listContinue: URL { paths.listContinue }
    var guestCommandStarted: URL { paths.guestCommandStarted }
    var guestReadinessProbeAttemptsFile: URL {
        paths.guestReadinessProbeAttemptsFile
    }
    var guestReadinessProbeStarted: URL {
        paths.guestReadinessProbeStarted
    }
    var guestReadinessProbeProcessIdentifier: URL {
        paths.guestReadinessProbeProcessIdentifier
    }
    var invalidGuestReadinessProbe: URL {
        paths.invalidGuestReadinessProbe
    }
    var guestExecutorProbeObserved: URL {
        paths.guestExecutorProbeObserved
    }
    var runStarted: URL { paths.runStarted }
    var runContinue: URL { paths.runContinue }
    var runProcessIdentifier: URL { paths.runProcessIdentifier }
    var startIntentObserved: URL { paths.startIntentObserved }
    var startHolderCrash: URL { paths.startHolderCrash }
    var startHolderCrashed: URL { paths.startHolderCrashed }
    var startHolderOutput: URL { paths.startHolderOutput }
    var restoreImage: URL { paths.restoreImage }

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

    var startIntentFile: URL {
        virtualMachineDirectory.appendingPathComponent(
            LumeVirtualMachineStartIntent.fileName
        )
    }

    var provenanceFile: URL {
        runtimeDirectory.appendingPathComponent("lume.provenance.json")
    }

    init(
        writeProvenance: Bool = true,
        initialState: String? = "stopped",
        behavior: String = "normal",
        observedCPUCount: UInt16 = 4,
        observedMemoryBytes: UInt64 =
            8 * SandboxResourcePolicy.gibibyte,
        observedDiskBytes: UInt64 =
            100 * SandboxResourcePolicy.gibibyte
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-fake-lume-\(UUID().uuidString)",
                isDirectory: true
            )
        paths = FakeLumeFixturePaths(directory: directory)
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
            try FileManager.default.createDirectory(
                at: virtualMachineDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.writeOwnershipMarker(
                to: virtualMachineDirectory,
                name: virtualMachineName
            )
        }
        try Data("\(behavior)\n".utf8).write(to: self.behavior)
        try Data("\(observedCPUCount)\n".utf8).write(
            to: paths.observedCPUCount
        )
        try Data("\(observedMemoryBytes)\n".utf8).write(
            to: paths.observedMemoryBytes
        )
        try Data("\(observedDiskBytes)\n".utf8).write(
            to: paths.observedDiskBytes
        )
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

    init(existingDirectory directory: URL) {
        paths = FakeLumeFixturePaths(directory: directory)
    }

    func makeRuntime(
        commandTimeoutSeconds: UInt32 = 1,
        guestReadinessPolicy: LumeGuestReadinessPolicy = .standard
    ) throws -> LumeVirtualMachineRuntime {
        LumeVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: executable,
                storageDirectory: storage,
                commandTimeoutSeconds: commandTimeoutSeconds,
                createTimeoutSeconds: commandTimeoutSeconds,
                trustPolicy: .developmentAdHoc,
                guestCommandPolicy: .baseImagePreparationAndDevelopment
            ),
            guestReadinessPolicy: guestReadinessPolicy
        )
    }

    func makeCapacityArbiter(
        clock: LumeTestWallClock,
        availableStorageBytes:
            @escaping @Sendable () throws -> UInt64 = { UInt64.max }
    ) throws -> SandboxHostCapacityArbiter {
        let storageIdentity = try SandboxStorageVolumeInspector().inspect(
            path: storage
        ).identity
        let arbiter = try SandboxHostCapacityArbiter(
            stateDirectory: directory.appendingPathComponent(
                "capacity",
                isDirectory: true
            ),
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            storageIdentity: storageIdentity,
            currentDate: { clock.now() },
            availableStorageBytes: availableStorageBytes
        )
        _ = try arbiter.initialize()
        _ = try arbiter.setMode(.sandboxDedicated)
        return arbiter
    }

    func makeLeaseFencedRuntime(
        capacityArbiter: SandboxHostCapacityArbiter,
        commandTimeoutSeconds: UInt32 = 5,
        guestCommandPolicy: LumeGuestCommandPolicy = .disabled
    ) throws -> LumeLeaseFencedVirtualMachineRuntime {
        try LumeLeaseFencedVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: executable,
                storageDirectory: storage,
                commandTimeoutSeconds: commandTimeoutSeconds,
                createTimeoutSeconds: commandTimeoutSeconds,
                trustPolicy: .developmentAdHoc,
                guestCommandPolicy: guestCommandPolicy
            ),
            capacityArbiter: capacityArbiter
        )
    }

    func bindOwnership(to scope: SandboxOperationScope) throws {
        try bindOwnership(
            to: scope,
            resources: SandboxResourceSpecification.macOSSmall()
        )
    }

    func bindOwnership(
        to scope: SandboxOperationScope,
        resources: SandboxResourceSpecification,
        diskBytes: UInt64 = 100 * SandboxResourcePolicy.gibibyte
    ) throws {
        try Self.writeOwnershipMarker(
            to: virtualMachineDirectory,
            name: virtualMachineName,
            owner: .init(operationScope: scope),
            resources: resources,
            diskBytes: diskBytes
        )
    }

    @discardableResult
    func persistStartIntent(
        scope: SandboxOperationScope? = nil
    ) throws -> LumeVirtualMachineStartIntent.Intent {
        let owner = LumeVirtualMachineOwnership.Owner(
            operationScope: scope
        )
        let ownership = try LumeVirtualMachineOwnership.requireOwned(
            name: virtualMachineName,
            owner: owner,
            in: storage
        )
        return try LumeVirtualMachineStartIntent.persist(
            name: virtualMachineName,
            ownership: ownership,
            owner: owner,
            initiatingScope: scope,
            in: storage
        )
    }

    var startIntentWasObserved: Bool {
        FileManager.default.fileExists(
            atPath: startIntentObserved.path
        )
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
        try await waitForMarker(
            createStarted,
            timeout: .seconds(5),
            error: .createStartTimeout
        )
    }

    func waitForListToStart() async throws {
        try await waitForMarker(
            listStarted,
            timeout: .seconds(5),
            error: .listStartTimeout
        )
    }

    func allowListToContinue() throws {
        try Data().write(to: listContinue)
    }

    func setBehavior(_ value: String) throws {
        try Data("\(value)\n".utf8).write(to: behavior)
    }

    func resetGuestCommandObservation() throws {
        try FileManager.default.removeItem(at: guestCommandStarted)
    }

    func launchStartHolderSubprocess(now: Date) throws -> Process {
        let testBundle = Bundle(
            for: LumeRuntimeFailureTests.self
        ).bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "SandboxRuntimeLumeTests.LumeRuntimeFailureTests/testUnpublishedStartCrashHolderSubprocess",
            testBundle.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        let inheritedXCTestKeys = environment.keys.filter {
            $0.hasPrefix("XCTest")
        }
        for key in inheritedXCTestKeys {
            environment.removeValue(forKey: key)
        }
        environment[Self.startHolderFixtureEnvironmentKey] = directory.path
        environment[Self.startHolderNowEnvironmentKey] =
            String(now.timeIntervalSince1970)
        process.environment = environment
        guard FileManager.default.createFile(
            atPath: startHolderOutput.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw FakeLumeFixtureError.startHolderOutputUnavailable(
                startHolderOutput.path
            )
        }
        let output = try FileHandle(forWritingTo: startHolderOutput)
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            try? output.close()
            throw error
        }
        try? output.close()
        return process
    }

    func waitForControlledRunToLaunch(
        startHolder: Process
    ) async throws -> pid_t {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        repeat {
            if FileManager.default.fileExists(atPath: runStarted.path),
               let processIdentifier = controlledRunProcessIdentifier,
               Darwin.kill(processIdentifier, 0) == 0,
               startHolder.isRunning
            {
                return processIdentifier
            }
            if !startHolder.isRunning {
                throw FakeLumeFixtureError.runLaunchTimeout(
                    startHolderDiagnostics(startHolder)
                )
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.runLaunchTimeout(
            startHolderDiagnostics(startHolder)
        )
    }

    func crashStartHolder() throws {
        try Data().write(to: startHolderCrash)
    }

    func waitForStartHolderCrash(
        startHolder: Process,
        controlledRunProcessIdentifier: pid_t
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            let crashWasSignaled = FileManager.default.fileExists(
                atPath: startHolderCrashed.path
            )
            if crashWasSignaled, !startHolder.isRunning {
                startHolder.waitUntilExit()
                guard startHolder.terminationReason == .uncaughtSignal,
                      startHolder.terminationStatus == SIGKILL
                else {
                    throw FakeLumeFixtureError.startHolderCrashTimeout(
                        startHolderDiagnostics(startHolder)
                    )
                }
                if Darwin.kill(controlledRunProcessIdentifier, 0) != 0,
                   errno == ESRCH
                {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.startHolderCrashTimeout(
            startHolderDiagnostics(startHolder)
        )
    }

    func allowRunToPublishState() throws {
        try Data().write(to: runContinue)
    }

    func forceControlledRunState(_ value: String) throws {
        try Data("\(value)\n".utf8).write(to: state)
    }

    var controlledRunProcessIdentifier: pid_t? {
        processIdentifier(in: runProcessIdentifier)
    }

    private func startHolderDiagnostics(_ process: Process) -> String {
        let status: String
        if process.isRunning {
            status = "running"
        } else {
            process.waitUntilExit()
            let reason =
                process.terminationReason == .exit
                    ? "exit"
                    : "uncaught-signal"
            status =
                "terminated reason=\(reason) status=\(process.terminationStatus)"
        }
        let outputData = try? Data(contentsOf: startHolderOutput)
        let output = outputData.map {
            String(decoding: $0, as: UTF8.self)
        } ?? "<unavailable>"
        return """
        start holder \(status)
        command: /usr/bin/xcrun xctest -XCTest SandboxRuntimeLumeTests.LumeRuntimeFailureTests/testUnpublishedStartCrashHolderSubprocess \(Bundle(for: LumeRuntimeFailureTests.self).bundleURL.path)
        output:
        \(output.isEmpty ? "<empty>" : output)
        """
    }

    func terminateControlledRunIfNeeded() {
        guard let processIdentifier = controlledRunProcessIdentifier,
              Darwin.kill(processIdentifier, 0) == 0
        else {
            return
        }
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }

    private func waitForMarker(
        _ marker: URL,
        timeout: Duration,
        error: FakeLumeFixtureError
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if FileManager.default.fileExists(atPath: marker.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw error
    }

    var guestCommandWasStarted: Bool {
        FileManager.default.fileExists(atPath: guestCommandStarted.path)
    }

    var guestCommandExecutionAttempts: Int {
        integer(in: paths.guestCommandExecutionAttempts)
    }

    var guestCommandCancellationAttempts: Int {
        integer(in: paths.guestCommandCancellationAttempts)
    }

    var guestCommandExecutionProcessIdentifier: pid_t? {
        processIdentifier(in: paths.guestCommandExecutionProcessIdentifier)
    }

    var guestCommandCancellationProcessIdentifier: pid_t? {
        processIdentifier(in: paths.guestCommandCancellationProcessIdentifier)
    }

    var guestCommandCancellationWasAcknowledged: Bool {
        FileManager.default.fileExists(
            atPath: paths.guestCommandCancellationAcknowledged.path
        )
    }

    func waitForGuestCommandExecutionToStart() async throws -> pid_t {
        try await waitForMarker(
            paths.guestCommandExecutionStarted,
            timeout: .seconds(5),
            error: .guestCommandStartTimeout("execution")
        )
        guard let processIdentifier =
            guestCommandExecutionProcessIdentifier
        else {
            throw FakeLumeFixtureError
                .guestCommandProcessIdentifierUnavailable("execution")
        }
        return processIdentifier
    }

    func waitForGuestCommandCancellationToStart() async throws -> pid_t {
        try await waitForMarker(
            paths.guestCommandCancellationStarted,
            timeout: .seconds(5),
            error: .guestCommandStartTimeout("cancellation")
        )
        guard let processIdentifier =
            guestCommandCancellationProcessIdentifier
        else {
            throw FakeLumeFixtureError
                .guestCommandProcessIdentifierUnavailable("cancellation")
        }
        return processIdentifier
    }

    var stopStateProofWasConsumed: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "stopped-observed"
            ).path
        )
    }

    var runningStateProofWasConsumed: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "running-observed"
            ).path
        )
    }

    var runningStateRegressionWasConsumed: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "running-regressed"
            ).path
        )
    }

    var crossProcessStopWasInvoked: Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                "stop-invoked"
            ).path
        )
    }

    var guestReadinessProbeAttempts: Int {
        integer(in: guestReadinessProbeAttemptsFile)
    }

    var invalidGuestReadinessProbeWasObserved: Bool {
        FileManager.default.fileExists(
            atPath: invalidGuestReadinessProbe.path
        )
    }

    var guestExecutorProbeWasObserved: Bool {
        FileManager.default.fileExists(
            atPath: guestExecutorProbeObserved.path
        )
    }

    func waitForGuestReadinessProbeToStart() async throws -> pid_t {
        try await waitForMarker(
            guestReadinessProbeStarted,
            timeout: .seconds(5),
            error: .guestReadinessProbeStartTimeout
        )
        guard let processIdentifier = processIdentifier(
            in: guestReadinessProbeProcessIdentifier
        ) else {
            throw FakeLumeFixtureError
                .guestCommandProcessIdentifierUnavailable("readiness probe")
        }
        return processIdentifier
    }

    func waitForProcessExit(_ processIdentifier: pid_t) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if kill(processIdentifier, 0) != 0, errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline
        throw FakeLumeFixtureError.processExitTimeout(processIdentifier)
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
        guard var patches = object["patches"] as? [String: String] else {
            throw POSIXError(.EINVAL)
        }
        patches[LumeRuntimeConfiguration.pinnedPatchPath] = digest
        object["patches"] = patches
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

    private func integer(in file: URL) -> Int {
        guard let contents = try? String(
            contentsOf: file,
            encoding: .utf8
        ) else {
            return 0
        }
        return Int(
            contents.trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
    }

    private func processIdentifier(in file: URL) -> pid_t? {
        guard let contents = try? String(
            contentsOf: file,
            encoding: .utf8
        ) else {
            return nil
        }
        return pid_t(
            contents.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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
            "patches": LumeRuntimeConfiguration.pinnedPatches,
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
        name: String,
        owner: LumeVirtualMachineOwnership.Owner = .baseTemplate,
        resources: SandboxResourceSpecification? = nil,
        diskBytes: UInt64 = 100 * SandboxResourcePolicy.gibibyte
    ) throws {
        let committedResources: SandboxResourceSpecification
        if let resources {
            committedResources = resources
        } else {
            committedResources =
                try SandboxResourceSpecification.macOSSmall()
        }
        try LumeVirtualMachineOwnership.write(
            specification: SandboxVirtualMachineSpecification(
                name: name,
                resources: committedResources,
                imageSource: .localTemplate(name: "base"),
                diskBytes: diskBytes,
                diskPolicy: SandboxDiskPolicy(
                    bootDiskBytes: diskBytes...diskBytes
                )
            ),
            owner: owner,
            sourceInstallationID: UUID(),
            to: virtualMachineDirectory
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
        case "$behavior" in
          block-first-list|block-first-list-stop-liveness-inconclusive)
            if [ ! -f "$root/list-started" ]; then
              : > "$root/list-started"
              while [ ! -f "$root/list-continue" ]; do
                /bin/sleep 0.01
              done
            fi
            ;;
        esac
        if [ ! -f "$state_file" ] || [ ! -d "$storage/sandbox-failure-test" ]; then
          printf '%s\\n' '[]'
          exit 0
        fi
        if [ "$behavior" = "log-info-on-list" ] && [ "${LUME_LOG_LEVEL:-info}" != "error" ]; then
          printf '%s\\n' '[2026-08-23T02:50:37Z] INFO: dependency diagnostic'
        fi
        state="$(tr -d '\\n' < "$state_file")"
        cpu_count="$(tr -d '\\n' < "$root/observed-cpu-count")"
        memory_bytes="$(tr -d '\\n' < "$root/observed-memory-bytes")"
        disk_bytes="$(tr -d '\\n' < "$root/observed-disk-bytes")"
        ready=false
        if [ "$state" = "ready" ]; then
          ready=true
          state=running
        elif [ "$state" = "running" ]; then
          case "$behavior" in
            credentialed-readiness-*)
              ready=true
              ;;
          esac
        fi
        if [ "$behavior" = "regress-after-first-stopped-observation" ] \
          && [ "$state" = "stopped" ] \
          && [ -f "$root/stop-completed" ]; then
          if [ -f "$root/stopped-observed" ]; then
            state=unknown
          else
            : > "$root/stopped-observed"
          fi
        fi
        if [ "$behavior" = "credentialed-readiness-regress-after-first-running-observation" ] \
          && [ "$state" = "running" ]; then
          if [ ! -f "$root/running-observed" ]; then
            : > "$root/running-observed"
          elif [ ! -f "$root/running-regressed" ]; then
            : > "$root/running-regressed"
            state=unknown
            ready=false
            cpu_count=5
          fi
        fi
        printf '[{"name":"sandbox-failure-test","cpuCount":%s,' "$cpu_count"
        printf '"memorySize":%s,"diskSize":{"total":%s},' \
          "$memory_bytes" "$disk_bytes"
        printf '"status":"%s","sshAvailable":%s}]\\n' "$state" "$ready"
        if [ "$behavior" = "disable-executable-after-list" ]; then
          chmod 0444 "$0"
        fi
        ;;
      run)
        if [ "$behavior" = "credentialed-readiness-uncooperative" ]; then
          trap '' HUP INT TERM
        else
          trap 'printf "%s\\n" "stopped" > "$state_file"; exit 0' EXIT HUP INT TERM
        fi
        printf '%s\\n' "$$" > "$root/run-pid"
        lifecycle_closed="$root/lifecycle-closed"
        rm -f "$lifecycle_closed"
        lifecycle_fd="${DARKBLOOM_LUME_LIFECYCLE_FD:-}"
        if [ -n "$lifecycle_fd" ] \
          && [ "$behavior" != "credentialed-readiness-uncooperative" ]; then
          (
            eval "/bin/cat <&$lifecycle_fd" >/dev/null 2>&1
            : > "$lifecycle_closed"
          ) &
        fi
        if [ ! -f "$root/vms/sandbox-failure-test/.darkbloom-start-intent.json" ]; then
          printf '%s\\n' "missing durable start intent" >&2
          exit 78
        fi
        : > "$root/start-intent-observed"
        if [ "$behavior" = "hardlink-start-intent-before-running" ]; then
          /bin/ln \
            "$root/vms/sandbox-failure-test/.darkbloom-start-intent.json" \
            "$root/start-intent-alias"
        fi
        if [ "$behavior" = "failed-start-before-state-publication" ]; then
          while :; do
            /bin/sleep 0.01
          done
        fi
        if [ "$behavior" = "pause-run-before-state-publication" ]; then
          holder_pid="$PPID"
          printf '%s\\n' "$$" > "$root/run-pid"
          : > "$root/run-started"
          while [ ! -f "$root/start-holder-crash" ]; do
            /bin/sleep 0.01
          done
          kill -KILL "$holder_pid"
          : > "$root/start-holder-crashed"
          while [ ! -f "$root/run-continue" ]; do
            if [ -f "$lifecycle_closed" ]; then
              exit 0
            fi
            /bin/sleep 0.01
          done
          printf '%s\\n' "starting" > "$state_file"
        fi
        printf '%s\\n' "running" > "$state_file"
        while IFS= read -r current_state < "$state_file"; do
          if [ "$current_state" = "stopped" ] \
            || [ -f "$lifecycle_closed" ]; then
            exit 0
          fi
          /bin/sleep 0.01
        done
        ;;
      ssh)
        : > "$root/guest-command-started"
        encoded_payload="$(printf '%s' "${8:-}" | /usr/bin/cut -d "'" -f 4)"
        decoded_guest_script="$(printf '%s' "$encoded_payload" | /usr/bin/base64 -D)"
        case "$decoded_guest_script" in
          *darkbloom-cancel*)
            guest_command_kind=cancellation
            ;;
          *darkbloom-bootstrap*)
            guest_command_kind=execution
            ;;
          *)
            printf '%s\\n' "unrecognized fake Lume guest command" >&2
            exit 64
            ;;
        esac
        attempts_file="$root/guest-command-$guest_command_kind-attempts"
        attempts=0
        if [ -f "$attempts_file" ]; then
          attempts="$(tr -d '\\n' < "$attempts_file")"
        fi
        attempts=$((attempts + 1))
        printf '%s\\n' "$attempts" > "$attempts_file"
        printf '%s\\n' "$$" > "$root/guest-command-$guest_command_kind-pid"
        : > "$root/guest-command-$guest_command_kind-started"
        if [ "$guest_command_kind" = "cancellation" ]; then
          case "$behavior" in
            guest-command-blocking-cancel-and-stop-failure)
              printf '%s\\n' "simulated cancellation SSH failure" >&2
              exit 69
              ;;
            guest-command-transport-failure|guest-command-timeout)
              command_attempts=0
              if [ -f "$root/guest-readiness-probe-attempts" ]; then
                command_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
              fi
              command_attempts=$((command_attempts + 1))
              printf '%s\\n' "$command_attempts" \
                > "$root/guest-readiness-probe-attempts"
              ;;
          esac
          : > "$root/guest-command-cancellation-acknowledged"
          exit 0
        fi
        case "$behavior" in
          guest-command-success)
            command_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              command_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            command_attempts=$((command_attempts + 1))
            printf '%s\\n' "$command_attempts" \
              > "$root/guest-readiness-probe-attempts"
            printf '%s\\n' '{"magic":"darkbloom_guest_result","schema_version":2,"exit_code":0,"stdout_length":0,"stderr_length":0,"stdout_truncated":false,"stderr_truncated":false,"timed_out":false,"stdout_base64":"","stderr_base64":""}'
            exit 0
            ;;
          guest-command-transport-failure)
            command_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              command_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            command_attempts=$((command_attempts + 1))
            printf '%s\\n' "$command_attempts" \
              > "$root/guest-readiness-probe-attempts"
            printf '%s\\n' "simulated SSH transport failure" >&2
            exit 69
            ;;
          guest-command-timeout)
            command_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              command_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            command_attempts=$((command_attempts + 1))
            printf '%s\\n' "$command_attempts" \
              > "$root/guest-readiness-probe-attempts"
            printf '%s\\n' '{"magic":"darkbloom_guest_result","schema_version":2,"exit_code":124,"stdout_length":0,"stderr_length":0,"stdout_truncated":false,"stderr_truncated":false,"timed_out":true,"stdout_base64":"","stderr_base64":""}'
            exit 0
            ;;
          guest-command-blocking|guest-command-blocking-cancel-and-stop-failure)
            while :; do
              /bin/sleep 0.01
            done
            ;;
          credentialed-readiness-*)
            expected_probe_prefix="/usr/bin/printf '%s' '"
            expected_probe_suffix="' | /usr/bin/base64 -D | /bin/zsh -f"
            valid_probe_command=false
            case "$8" in
              "$expected_probe_prefix"*"$expected_probe_suffix")
                valid_probe_command=true
                ;;
            esac
            if [ "$#" -ne 8 ] \
              || [ "$2" != "sandbox-failure-test" ] \
              || [ "$3" != "--storage" ] \
              || [ "$4" != "$root/vms" ] \
              || [ "$5" != "--timeout" ] \
              || [ "$6" != "35" ] \
              || [ "$7" != "--nio-only" ] \
              || [ "$valid_probe_command" != "true" ] \
              || [ "${LUME_HOME:-}" != "$root/vms/.darkbloom-runtime" ] \
              || [ "${LUME_LOG_LEVEL:-}" != "error" ] \
              || [ "${LUME_TELEMETRY_ENABLED:-}" != "false" ] \
              || [ "${LANG:-}" != "C" ] \
              || [ "${LC_ALL:-}" != "C" ] \
              || [ "${NO_COLOR:-}" != "1" ] \
              || [ "${XDG_CACHE_HOME:-}" != "$root/vms/.darkbloom-runtime/cache" ] \
              || [ "${XDG_CONFIG_HOME:-}" != "$root/vms/.darkbloom-runtime/config" ]; then
              : > "$root/invalid-guest-readiness-probe"
              printf '%s\\n' "invalid credentialed readiness probe" >&2
              exit 64
            fi
            : > "$root/guest-executor-probe-observed"
            probe_attempts=0
            if [ -f "$root/guest-readiness-probe-attempts" ]; then
              probe_attempts="$(tr -d '\\n' < "$root/guest-readiness-probe-attempts")"
            fi
            probe_attempts=$((probe_attempts + 1))
            printf '%s\\n' "$probe_attempts" \
              > "$root/guest-readiness-probe-attempts"
            case "$behavior" in
              credentialed-readiness-transient)
                case "$probe_attempts" in
                  1)
                    printf '%s\\n' "SSH authentication failed" >&2
                    exit 69
                    ;;
                  2)
                    printf '%s\\n' "$$" > "$root/guest-readiness-probe-pid"
                    : > "$root/guest-readiness-probe-started"
                    while :; do :; done
                    ;;
                  3)
                    /bin/dd if=/dev/zero bs=8192 count=1 2>/dev/null
                    exit 0
                    ;;
                esac
                ;;
              credentialed-readiness-blocking)
                printf '%s\\n' "$$" > "$root/guest-readiness-probe-pid"
                : > "$root/guest-readiness-probe-started"
                while :; do :; done
                ;;
              credentialed-readiness-empty-first)
                if [ "$probe_attempts" -eq 1 ]; then
                  exit 0
                fi
                ;;
            esac
            printf '%s\\n' '{"magic":"darkbloom_guest_result","schema_version":2,"exit_code":0,"stdout_length":0,"stderr_length":0,"stdout_truncated":false,"stderr_truncated":false,"timed_out":false,"stdout_base64":"","stderr_base64":""}'
            exit 0
            ;;
        esac
        printf '%s\\n' "unexpected fake Lume guest command" >&2
        exit 64
        ;;
      stop)
        : > "$root/stop-invoked"
        if [ "$behavior" = "stop-liveness-inconclusive" ] \
          || [ "$behavior" = "credentialed-readiness-uncooperative" ]; then
          printf '%s\\n' "VM liveness is inconclusive" >&2
          exit 70
        fi
        if [ "$behavior" = "guest-command-blocking-cancel-and-stop-failure" ]; then
          printf '%s\\n' "simulated VM stop failure" >&2
          exit 70
        fi
        if [ "$behavior" = "block-first-list-stop-liveness-inconclusive" ]; then
          run_pid="$(tr -d '\\n' < "$root/run-pid" 2>/dev/null || true)"
          if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then
            printf '%s\\n' "VM liveness is inconclusive" >&2
            exit 70
          fi
        fi
        printf '%s\\n' "stopped" > "$state_file"
        if [ "$behavior" = "regress-after-first-stopped-observation" ]; then
          : > "$root/stop-completed"
        fi
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

private struct FakeLumeFixturePaths {
    let directory: URL
    let runtimeDirectory: URL
    let executable: URL
    let storage: URL
    let state: URL
    let behavior: URL
    let observedCPUCount: URL
    let observedMemoryBytes: URL
    let observedDiskBytes: URL
    let createStarted: URL
    let listStarted: URL
    let listContinue: URL
    let guestCommandStarted: URL
    let guestCommandExecutionAttempts: URL
    let guestCommandExecutionStarted: URL
    let guestCommandExecutionProcessIdentifier: URL
    let guestCommandCancellationAttempts: URL
    let guestCommandCancellationStarted: URL
    let guestCommandCancellationProcessIdentifier: URL
    let guestCommandCancellationAcknowledged: URL
    let guestReadinessProbeAttemptsFile: URL
    let guestReadinessProbeStarted: URL
    let guestReadinessProbeProcessIdentifier: URL
    let invalidGuestReadinessProbe: URL
    let guestExecutorProbeObserved: URL
    let runStarted: URL
    let runContinue: URL
    let runProcessIdentifier: URL
    let startIntentObserved: URL
    let startHolderCrash: URL
    let startHolderCrashed: URL
    let startHolderOutput: URL
    let restoreImage: URL

    init(directory: URL) {
        self.directory = directory
        runtimeDirectory = directory.appendingPathComponent(
            "runtime",
            isDirectory: true
        )
        executable = runtimeDirectory.appendingPathComponent("lume")
        storage = directory.appendingPathComponent("vms", isDirectory: true)
        state = directory.appendingPathComponent("state")
        behavior = directory.appendingPathComponent("behavior")
        observedCPUCount = directory.appendingPathComponent(
            "observed-cpu-count"
        )
        observedMemoryBytes = directory.appendingPathComponent(
            "observed-memory-bytes"
        )
        observedDiskBytes = directory.appendingPathComponent(
            "observed-disk-bytes"
        )
        createStarted = directory.appendingPathComponent("create-started")
        listStarted = directory.appendingPathComponent("list-started")
        listContinue = directory.appendingPathComponent("list-continue")
        guestCommandStarted = directory.appendingPathComponent(
            "guest-command-started"
        )
        guestCommandExecutionAttempts = directory.appendingPathComponent(
            "guest-command-execution-attempts"
        )
        guestCommandExecutionStarted = directory.appendingPathComponent(
            "guest-command-execution-started"
        )
        guestCommandExecutionProcessIdentifier =
            directory.appendingPathComponent(
                "guest-command-execution-pid"
            )
        guestCommandCancellationAttempts = directory.appendingPathComponent(
            "guest-command-cancellation-attempts"
        )
        guestCommandCancellationStarted = directory.appendingPathComponent(
            "guest-command-cancellation-started"
        )
        guestCommandCancellationProcessIdentifier =
            directory.appendingPathComponent(
                "guest-command-cancellation-pid"
            )
        guestCommandCancellationAcknowledged =
            directory.appendingPathComponent(
                "guest-command-cancellation-acknowledged"
            )
        guestReadinessProbeAttemptsFile = directory.appendingPathComponent(
            "guest-readiness-probe-attempts"
        )
        guestReadinessProbeStarted = directory.appendingPathComponent(
            "guest-readiness-probe-started"
        )
        guestReadinessProbeProcessIdentifier =
            directory.appendingPathComponent(
                "guest-readiness-probe-pid"
            )
        invalidGuestReadinessProbe = directory.appendingPathComponent(
            "invalid-guest-readiness-probe"
        )
        guestExecutorProbeObserved = directory.appendingPathComponent(
            "guest-executor-probe-observed"
        )
        runStarted = directory.appendingPathComponent("run-started")
        runContinue = directory.appendingPathComponent("run-continue")
        runProcessIdentifier = directory.appendingPathComponent("run-pid")
        startIntentObserved = directory.appendingPathComponent(
            "start-intent-observed"
        )
        startHolderCrash = directory.appendingPathComponent(
            "start-holder-crash"
        )
        startHolderCrashed = directory.appendingPathComponent(
            "start-holder-crashed"
        )
        startHolderOutput = directory.appendingPathComponent(
            "start-holder-output.log"
        )
        restoreImage = directory.appendingPathComponent("restore.ipsw")
    }
}

enum FakeLumeFixtureError: LocalizedError {
    case stateTimeout(String)
    case createStartTimeout
    case listStartTimeout
    case runLaunchTimeout(String)
    case startHolderCrashTimeout(String)
    case startHolderOutputUnavailable(String)
    case guestCommandStartTimeout(String)
    case guestCommandProcessIdentifierUnavailable(String)
    case guestReadinessProbeStartTimeout
    case processExitTimeout(pid_t)

    var errorDescription: String? {
        switch self {
        case .stateTimeout(let state):
            "timed out waiting for fake Lume state \(state)"
        case .createStartTimeout:
            "timed out waiting for fake Lume create"
        case .listStartTimeout:
            "timed out waiting for fake Lume list"
        case .runLaunchTimeout(let diagnostics):
            """
            controlled fake Lume run never launched
            \(diagnostics)
            """
        case .startHolderCrashTimeout(let diagnostics):
            """
            start holder did not terminate with SIGKILL
            \(diagnostics)
            """
        case .startHolderOutputUnavailable(let path):
            "could not create start-holder output capture at \(path)"
        case .guestCommandStartTimeout(let command):
            "timed out waiting for guest command \(command)"
        case .guestCommandProcessIdentifierUnavailable(let command):
            "guest command \(command) process identifier is unavailable"
        case .guestReadinessProbeStartTimeout:
            "timed out waiting for guest readiness probe"
        case .processExitTimeout(let processIdentifier):
            "timed out waiting for process \(processIdentifier) to exit"
        }
    }
}

final class LumeTestWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

final class LumeTestStorageAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func available() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

actor LumeRenewalStatus {
    private(set) var started = false
    private(set) var completed = false

    func markStarted() {
        started = true
    }

    func markCompleted() {
        completed = true
    }
}
