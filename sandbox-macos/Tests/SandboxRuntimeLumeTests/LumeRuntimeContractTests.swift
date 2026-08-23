import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume
import XCTest

final class LumeRuntimeContractTests: XCTestCase {
    func testRuntimePinMatchesAuditedLockFile() throws {
        let lockURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ThirdParty/lume.lock.json")
        let lock = try JSONDecoder().decode(
            LumeLock.self,
            from: Data(contentsOf: lockURL)
        )

        XCTAssertEqual(lock.repository, LumeRuntimeConfiguration.pinnedRepository)
        XCTAssertEqual(lock.commit, LumeRuntimeConfiguration.pinnedCommit)
        XCTAssertEqual(lock.path, LumeRuntimeConfiguration.pinnedSourcePath)
        XCTAssertEqual(lock.version, LumeRuntimeConfiguration.pinnedVersion)
        XCTAssertEqual(lock.license, "MIT")
        XCTAssertEqual(lock.telemetry, "disabled")
    }

    func testPinnedRealLumeBinaryAndEmptyStorageContract() async throws {
        guard let executablePath = ProcessInfo.processInfo.environment[
            "DARKBLOOM_SANDBOX_LUME_PATH"
        ] else {
            throw XCTSkip(
                "set DARKBLOOM_SANDBOX_LUME_PATH for the pinned Lume contract test"
            )
        }

        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-lume-contract-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: storage) }

        let configuration = try LumeRuntimeConfiguration(
            executable: URL(fileURLWithPath: executablePath),
            storageDirectory: storage
        )
        let runtime = LumeVirtualMachineRuntime(configuration: configuration)

        let capabilities = try await runtime.capabilities()
        XCTAssertEqual(capabilities.runtime, "lume")
        XCTAssertEqual(capabilities.version, LumeRuntimeConfiguration.pinnedVersion)
        XCTAssertTrue(capabilities.supportsMacOS)
        XCTAssertFalse(capabilities.supportsPause)
        XCTAssertFalse(capabilities.supportsSnapshots)
        let virtualMachines = try await runtime.list()
        XCTAssertEqual(virtualMachines, [])
    }

    func testPrepareRealMacOSBaseImage() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["DARKBLOOM_SANDBOX_LIVE_VM"] == "1",
            "set DARKBLOOM_SANDBOX_LIVE_VM=1 for the real macOS VM proof"
        )
        let lumePath = try XCTUnwrap(environment["DARKBLOOM_SANDBOX_LUME_PATH"])
        let restoreImagePath = try XCTUnwrap(
            environment["DARKBLOOM_SANDBOX_IPSW_PATH"]
        )
        let storagePath = try XCTUnwrap(
            environment["DARKBLOOM_SANDBOX_VM_STORAGE"]
        )
        let name = environment["DARKBLOOM_SANDBOX_BASE_NAME"]
            ?? "darkbloom-phase0-base"
        let runtime = LumeVirtualMachineRuntime(configuration: try LumeRuntimeConfiguration(
            executable: URL(fileURLWithPath: lumePath),
            storageDirectory: URL(fileURLWithPath: storagePath, isDirectory: true),
            commandTimeoutSeconds: 120,
            createTimeoutSeconds: 7_200
        ))
        let resources = try SandboxResourceSpecification.macOSSmall()
        let specification = try SandboxVirtualMachineSpecification(
            name: name,
            resources: resources,
            imageSource: .restoreImage(
                url: URL(fileURLWithPath: restoreImagePath),
                unattendedPreset: "tahoe"
            ),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )

        let report = try await MacOSBaseImagePreparer(runtime: runtime).prepare(
            specification: specification
        )

        XCTAssertEqual(report.name, name)
        XCTAssertEqual(report.runtimeVersion, LumeRuntimeConfiguration.pinnedVersion)
        XCTAssertEqual(report.guestArchitecture, "arm64")
        XCTAssertFalse(report.guestOperatingSystemVersion.isEmpty)
        XCTAssertEqual(report.cpuCount, 4)
        XCTAssertEqual(report.memoryBytes, 8 * SandboxResourcePolicy.gibibyte)
        XCTAssertEqual(report.diskBytes, 100 * SandboxResourcePolicy.gibibyte)
    }

    func testRunTwoIsolatedMacOSClones() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["DARKBLOOM_SANDBOX_LIVE_TWO_VMS"] == "1",
            "set DARKBLOOM_SANDBOX_LIVE_TWO_VMS=1 for the two-VM proof"
        )
        let lumePath = try XCTUnwrap(environment["DARKBLOOM_SANDBOX_LUME_PATH"])
        let storagePath = try XCTUnwrap(
            environment["DARKBLOOM_SANDBOX_VM_STORAGE"]
        )
        let baseName = environment["DARKBLOOM_SANDBOX_BASE_NAME"]
            ?? "darkbloom-phase0-base"
        let runtime = LumeVirtualMachineRuntime(configuration: try LumeRuntimeConfiguration(
            executable: URL(fileURLWithPath: lumePath),
            storageDirectory: URL(fileURLWithPath: storagePath, isDirectory: true),
            commandTimeoutSeconds: 120,
            createTimeoutSeconds: 7_200
        ))
        guard try await runtime.inspect(name: baseName)?.state == .stopped else {
            XCTFail("prepare the stopped base image before the two-VM proof")
            return
        }

        let resources = try SandboxResourceSpecification.macOSSmall()
        let runID = UUID().uuidString.lowercased().prefix(8)
        let firstName = "darkbloom-phase0-a-\(runID)"
        let secondName = "darkbloom-phase0-b-\(runID)"
        for name in [firstName, secondName] {
            try await runtime.create(SandboxVirtualMachineSpecification(
                name: name,
                resources: resources,
                imageSource: .localTemplate(name: baseName),
                diskBytes: 100 * SandboxResourcePolicy.gibibyte
            ))
        }

        do {
            async let firstStart: Void = runtime.start(name: firstName)
            async let secondStart: Void = runtime.start(name: secondName)
            _ = try await (firstStart, secondStart)

            let marker = "/Users/lume/darkbloom-isolation-marker"
            for name in [firstName, secondName] {
                let reset = try await runtime.execute(
                    name: name,
                    request: SandboxGuestCommandRequest(
                        idempotencyKey: UUID(),
                        executable: "/bin/rm",
                        arguments: ["-f", marker],
                        timeoutSeconds: 30
                    )
                )
                XCTAssertEqual(reset.exitCode, 0)
            }
            let touch = try await runtime.execute(
                name: firstName,
                request: SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/usr/bin/touch",
                    arguments: [marker],
                    timeoutSeconds: 30
                )
            )
            XCTAssertEqual(touch.exitCode, 0)
            let isolation = try await runtime.execute(
                name: secondName,
                request: SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/bin/test",
                    arguments: ["!", "-e", marker],
                    timeoutSeconds: 30
                )
            )
            XCTAssertEqual(isolation.exitCode, 0)

            async let firstStop: Void = runtime.stop(name: firstName)
            async let secondStop: Void = runtime.stop(name: secondName)
            _ = try await (firstStop, secondStop)
        } catch {
            async let firstCleanup: Void? = try? runtime.stop(name: firstName)
            async let secondCleanup: Void? = try? runtime.stop(name: secondName)
            _ = await (firstCleanup, secondCleanup)
            async let firstDelete: Void? = try? runtime.delete(name: firstName)
            async let secondDelete: Void? = try? runtime.delete(name: secondName)
            _ = await (firstDelete, secondDelete)
            throw error
        }

        let firstState = try await runtime.inspect(name: firstName)?.state
        let secondState = try await runtime.inspect(name: secondName)?.state
        XCTAssertEqual(firstState, .stopped)
        XCTAssertEqual(secondState, .stopped)
        async let firstDelete: Void = runtime.delete(name: firstName)
        async let secondDelete: Void = runtime.delete(name: secondName)
        _ = try await (firstDelete, secondDelete)
        let firstDeleted = try await runtime.inspect(name: firstName)
        let secondDeleted = try await runtime.inspect(name: secondName)
        XCTAssertNil(firstDeleted)
        XCTAssertNil(secondDeleted)
    }

    func testConfigurationRejectsRelativeStoragePath() {
        XCTAssertThrowsError(try LumeRuntimeConfiguration(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            storageDirectory: URL(fileURLWithPath: "relative", relativeTo: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ))
        ))
    }
}

private struct LumeLock: Decodable {
    let repository: String
    let commit: String
    let path: String
    let version: String
    let license: String
    let telemetry: String
}
