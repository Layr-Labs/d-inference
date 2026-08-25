import Foundation
import Testing
@testable import ProviderCore

@Suite("Update recovery verified-predecessor fallback", .serialized)
struct UpdateRecoveryFallbackTests {
    #if canImport(Darwin)
    @Test("verified predecessor replaces corrupt live and staged target copies")
    func corruptTargetCopiesRestorePredecessor() throws {
        for layout in [
            VerifiedPredecessor.Layout.app,
            VerifiedPredecessor.Layout.flat,
        ] {
            let journal = try UpdateRecoveryJournalFixture(layout: layout)
            defer { journal.cleanup() }
            let store = journal.store
            let transaction = try journal.transactionObject()
            let target = try journal.targetRecord(from: transaction)

            try journal.installExactTargetCopyAsLive()
            #expect(
                try store.liveMatches(target, layout: layout),
                "test setup did not install the exact \(layout) target"
            )
            #expect(
                try store.stagingContainsTarget(
                    journal.staged.stagingRoot,
                    target: target,
                    layout: layout
                ),
                "test setup did not retain the exact \(layout) staged target"
            )

            let stateBeforeCorruption = try store.loadState()
            guard let predecessor = stateBeforeCorruption.predecessor else {
                Issue.record("prepared \(layout) transaction omitted predecessor")
                continue
            }
            try store.verifyPredecessor(predecessor)

            let liveBinary = journal.binary(in: journal.base.installRoot)
            let stagedBinary = journal.binary(in: journal.staged.stagingRoot)
            try Data("corrupt-live-target".utf8).write(to: liveBinary)
            try Data("corrupt-staged-target".utf8).write(to: stagedBinary)
            #expect(try !store.liveMatches(target, layout: layout))
            #expect(
                try !store.stagingContainsTarget(
                    journal.staged.stagingRoot,
                    target: target,
                    layout: layout
                )
            )

            try withRecoveryLock(store, operation: "restore-\(layout)") {
                try store.recoverInterruptedTransaction(now: 200)
            }

            let recovered = try store.loadState()
            #expect(recovered.current == predecessor.release)
            #expect(recovered.predecessor == predecessor)
            #expect(recovered.candidate == nil)
            #expect(recovered.installGeneration == predecessor.release.installGeneration)
            #expect(
                try journal.base.liveBinaryContents()
                    == "\(journal.base.oldVersion)-darkbloom"
            )
            #expect(try journal.base.persistentStateIsIntact())
            #expect(
                !FileManager.default.fileExists(
                    atPath: journal.transactionPath.path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: journal.staged.stagingRoot.path
                )
            )

            let stableState = recovered
            try withRecoveryLock(store, operation: "restore-idempotence-\(layout)") {
                try store.recoverInterruptedTransaction(now: 201)
            }
            #expect(try store.loadState() == stableState)
        }
    }
    #endif

    private func withRecoveryLock<T>(
        _ store: UpdateRecoveryStore,
        operation: String,
        body: () throws -> T
    ) throws -> T {
        let lock = try UpdateProcessLock.acquire(
            at: store.lockPath,
            operation: operation
        )
        defer { lock.release() }
        return try body()
    }
}
