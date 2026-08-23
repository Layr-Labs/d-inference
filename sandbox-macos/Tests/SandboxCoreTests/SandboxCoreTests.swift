import Foundation
import SandboxCore
import XCTest

final class SandboxCoreTests: XCTestCase {
    func testIdentifiersRejectZeroAndUseCanonicalEncoding() throws {
        XCTAssertNil(SandboxGeneration(rawValue: 0))
        XCTAssertNil(SandboxFencingToken(rawValue: 0))

        let id = SandboxID(rawValue: UUID(
            uuidString: "6413F8B4-C551-43CF-99B6-E028E1A52C92"
        )!)
        let encoded = try JSONEncoder().encode(id)
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            "\"6413f8b4-c551-43cf-99b6-e028e1a52c92\""
        )
        XCTAssertEqual(try JSONDecoder().decode(SandboxID.self, from: encoded), id)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SandboxGeneration.self,
                from: Data("0".utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SandboxFencingToken.self,
                from: Data("0".utf8)
            )
        )
    }

    func testAlphaResourcePolicyAcceptsProductShapes() throws {
        let small = try SandboxResourceSpecification.macOSSmall()
        XCTAssertEqual(small.cpuCount, 4)
        XCTAssertEqual(small.memoryBytes, 8 * SandboxResourcePolicy.gibibyte)
        XCTAssertEqual(small.workspaceBytes, 25 * SandboxResourcePolicy.gibibyte)
        XCTAssertEqual(small.commandTimeoutSeconds, 900)

        _ = try SandboxResourceSpecification(
            cpuCount: 8,
            memoryBytes: 16 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 50 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 300
        )
    }

    func testAlphaResourcePolicyRejectsOutOfContractValues() {
        XCTAssertThrowsError(try SandboxResourceSpecification(
            cpuCount: 0,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        ))
        XCTAssertThrowsError(try SandboxResourceSpecification(
            cpuCount: 4,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 24 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        ))
        XCTAssertThrowsError(try SandboxResourceSpecification(
            cpuCount: 4,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 901
        ))
    }

    func testResourceDecodeCannotBypassPolicyValidation() {
        let invalid = Data(
            """
            {
              "cpuCount": 0,
              "memoryBytes": 8589934592,
              "workspaceBytes": 26843545600,
              "commandTimeoutSeconds": 900
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SandboxResourceSpecification.self,
                from: invalid
            )
        )
    }

    func testLifecycleHappyPathAndRecoveryPath() throws {
        var lifecycle = SandboxLifecycle()
        let transitions: [SandboxLifecycleState] = [
            .reserving,
            .preparing,
            .booting,
            .ready,
            .executing,
            .ready,
            .stopping,
            .checkpointing,
            .stoppedLocal,
            .recovering,
            .stopped,
            .deleting,
            .deleted,
        ]

        for destination in transitions {
            try lifecycle.transition(
                to: destination,
                reason: "test \(destination.rawValue)",
                at: Date(timeIntervalSince1970: TimeInterval(lifecycle.sequence + 1))
            )
        }

        XCTAssertEqual(lifecycle.state, .deleted)
        XCTAssertEqual(lifecycle.sequence, UInt64(transitions.count))
        XCTAssertTrue(lifecycle.state.isTerminal)
        XCTAssertThrowsError(
            try lifecycle.transition(to: .queued, reason: "cannot resurrect")
        )

        let encoded = try JSONEncoder().encode(lifecycle)
        XCTAssertEqual(
            try JSONDecoder().decode(SandboxLifecycle.self, from: encoded),
            lifecycle
        )
    }

    func testLifecycleRejectsInvalidTransitionsAndSnapshots() {
        var lifecycle = SandboxLifecycle()
        XCTAssertThrowsError(
            try lifecycle.transition(to: .ready, reason: "skip reservation")
        )
        XCTAssertThrowsError(
            try lifecycle.transition(to: .reserving, reason: "  ")
        )

        let inconsistent = Data(
            """
            {"state":"ready","sequence":0}
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SandboxLifecycle.self, from: inconsistent)
        )
    }
}
