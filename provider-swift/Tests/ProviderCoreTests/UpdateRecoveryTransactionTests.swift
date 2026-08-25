import Foundation
import Testing
@testable import ProviderCore

@Suite("Update recovery transactions", .serialized)
struct UpdateRecoveryTransactionTests {
    private enum InjectedCrash: Error {
        case boundary
    }

    private enum FixtureError: Error {
        case stagingFailed
    }

    private static let journalFaultPoints: [UpdateRecoveryStore.FaultPoint] = [
        .transactionPersisted,
        .liveLayoutExchanged,
        .liveLayoutReplaced,
        .statePersisted,
    ]

    private static let rollbackFaultPoints: [UpdateRecoveryStore.FaultPoint] =
        journalFaultPoints + [.transactionRemoved]

    @Test("every rollback boundary is idempotent across repeated recovery")
    func rollbackFaultBoundariesAreIdempotent() throws {
        #expect(
            Self.rollbackFaultPoints
                == UpdateRecoveryStore.FaultPoint.allCases.filter {
                    $0 != .predecessorPromoted
                }
        )

        for layout in [
            VerifiedPredecessor.Layout.app,
            VerifiedPredecessor.Layout.flat,
        ] {
            for point in Self.rollbackFaultPoints {
                let fixture = try UpdateRecoveryFixture(layout: layout)
                defer { fixture.cleanup() }
                try installCandidate(in: fixture)

                let before = try recoveryStore(fixture).loadState()
                let expectedGeneration = try incremented(before.installGeneration)
                try interruptRollback(in: fixture, at: point)
                try proveRepeatedRecoveryIsStable(
                    fixture,
                    expectedGeneration: expectedGeneration,
                    context: "\(layout) rollback at \(point)"
                )
            }
        }
    }

    @Test("schema-1 rollback journals recover before and after durable state")
    func legacyRollbackJournalsRemainCompatible() throws {
        for layout in [
            VerifiedPredecessor.Layout.app,
            VerifiedPredecessor.Layout.flat,
        ] {
            for point in Self.journalFaultPoints {
                let fixture = try UpdateRecoveryFixture(layout: layout)
                defer { fixture.cleanup() }
                try installCandidate(in: fixture)

                let before = try recoveryStore(fixture).loadState()
                let expectedGeneration = try incremented(before.installGeneration)
                try interruptRollback(in: fixture, at: point)
                try downgradeJournalToSchema1(fixture)
                try proveRepeatedRecoveryIsStable(
                    fixture,
                    expectedGeneration: expectedGeneration,
                    context: "schema-1 \(layout) rollback at \(point)"
                )
            }
        }
    }

    @Test("schema-1 install journals recover at every journaled boundary")
    func legacyInstallJournalsRemainCompatible() throws {
        for layout in [
            VerifiedPredecessor.Layout.app,
            VerifiedPredecessor.Layout.flat,
        ] {
            for point in Self.journalFaultPoints {
                let fixture = try UpdateRecoveryFixture(layout: layout)
                defer { fixture.cleanup() }
                let staged = try stagedBundle(for: fixture)
                let store = UpdateRecoveryStore(
                    installRoot: fixture.installRoot,
                    verifyCodeSignatures: false,
                    faultInjector: { hit in
                        if hit == point {
                            throw InjectedCrash.boundary
                        }
                    }
                )
                _ = try withLock(store, operation: "schema-1-install-\(point)") {
                    #expect(throws: InjectedCrash.self) {
                        try store.commit(
                            staged: staged,
                            currentVersion: fixture.oldVersion,
                            now: 100
                        )
                    }
                }
                try downgradeJournalToSchema1(fixture)

                let recovered = recoveryStore(fixture)
                try withLock(recovered, operation: "schema-1-install-recovery") {
                    try recovered.recoverInterruptedTransaction(now: 101)
                    try recovered.recoverInterruptedTransaction(now: 102)
                }

                let state = try recovered.loadState()
                #expect(state.installGeneration == 1)
                #expect(state.candidate?.release.version == fixture.newVersion)
                #expect(state.current?.version == fixture.oldVersion)
                #expect(try fixture.liveBinaryContents() == "\(fixture.newVersion)-darkbloom")
                #expect(try fixture.persistentStateIsIntact())
                #expect(!journalExists(fixture))
            }
        }
    }

    private func installCandidate(in fixture: UpdateRecoveryFixture) throws {
        let staged = try stagedBundle(for: fixture)
        let store = recoveryStore(fixture)
        try withLock(store, operation: "install-candidate") {
            try store.commit(
                staged: staged,
                currentVersion: fixture.oldVersion,
                now: 100
            )
            var state = try store.loadState()
            state.candidate?.failureCount = UpdateRecoveryState.rollbackThreshold
            try store.writeState(state)
        }
    }

    private func interruptRollback(
        in fixture: UpdateRecoveryFixture,
        at point: UpdateRecoveryStore.FaultPoint
    ) throws {
        let store = UpdateRecoveryStore(
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            faultInjector: { hit in
                if hit == point {
                    throw InjectedCrash.boundary
                }
            }
        )
        _ = try withLock(store, operation: "rollback-\(point)") {
            #expect(throws: InjectedCrash.self) {
                _ = try store.rollback(now: 200, reason: "candidate failed to start")
            }
        }
    }

    private func proveRepeatedRecoveryIsStable(
        _ fixture: UpdateRecoveryFixture,
        expectedGeneration: UInt64,
        context: String
    ) throws {
        var firstRecoveredState: UpdateRecoveryState?
        if journalExists(fixture) {
            let repeatedlyCrashing = UpdateRecoveryStore(
                installRoot: fixture.installRoot,
                verifyCodeSignatures: false,
                faultInjector: { point in
                    if point == .statePersisted {
                        throw InjectedCrash.boundary
                    }
                }
            )
            for attempt in 0..<3 {
                _ = try withLock(
                    repeatedlyCrashing,
                    operation: "repeated-recovery-\(attempt)"
                ) {
                    #expect(throws: InjectedCrash.self) {
                        try repeatedlyCrashing.recoverInterruptedTransaction(
                            now: 300 + Double(attempt)
                        )
                    }
                }
                let state = try recoveryStore(fixture).loadState()
                assertRecoveredRollback(
                    state,
                    fixture: fixture,
                    expectedGeneration: expectedGeneration,
                    context: "\(context), recovery \(attempt)"
                )
                if let firstRecoveredState {
                    #expect(
                        state == firstRecoveredState,
                        "recovery changed already-durable state: \(context)"
                    )
                } else {
                    firstRecoveredState = state
                }
            }
        }

        let recovered = recoveryStore(fixture)
        try withLock(recovered, operation: "final-recovery") {
            try recovered.recoverInterruptedTransaction(now: 400)
        }
        let finalState = try recovered.loadState()
        assertRecoveredRollback(
            finalState,
            fixture: fixture,
            expectedGeneration: expectedGeneration,
            context: context
        )
        try withLock(recovered, operation: "idempotence-check") {
            try recovered.recoverInterruptedTransaction(now: 500)
        }
        #expect(
            try recovered.loadState() == finalState,
            "recovery without a journal changed state: \(context)"
        )
        #expect(try fixture.liveBinaryContents() == "\(fixture.oldVersion)-darkbloom")
        #expect(try fixture.persistentStateIsIntact())
        #expect(!journalExists(fixture))
        #expect(try orphanedRollbackStaging(in: fixture).isEmpty)
    }

    private func assertRecoveredRollback(
        _ state: UpdateRecoveryState,
        fixture: UpdateRecoveryFixture,
        expectedGeneration: UInt64,
        context: String
    ) {
        #expect(
            state.installGeneration == expectedGeneration,
            "install generation changed: \(context)"
        )
        #expect(state.current?.version == fixture.oldVersion)
        #expect(state.candidate == nil)
        #expect(state.quarantine?.version == fixture.newVersion)
        #expect(
            state.quarantine?.failureCount == UpdateRecoveryState.rollbackThreshold
        )
    }

    private func stagedBundle(
        for fixture: UpdateRecoveryFixture
    ) throws -> SelfUpdater.StagedBundle {
        let updater = SelfUpdater(
            coordinatorBaseURL: "http://127.0.0.1:1",
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false,
            currentVersion: fixture.oldVersion
        )
        let result = updater.stageBundleForTesting(
            from: fixture.tarball,
            release: fixture.release,
            installDir: fixture.installRoot
        )
        switch result {
        case .success(let staged):
            return staged
        case .failure(let error):
            throw error
        }
    }

    private func downgradeJournalToSchema1(
        _ fixture: UpdateRecoveryFixture
    ) throws {
        let path = journalPath(fixture)
        let data = try Data(contentsOf: path)
        guard var object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw FixtureError.stagingFailed
        }
        object["schema"] = 1
        object.removeValue(forKey: "resulting_install_generation")
        let legacyData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try UpdateAtomicFilesystem.write(legacyData, to: path)
    }

    private func incremented(_ generation: UInt64) throws -> UInt64 {
        let (next, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else {
            throw UpdateRecoveryStore.StoreError.corruptState(
                "test fixture install generation overflow"
            )
        }
        return next
    }

    private func withLock<T>(
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

    private func recoveryStore(
        _ fixture: UpdateRecoveryFixture
    ) -> UpdateRecoveryStore {
        UpdateRecoveryStore(
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false
        )
    }

    private func journalPath(_ fixture: UpdateRecoveryFixture) -> URL {
        fixture.installRoot.appendingPathComponent("recovery/transaction.json")
    }

    private func journalExists(_ fixture: UpdateRecoveryFixture) -> Bool {
        FileManager.default.fileExists(atPath: journalPath(fixture).path)
    }

    private func orphanedRollbackStaging(
        in fixture: UpdateRecoveryFixture
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: fixture.installRoot,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".rollback-staging-")
                || $0.lastPathComponent.hasPrefix(".recovery-restore-")
        }
    }
}
