import Foundation
@testable import ProviderCore

/// A real on-disk SelfUpdater transaction stopped at one durability boundary.
/// Tests mutate only the resulting filesystem/journal; no recovery-store
/// behavior is mocked.
struct UpdateRecoveryJournalFixture {
    enum FixtureError: Error {
        case stagingFailed(UpdateError)
        case expectedInterruption(UpdateRecoveryStore.FaultPoint)
    }

    private enum InjectedInterruption: Error {
        case boundary
    }

    let base: UpdateRecoveryFixture
    let staged: SelfUpdater.StagedBundle

    init(
        layout: VerifiedPredecessor.Layout = .app,
        interruption: UpdateRecoveryStore.FaultPoint = .transactionPersisted
    ) throws {
        let base = try UpdateRecoveryFixture(layout: layout)
        do {
            let updater = SelfUpdater(
                coordinatorBaseURL: "http://127.0.0.1:1",
                installRoot: base.installRoot,
                verifyCodeSignatures: false,
                currentVersion: base.oldVersion
            )
            let staged: SelfUpdater.StagedBundle
            switch updater.stageBundleForTesting(
                from: base.tarball,
                release: base.release,
                installDir: base.installRoot
            ) {
            case .success(let candidate):
                staged = candidate
            case .failure(let error):
                throw FixtureError.stagingFailed(error)
            }

            let interruptedStore = UpdateRecoveryStore(
                installRoot: base.installRoot,
                verifyCodeSignatures: false,
                faultInjector: { point in
                    if point == interruption {
                        throw InjectedInterruption.boundary
                    }
                }
            )
            let lock = try UpdateProcessLock.acquire(
                at: interruptedStore.lockPath,
                operation: "seed-\(interruption)"
            )
            defer { lock.release() }
            do {
                try interruptedStore.commit(
                    staged: staged,
                    currentVersion: base.oldVersion,
                    now: 100
                )
                throw FixtureError.expectedInterruption(interruption)
            } catch InjectedInterruption.boundary {
                // The journal and concrete filesystem state are the fixture.
            }

            self.base = base
            self.staged = staged
        } catch {
            base.cleanup()
            throw error
        }
    }

    var store: UpdateRecoveryStore {
        UpdateRecoveryStore(
            installRoot: base.installRoot,
            verifyCodeSignatures: false
        )
    }

    var transactionPath: URL {
        base.installRoot.appendingPathComponent(
            "recovery/transaction.json"
        )
    }

    func cleanup() {
        base.cleanup()
    }

    func transactionObject() throws -> [String: Any] {
        guard
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: transactionPath)
            ) as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    func writeTransactionObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try UpdateAtomicFilesystem.write(data, to: transactionPath)
    }

    func targetRecord(from object: [String: Any]) throws
        -> InstalledReleaseRecord
    {
        guard let target = object["target"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(
            InstalledReleaseRecord.self,
            from: JSONSerialization.data(withJSONObject: target)
        )
    }

    func installExactTargetCopyAsLive() throws {
        let fm = FileManager.default
        let source: URL
        let destination: URL
        switch base.candidateLayout {
        case .app:
            source = staged.stagingRoot.appendingPathComponent(
                "Darkbloom.app"
            )
            destination = base.installRoot.appendingPathComponent(
                "Darkbloom.app"
            )
        case .flat:
            source = staged.stagingRoot.appendingPathComponent("bin")
            destination = base.installRoot.appendingPathComponent("bin")
        }
        if UpdateAtomicFilesystem.itemExists(destination) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        try store.ensureCanonicalLinks(layout: base.candidateLayout)
    }

    func binary(in root: URL) -> URL {
        switch base.candidateLayout {
        case .app:
            root.appendingPathComponent(
                "Darkbloom.app/Contents/MacOS/darkbloom"
            )
        case .flat:
            root.appendingPathComponent("bin/darkbloom")
        }
    }
}
