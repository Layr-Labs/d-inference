import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

final class StageBatchObservationTests: XCTestCase {
    private let scope = UUID(uuidString: "BFEA1299-FC61-4F58-B96F-461FB81CE102")!
    private var empty: StageBatchObservation.Memory {
        .init(backend: "paged", capacity: 4096, reserved: 0, inUse: 0,
              materialized: 0, boundRows: 0, drained: true)
    }
    private var active: StageBatchObservation.Memory {
        .init(backend: "paged", capacity: 4096, reserved: 2048, inUse: 128,
              materialized: 1024, boundRows: 4, drained: false)
    }

    func testSuccessfulNativeWidthsEmitOnlyNewMaximaAndShareRankScope() {
        for rank in 0...1 {
            let observation = StageBatchObservation(rank: rank, scope: scope, capacity: 8)
            XCTAssertEqual(observation.started(memory: empty).count, 1)
            var lines: [String] = []
            for width in 1...8 {
                lines += observation.completedDecode(width: width, memory: active)
                XCTAssertTrue(observation.completedDecode(width: width, memory: active).isEmpty)
                XCTAssertTrue(observation.completedDecode(width: 1, memory: active).isEmpty)
            }
            XCTAssertEqual(lines.count, 16)
            XCTAssertEqual(lines.filter { $0.hasPrefix("darkbloom-stage-batch-decode-v1") }.count, 8)
            XCTAssertTrue(lines.allSatisfy { $0.contains("rank=\(rank) scope=\(scope.uuidString.lowercased())") })
            XCTAssertTrue(lines[14].hasSuffix("width=8 capacity=8"))
        }
    }

    func testUncompletedAndOutOfRangeWorkCannotProduceWidthEvidence() {
        let observation = StageBatchObservation(rank: 0, scope: scope, capacity: 2)
        XCTAssertTrue(observation.completedDecode(width: 2, memory: active).isEmpty)
        _ = observation.started(memory: empty)
        for width in [-1, 0, 3, 8, Int.max] {
            XCTAssertTrue(observation.completedDecode(width: width, memory: active).isEmpty)
        }
        XCTAssertEqual(observation.completedDecode(width: 2, memory: active).count, 2)
    }

    func testSnapshotsExposeActualBackingSeparatelyFromReservationAndCapacity() {
        let observation = StageBatchObservation(rank: 1, scope: scope, capacity: 8)
        _ = observation.started(memory: empty)
        let line = observation.completedPrefill(memory: active).first!
        XCTAssertTrue(line.contains("phase=prefill backend=paged capacity=4096 reserved=2048 in_use=128 materialized=1024 bound_rows=4 drained=0"))
        let final = observation.finished(success: true, memory: empty).first!
        XCTAssertTrue(final.contains("phase=retired"))
        XCTAssertTrue(final.contains("reserved=0 in_use=0 materialized=0 bound_rows=0 drained=1"))
    }

    func testRetirementDoesNotInventDrainOrPhysicalRelease() {
        let observation = StageBatchObservation(rank: 0, scope: scope, capacity: 8)
        _ = observation.started(memory: empty)
        let line = observation.finished(success: true, memory: active).first!
        XCTAssertTrue(line.contains("phase=retired"))
        XCTAssertTrue(line.contains("materialized=1024 bound_rows=4 drained=0"))
    }

    func testFailedCleanupNeverClaimsSuccessfulRetirementAndEndsObservation() {
        let observation = StageBatchObservation(rank: 0, scope: scope, capacity: 2)
        _ = observation.started(memory: empty)
        let line = observation.finished(success: false, memory: empty).first!
        XCTAssertTrue(line.contains("phase=failed"))
        XCTAssertFalse(line.contains("retired"))
        XCTAssertTrue(observation.finished(success: true, memory: empty).isEmpty)
        XCTAssertTrue(observation.completedDecode(width: 2, memory: active).isEmpty)
        XCTAssertTrue(observation.completedPrefill(memory: active).isEmpty)
        XCTAssertTrue(observation.started(memory: active).isEmpty)
    }

    func testRepeatedNativeStepsDoNotReadMemoryCountersOrGrowLog() {
        let observation = StageBatchObservation(rank: 0, scope: scope, capacity: 8)
        var reads = 0
        func snapshot() -> StageBatchObservation.Memory { reads += 1; return active }
        _ = observation.started(memory: snapshot())
        _ = observation.completedPrefill(memory: snapshot())
        _ = observation.completedDecode(width: 8, memory: snapshot())
        for _ in 0..<1024 {
            XCTAssertTrue(observation.started(memory: snapshot()).isEmpty)
            XCTAssertTrue(observation.completedPrefill(memory: snapshot()).isEmpty)
            XCTAssertTrue(observation.completedDecode(width: 8, memory: snapshot()).isEmpty)
        }
        XCTAssertEqual(reads, 3)
        _ = observation.finished(success: true, memory: snapshot())
        XCTAssertEqual(reads, 4)
    }

    func testCompletedStepCountsIncludeRepeatedAndDecreasingWidthsOnlyWithinLiveScope() {
        let observation = StageBatchObservation(rank: 1, scope: scope, capacity: 4)
        XCTAssertTrue(observation.completedDecode(width: 4, memory: active).isEmpty)
        XCTAssertTrue(observation.finished(success: true, memory: empty).isEmpty)
        _ = observation.started(memory: empty)
        for width in [-1, 0, 5, 8, Int.max] {
            XCTAssertTrue(observation.completedDecode(width: width, memory: active).isEmpty)
        }
        for width in [1, 2, 2, 1, 4, 2, 1] {
            _ = observation.completedDecode(width: width, memory: active)
        }
        let final = observation.finished(success: true, memory: empty)
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final[0].hasPrefix("darkbloom-stage-batch-memory-v1"))
        XCTAssertEqual(final[1], "darkbloom-stage-batch-decode-counts-v1 rank=1 scope=\(scope.uuidString.lowercased()) phase=retired capacity=4 width1=3 width2=3 width3=0 width4=1 width5=0 width6=0 width7=0 width8=0")
        XCTAssertTrue(observation.completedDecode(width: 4, memory: active).isEmpty)
        XCTAssertTrue(observation.finished(success: false, memory: empty).isEmpty)
    }

    func testFailedScopeKeepsCompletedCountsWithoutClaimingRetirement() {
        let observation = StageBatchObservation(rank: 0, scope: scope, capacity: 2)
        _ = observation.started(memory: empty)
        _ = observation.completedDecode(width: 2, memory: active)
        _ = observation.completedDecode(width: 2, memory: active)
        let final = observation.finished(success: false, memory: empty)
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final.allSatisfy { $0.contains("phase=failed") && !$0.contains("retired") })
        XCTAssertTrue(final[1].hasSuffix("width1=0 width2=2 width3=0 width4=0 width5=0 width6=0 width7=0 width8=0"))
    }

    func testAllWidthsKeepLogsAndMemoryReadsBoundedWithOneFinalSummary() {
        let observation = StageBatchObservation(rank: 0, scope: scope, capacity: 8)
        var reads = 0
        func snapshot() -> StageBatchObservation.Memory { reads += 1; return active }
        var lines = observation.started(memory: snapshot())
        lines += observation.completedPrefill(memory: snapshot())
        for width in 1...8 {
            lines += observation.completedDecode(width: width, memory: snapshot())
            for _ in 0..<1024 {
                XCTAssertTrue(observation.completedDecode(width: width, memory: snapshot()).isEmpty)
            }
        }
        XCTAssertEqual(reads, 10)
        lines += observation.finished(success: true, memory: snapshot())
        XCTAssertEqual(reads, 11)
        XCTAssertEqual(lines.count, 20)
        XCTAssertEqual(lines.filter { $0.hasPrefix("darkbloom-stage-batch-decode-counts-v1") }.count, 1)
        for width in 1...8 { XCTAssertTrue(lines.last!.contains("width\(width)=1025")) }
        XCTAssertTrue(observation.finished(success: true, memory: snapshot()).isEmpty)
        XCTAssertTrue(observation.completedDecode(width: 8, memory: snapshot()).isEmpty)
        XCTAssertEqual(reads, 11)
    }

    func testInvalidCapacityAndNoCompletedWorkReportOnlyZeroCounts() {
        for capacity in [-1, 0, 2, 9] {
            let observation = StageBatchObservation(rank: 0, scope: scope, capacity: capacity)
            _ = observation.started(memory: empty)
            if capacity != 2 {
                for width in 1...8 { XCTAssertTrue(observation.completedDecode(width: width, memory: active).isEmpty) }
            }
            XCTAssertTrue(observation.finished(success: true, memory: empty)[1].hasSuffix(
                "width1=0 width2=0 width3=0 width4=0 width5=0 width6=0 width7=0 width8=0"))
        }
    }

    func testContiguousBackingIsUnavailableRatherThanInferredFromLiveBytes() {
        let observation = StageBatchObservation(rank: 0, scope: scope, capacity: 2)
        let memory = StageBatchObservation.Memory(backend: "contiguous", capacity: 4096,
            reserved: 2048, inUse: 128, materialized: nil, boundRows: 1, drained: false)
        XCTAssertTrue(observation.started(memory: memory)[0].contains("materialized=unavailable"))
    }
}
