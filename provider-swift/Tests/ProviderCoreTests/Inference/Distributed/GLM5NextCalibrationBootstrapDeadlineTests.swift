import Foundation
import Testing
@testable import ProviderCore

/// Old-API-compatible regression. Real native CPU helper, both actual owners
/// and authenticated drivers; a long deadline value never means a long wait.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationBootstrapDeadlineTests {
    private final class Rounds: @unchecked Sendable {
        private let lock = NSLock()
        private var published: [Int: [UInt64]] = [:]
        func record(_ rank: Int, _ event: GLM5NextCalibrationDispatch.Observation) {
            if case .bootstrapPublished(let sequence) = event {
                lock.withLock { published[rank, default: []].append(sequence) }
            }
        }
        func sequences(_ rank: Int) -> [UInt64] { lock.withLock { published[rank, default: []] } }
    }

    @Test func nineHundredSecondExperimentActuallyLaunchesAndRetiresBothNativeChildren() throws {
        let rounds = Rounds()
        let f = try GLM5NextCalibrationDispatchRunFixture(experimentLifetimeSeconds: 900) { rank, event, _ in
            rounds.record(rank, event)
        }
        defer { f.cleanup() }
        f.start()
        // Existing join stays eight seconds. No wait/clock advance to either
        // the300-second socket bound or the900-second experiment deadline.
        try f.requireSuccess(f.join())
        for rank in 0...1 {
            let owner = try #require(f.ledger.owner(rank))
            let context = try #require(f.ledger.context(rank))
            let expiry = f.quotes[rank].authorized.request.selection.expiresUnixSeconds
            #expect(expiry == f.quotes[1 - rank].authorized.request.selection.expiresUnixSeconds)
            #expect(context.expiresUnixSeconds == expiry)
            for start in context.starts {
                if case .finiteCalibrationV1(let permission) = start.common.permission {
                    #expect(permission.expiresUnixSeconds == expiry)
                    #expect(permission.requestID == context.requestID)
                } else {
                    Issue.record("Native start must carry the exact finite calibration permission")
                }
            }
            #expect(owner.experimentDeadline > DispatchTime.now().uptimeNanoseconds + 300_000_000_000)
            #expect(rounds.sequences(rank) == Array(UInt64(0)...UInt64(6)))
            #expect(owner.status().bootstrapCompleted && owner.status().journalResolved)
            #expect(owner.status().observedExit)
            #expect(owner.actualExit()?.termination == .exited(0))
            #expect(owner.actualExit()?.localJournalResolved == true)
            _ = try owner.completed()
            #expect(!FileManager.default.fileExists(atPath: f.pending(rank).path))
        }
    }
}
