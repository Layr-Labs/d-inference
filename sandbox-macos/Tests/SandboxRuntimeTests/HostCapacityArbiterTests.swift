import Foundation
import SandboxCore
@testable import SandboxRuntime
import XCTest

final class HostCapacityArbiterTests: XCTestCase {
    func testPersistsHostModeAndRequiresDrainingTransitions() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)

        assertCapacityError(.uninitialized) {
            _ = try arbiter.snapshot()
        }
        XCTAssertEqual(try arbiter.initialize().mode, .draining)
        XCTAssertEqual(try arbiter.setMode(.sandboxDedicated).mode, .sandboxDedicated)
        assertCapacityError(
            .invalidModeTransition(from: .sandboxDedicated, to: .inference)
        ) {
            _ = try arbiter.setMode(.inference)
        }
        XCTAssertEqual(try arbiter.setMode(.draining).mode, .draining)
        XCTAssertEqual(try arbiter.setMode(.inference).mode, .inference)

        let reopened = try makeArbiter(stateDirectory: stateDirectory)
        XCTAssertEqual(
            try reopened.initialize().mode,
            .inference,
            "initialization must not overwrite durable host mode"
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: stateDirectory.appendingPathComponent("capacity.json").path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).uint16Value
        XCTAssertEqual(permissions & 0o077, 0)
    }

    func testEnforcesTwoGuestAndAggregateResourceCapacity() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        _ = try arbiter.initialize()
        let resources = try makeResources()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstID = SandboxID()

        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try arbiter.reserve(
                sandboxID: firstID,
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: resources,
                expiresAt: now.addingTimeInterval(120),
                now: now
            )
        }
        _ = try arbiter.setMode(.sandboxDedicated)
        let first = try arbiter.reserve(
            sandboxID: firstID,
            generation: try generation(1),
            virtualMachineName: "sandbox-a",
            resources: resources,
            expiresAt: now.addingTimeInterval(120),
            now: now
        )
        XCTAssertEqual(
            try arbiter.reserve(
                sandboxID: firstID,
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: resources,
                expiresAt: now.addingTimeInterval(180),
                now: now
            ),
            first,
            "reservation retries must return the original lease"
        )
        assertCapacityError(.duplicateVirtualMachineName) {
            _ = try arbiter.reserve(
                sandboxID: SandboxID(),
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: resources,
                expiresAt: now.addingTimeInterval(120),
                now: now
            )
        }
        assertCapacityError(.staleFencingToken) {
            _ = try arbiter.reserve(
                sandboxID: firstID,
                generation: try generation(1),
                virtualMachineName: "sandbox-a",
                resources: try makeResources(cpuCount: 2),
                expiresAt: now.addingTimeInterval(120),
                now: now
            )
        }
        _ = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-b",
            resources: resources,
            expiresAt: now.addingTimeInterval(120),
            now: now
        )
        assertCapacityError(.capacityExhausted) {
            _ = try arbiter.reserve(
                sandboxID: SandboxID(),
                generation: try generation(1),
                virtualMachineName: "sandbox-c",
                resources: resources,
                expiresAt: now.addingTimeInterval(120),
                now: now
            )
        }
        XCTAssertEqual(
            try arbiter.expiredLeases(at: now.addingTimeInterval(121)).count,
            2
        )
        XCTAssertEqual(
            try arbiter.snapshot().leases.count,
            2,
            "expiry discovery must not reclaim capacity before VM cleanup"
        )
    }

    func testFencingRejectsStaleCommandsAndSurvivesRestart() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let sandboxID = SandboxID()
        let firstGeneration = try generation(1)
        let secondGeneration = try generation(2)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let first = try arbiter.reserve(
            sandboxID: sandboxID,
            generation: firstGeneration,
            virtualMachineName: "sandbox-fenced",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120),
            now: now
        )
        // #region agent log
        agentDebugLog(
            hypothesisId: "A",
            location: "HostCapacityArbiterTests.swift:146",
            message: "reserved initial capacity lease",
            data: [
                "firstToken": first.scope.fencingToken.rawValue,
            ]
        )
        // #endregion

        assertCapacityError(.activeSandboxGeneration(
            existing: firstGeneration,
            requested: secondGeneration
        )) {
            _ = try arbiter.reserve(
                sandboxID: sandboxID,
                generation: secondGeneration,
                virtualMachineName: "sandbox-replacement",
                resources: try makeResources(),
                expiresAt: now.addingTimeInterval(120),
                now: now
            )
        }
        let staleScope = SandboxOperationScope(
            sandboxID: sandboxID,
            generation: firstGeneration,
            fencingToken: try fencingToken(first.scope.fencingToken.rawValue + 1)
        )
        assertCapacityError(.staleFencingToken) {
            _ = try arbiter.renew(
                scope: staleScope,
                expiresAt: now.addingTimeInterval(180),
                now: now
            )
        }
        let renewed = try arbiter.renew(
            scope: first.scope,
            expiresAt: now.addingTimeInterval(180),
            now: now
        )
        // #region agent log
        agentDebugLog(
            hypothesisId: "A",
            location: "HostCapacityArbiterTests.swift:177",
            message: "renewed capacity lease",
            data: [
                "firstToken": first.scope.fencingToken.rawValue,
                "probeToken": staleScope.fencingToken.rawValue,
                "renewedToken": renewed.scope.fencingToken.rawValue,
            ]
        )
        // #endregion
        XCTAssertEqual(renewed.expiresAt, now.addingTimeInterval(180))
        XCTAssertGreaterThan(
            renewed.scope.fencingToken,
            first.scope.fencingToken
        )
        assertCapacityError(.invalidLeaseDeadline) {
            _ = try arbiter.renew(
                scope: renewed.scope,
                expiresAt: now.addingTimeInterval(170),
                now: now
            )
        }
        assertCapacityError(.staleFencingToken) {
            try arbiter.release(scope: staleScope)
        }
        assertCapacityError(.staleFencingToken) {
            try arbiter.release(scope: first.scope)
        }
        try arbiter.release(scope: renewed.scope)

        let reopened = try makeArbiter(stateDirectory: stateDirectory)
        let second = try reopened.reserve(
            sandboxID: sandboxID,
            generation: secondGeneration,
            virtualMachineName: "sandbox-replacement",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120),
            now: now
        )
        XCTAssertGreaterThan(
            second.scope.fencingToken,
            first.scope.fencingToken,
            "released fencing tokens must never be reused after restart"
        )
    }

    func testConcurrentReservationsCannotOverbookHost() async throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let resources = try makeResources()
        let generation = try generation(1)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let outcomes = await withTaskGroup(
            of: ReservationOutcome.self,
            returning: [ReservationOutcome].self
        ) { group in
            for index in 0..<8 {
                group.addTask {
                    do {
                        _ = try arbiter.reserve(
                            sandboxID: SandboxID(),
                            generation: generation,
                            virtualMachineName: "sandbox-concurrent-\(index)",
                            resources: resources,
                            expiresAt: now.addingTimeInterval(120),
                            now: now
                        )
                        return .reserved
                    } catch let error as SandboxCapacityError {
                        if error == .capacityExhausted {
                            return .exhausted
                        }
                        return .failed(error.description)
                    } catch {
                        return .failed(String(describing: error))
                    }
                }
            }
            var outcomes: [ReservationOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        XCTAssertEqual(outcomes.filter { $0 == .reserved }.count, 2)
        XCTAssertEqual(outcomes.filter { $0 == .exhausted }.count, 6)
        XCTAssertFalse(outcomes.contains {
            if case .failed = $0 {
                return true
            }
            return false
        }, "\(outcomes)")
        XCTAssertEqual(try arbiter.snapshot().leases.count, 2)
    }

    func testRenewRejectsExpiredLeaseAndDrainingHost() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let lease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-renewal",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120),
            now: now
        )

        assertCapacityError(.leaseExpired) {
            _ = try arbiter.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(240),
                now: now.addingTimeInterval(121)
            )
        }
        assertCapacityError(.leaseExpired) {
            _ = try arbiter.reserve(
                sandboxID: lease.scope.sandboxID,
                generation: lease.scope.generation,
                virtualMachineName: lease.virtualMachineName,
                resources: try makeResources(),
                expiresAt: now.addingTimeInterval(240),
                now: now.addingTimeInterval(121)
            )
        }
        _ = try arbiter.setMode(.draining)
        assertCapacityError(.hostNotAcceptingSandboxes(.draining)) {
            _ = try arbiter.renew(
                scope: lease.scope,
                expiresAt: now.addingTimeInterval(180),
                now: now.addingTimeInterval(1)
            )
        }
    }

    func testRejectsInsecureAndCorruptPersistentState() throws {
        let insecureDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: insecureDirectory) }
        try FileManager.default.createDirectory(
            at: insecureDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: insecureDirectory.path
        )
        let insecure = try makeArbiter(stateDirectory: insecureDirectory)
        assertCapacityError(.unsafeStatePath) {
            _ = try insecure.initialize()
        }

        let corruptDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: corruptDirectory) }
        let corrupt = try makeArbiter(stateDirectory: corruptDirectory)
        _ = try corrupt.initialize()
        let stateURL = corruptDirectory.appendingPathComponent("capacity.json")
        try Data("{}".utf8).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
        assertCapacityError(.corruptState) {
            _ = try corrupt.snapshot()
        }
    }

    func testRejectsInferenceModeWithPersistedLease() throws {
        let stateDirectory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let arbiter = try makeArbiter(stateDirectory: stateDirectory)
        try initializeDedicated(arbiter)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try generation(1),
            virtualMachineName: "sandbox-active",
            resources: try makeResources(),
            expiresAt: now.addingTimeInterval(120),
            now: now
        )

        let stateURL = stateDirectory.appendingPathComponent("capacity.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: stateURL)
            ) as? [String: Any]
        )
        object["mode"] = SandboxHostMode.inference.rawValue
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )

        assertCapacityError(.corruptState) {
            _ = try arbiter.snapshot()
        }
    }

    private func makeArbiter(
        stateDirectory: URL,
        maximumCPUCount: UInt16 = 8,
        maximumMemoryGiB: UInt64 = 16
    ) throws -> SandboxHostCapacityArbiter {
        try SandboxHostCapacityArbiter(
            stateDirectory: stateDirectory,
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: maximumCPUCount,
                maximumReservedMemoryBytes: maximumMemoryGiB
                    * SandboxResourcePolicy.gibibyte
            )
        )
    }

    private func makeResources(
        cpuCount: UInt16 = 4,
        memoryGiB: UInt64 = 8
    ) throws -> SandboxResourceSpecification {
        try SandboxResourceSpecification(
            cpuCount: cpuCount,
            memoryBytes: memoryGiB * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        )
    }

    private func initializeDedicated(
        _ arbiter: SandboxHostCapacityArbiter
    ) throws {
        _ = try arbiter.initialize()
        _ = try arbiter.setMode(.sandboxDedicated)
    }

    private func generation(_ value: UInt64) throws -> SandboxGeneration {
        try XCTUnwrap(SandboxGeneration(rawValue: value))
    }

    private func fencingToken(_ value: UInt64) throws -> SandboxFencingToken {
        try XCTUnwrap(SandboxFencingToken(rawValue: value))
    }

    private func temporaryStateDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-capacity-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func assertCapacityError(
        _ expected: SandboxCapacityError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(
            try operation(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SandboxCapacityError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private enum ReservationOutcome: Equatable, Sendable {
    case reserved
    case exhausted
    case failed(String)
}

private func agentDebugLog(
    hypothesisId: String,
    location: String,
    message: String,
    data: [String: Any]
) {
    let payload: [String: Any] = [
        "hypothesisId": hypothesisId,
        "location": location,
        "message": message,
        "data": data,
        "timestamp": Date().timeIntervalSince1970 * 1_000,
    ]
    guard let encoded = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    ) else {
        return
    }
    let logURL = URL(fileURLWithPath: "/tmp/darkbloom-sandbox-debug.log")
    if !FileManager.default.fileExists(atPath: logURL.path) {
        _ = FileManager.default.createFile(
            atPath: logURL.path,
            contents: nil
        )
    }
    guard let handle = try? FileHandle(forWritingTo: logURL) else {
        return
    }
    defer { try? handle.close() }
    try? handle.seekToEnd()
    try? handle.write(contentsOf: encoded + Data([0x0A]))
}
