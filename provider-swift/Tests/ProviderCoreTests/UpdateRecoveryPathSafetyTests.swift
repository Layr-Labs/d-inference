import Foundation
import Testing
@testable import ProviderCore

@Suite("Update recovery path safety", .serialized)
struct UpdateRecoveryPathSafetyTests {
    private enum JournalKind: String, CaseIterable {
        case install
        case rollback
    }

    private enum AppEscape: String, CaseIterable {
        case bundle
        case contents
        case macOS
        case binary
    }

    @Test("flat install and rollback journals reject an external bin symlink")
    func flatComponentSymlinkCannotWriteExternalSentinel() throws {
        for kind in JournalKind.allCases {
            let journal = try UpdateRecoveryJournalFixture(layout: .flat)
            defer { journal.cleanup() }
            var transaction = try journal.transactionObject()
            let stagingRoot = try prepare(
                transaction: &transaction,
                kind: kind,
                journal: journal
            )
            let stagedBin = stagingRoot.appendingPathComponent("bin")
            let outside = journal.base.root.appendingPathComponent(
                "outside-flat-\(kind.rawValue)",
                isDirectory: true
            )
            let outsideBin = outside.appendingPathComponent(
                "payload",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: stagedBin, to: outsideBin)

            // The vulnerable replay writes this canonical link through a
            // promoted `bin` symlink. Bind the malicious journal hash so the
            // old implementation reaches that write instead of falling back.
            let externalSentinel = outsideBin.appendingPathComponent(
                "eigeninference-enclave"
            )
            try FileManager.default.removeItem(at: externalSentinel)
            try Data("external-flat-sentinel".utf8).write(
                to: externalSentinel
            )
            try replaceTargetTreeHash(
                in: &transaction,
                with: UpdateAtomicFilesystem.treeHash(root: outsideBin)
            )
            try replaceWithSymlink(stagedBin, target: outsideBin)
            try journal.writeTransactionObject(transaction)

            try assertRecoveryRefusesAndPreservesEvidence(
                journal: journal,
                stagingRoot: stagingRoot,
                externalRoot: outside,
                context: "\(kind.rawValue)-flat"
            )
            #expect(
                try String(
                    contentsOf: externalSentinel,
                    encoding: .utf8
                ) == "external-flat-sentinel"
            )
        }
    }

    @Test("app journal components and payload ancestors cannot escape staging")
    func appComponentAndChildSymlinksAreRejected() throws {
        for kind in JournalKind.allCases {
            for escape in AppEscape.allCases {
                let journal = try UpdateRecoveryJournalFixture(layout: .app)
                defer { journal.cleanup() }
                var transaction = try journal.transactionObject()
                let stagingRoot = try prepare(
                    transaction: &transaction,
                    kind: kind,
                    journal: journal
                )
                let stagedApp = stagingRoot.appendingPathComponent(
                    "Darkbloom.app"
                )
                let outside = journal.base.root.appendingPathComponent(
                    "outside-app-\(kind.rawValue)-\(escape.rawValue)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: outside,
                    withIntermediateDirectories: true
                )
                let externalSentinel = outside.appendingPathComponent(
                    "external-sentinel"
                )
                try Data("external-app-sentinel".utf8).write(
                    to: externalSentinel
                )

                switch escape {
                case .bundle:
                    let externalApp = outside.appendingPathComponent(
                        "Darkbloom.app"
                    )
                    try FileManager.default.copyItem(
                        at: stagedApp,
                        to: externalApp
                    )
                    try replaceWithSymlink(stagedApp, target: externalApp)

                case .contents:
                    let contents = stagedApp.appendingPathComponent("Contents")
                    let externalContents = outside.appendingPathComponent(
                        "Contents"
                    )
                    try FileManager.default.copyItem(
                        at: contents,
                        to: externalContents
                    )
                    try replaceWithSymlink(
                        contents,
                        target: externalContents
                    )
                    try replaceTargetTreeHash(
                        in: &transaction,
                        with: UpdateAtomicFilesystem.treeHash(root: stagedApp)
                    )

                case .macOS:
                    let macOS = stagedApp.appendingPathComponent(
                        "Contents/MacOS"
                    )
                    let externalMacOS = outside.appendingPathComponent("MacOS")
                    try FileManager.default.copyItem(
                        at: macOS,
                        to: externalMacOS
                    )
                    try replaceWithSymlink(macOS, target: externalMacOS)
                    try replaceTargetTreeHash(
                        in: &transaction,
                        with: UpdateAtomicFilesystem.treeHash(root: stagedApp)
                    )

                case .binary:
                    let binary = stagedApp.appendingPathComponent(
                        "Contents/MacOS/darkbloom"
                    )
                    let externalBinary = outside.appendingPathComponent(
                        "darkbloom"
                    )
                    try FileManager.default.copyItem(
                        at: binary,
                        to: externalBinary
                    )
                    try replaceWithSymlink(binary, target: externalBinary)
                    try replaceTargetTreeHash(
                        in: &transaction,
                        with: UpdateAtomicFilesystem.treeHash(root: stagedApp)
                    )
                }
                try journal.writeTransactionObject(transaction)

                try assertRecoveryRefusesAndPreservesEvidence(
                    journal: journal,
                    stagingRoot: stagingRoot,
                    externalRoot: outside,
                    context:
                        "\(kind.rawValue)-app-\(escape.rawValue)"
                )
                #expect(
                    try String(
                        contentsOf: externalSentinel,
                        encoding: .utf8
                    ) == "external-app-sentinel"
                )
            }
        }
    }

    @Test("app canonical bin symlink cannot redirect recovery writes")
    func appCanonicalBinSymlinkCannotWriteExternalFiles() throws {
        for kind in JournalKind.allCases {
            let journal = try UpdateRecoveryJournalFixture(layout: .app)
            defer { journal.cleanup() }
            try journal.installExactTargetCopyAsLive()

            var transaction = try journal.transactionObject()
            let stagingRoot = try prepare(
                transaction: &transaction,
                kind: kind,
                journal: journal
            )
            try journal.writeTransactionObject(transaction)

            let liveBin = journal.base.installRoot.appendingPathComponent("bin")
            let outside = journal.base.root.appendingPathComponent(
                "outside-canonical-bin-\(kind.rawValue)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            let externalSentinel = outside.appendingPathComponent("darkbloom")
            try Data("external-canonical-sentinel".utf8).write(
                to: externalSentinel
            )
            try replaceWithSymlink(liveBin, target: outside)

            try assertRecoveryRefusesAndPreservesEvidence(
                journal: journal,
                stagingRoot: stagingRoot,
                externalRoot: outside,
                context: "\(kind.rawValue)-app-canonical-bin"
            )
            #expect(
                try String(
                    contentsOf: externalSentinel,
                    encoding: .utf8
                ) == "external-canonical-sentinel"
            )
        }
    }

    @Test("wrong component and payload node types retain the journal")
    func wrongNodeTypesAreRejected() throws {
        for layout in [
            VerifiedPredecessor.Layout.flat,
            VerifiedPredecessor.Layout.app,
        ] {
            let journal = try UpdateRecoveryJournalFixture(layout: layout)
            defer { journal.cleanup() }
            let transaction = try journal.transactionObject()
            let stagingRoot = journal.staged.stagingRoot
            let unsafePath: URL
            switch layout {
            case .flat:
                unsafePath = stagingRoot.appendingPathComponent("bin")
                try FileManager.default.removeItem(at: unsafePath)
                try Data("not-a-directory".utf8).write(to: unsafePath)
            case .app:
                unsafePath = stagingRoot.appendingPathComponent(
                    "Darkbloom.app/Contents/MacOS/darkbloom"
                )
                try FileManager.default.removeItem(at: unsafePath)
                try FileManager.default.createDirectory(
                    at: unsafePath,
                    withIntermediateDirectories: false
                )
            }
            try journal.writeTransactionObject(transaction)

            try assertRecoveryRefusesAndPreservesEvidence(
                journal: journal,
                stagingRoot: stagingRoot,
                externalRoot: nil,
                context: "wrong-node-\(layout.rawValue)"
            )
            #expect(UpdateAtomicFilesystem.itemExists(unsafePath))
        }
    }

    @Test("replacement after validation cannot promote a symlink")
    func stagingReplacementRaceIsRejected() throws {
        let journal = try UpdateRecoveryJournalFixture(layout: .flat)
        defer { journal.cleanup() }
        let stagingRoot = journal.staged.stagingRoot
        let stagedBin = stagingRoot.appendingPathComponent("bin")
        let outside = journal.base.root.appendingPathComponent(
            "outside-race",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let outsideBin = outside.appendingPathComponent("bin")
        try FileManager.default.copyItem(at: stagedBin, to: outsideBin)
        let externalSentinel = outside.appendingPathComponent("sentinel")
        try Data("race-sentinel".utf8).write(to: externalSentinel)

        let oneShot = OneShotFault()
        let store = UpdateRecoveryStore(
            installRoot: journal.base.installRoot,
            verifyCodeSignatures: false,
            recoveryReplayHook: {
                guard oneShot.claim() else { return }
                try FileManager.default.removeItem(at: stagedBin)
                try FileManager.default.createSymbolicLink(
                    at: stagedBin,
                    withDestinationURL: outsideBin
                )
            }
        )

        try expectCorruptTransaction(
            store,
            operation: "staging-replacement-race"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: journal.transactionPath.path
            )
        )
        #expect(
            try String(
                contentsOf: externalSentinel,
                encoding: .utf8
            ) == "race-sentinel"
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: stagedBin.path
            ) == outsideBin.path
        )
    }

    private func prepare(
        transaction: inout [String: Any],
        kind: JournalKind,
        journal: UpdateRecoveryJournalFixture
    ) throws -> URL {
        transaction["kind"] = kind.rawValue
        guard kind == .rollback else {
            return journal.staged.stagingRoot
        }
        let rollbackRoot = journal.base.installRoot.appendingPathComponent(
            ".rollback-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: journal.staged.stagingRoot,
            to: rollbackRoot
        )
        transaction["staging_root"] = rollbackRoot.path
        return rollbackRoot
    }

    private func replaceTargetTreeHash(
        in transaction: inout [String: Any],
        with hash: String
    ) throws {
        guard var target = transaction["target"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        target["installed_bundle_hash"] = hash
        transaction["target"] = target
    }

    private func replaceWithSymlink(_ path: URL, target: URL) throws {
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(
            at: path,
            withDestinationURL: target
        )
    }

    private func assertRecoveryRefusesAndPreservesEvidence(
        journal: UpdateRecoveryJournalFixture,
        stagingRoot: URL,
        externalRoot: URL?,
        context: String
    ) throws {
        let journalBytes = try Data(contentsOf: journal.transactionPath)
        let stateBefore = try journal.store.loadState()
        let liveBefore = try journal.base.liveBinaryContents()
        let externalHash = try externalRoot.map {
            try UpdateAtomicFilesystem.treeHash(root: $0)
        }

        for attempt in 0..<2 {
            try expectCorruptTransaction(
                journal.store,
                operation: "\(context)-\(attempt)"
            )
            #expect(try Data(contentsOf: journal.transactionPath) == journalBytes)
            #expect(try journal.store.loadState() == stateBefore)
            #expect(try journal.base.liveBinaryContents() == liveBefore)
            #expect(try journal.base.persistentStateIsIntact())
            #expect(UpdateAtomicFilesystem.itemExists(stagingRoot))
            if let externalRoot, let externalHash {
                #expect(
                    try UpdateAtomicFilesystem.treeHash(root: externalRoot)
                        == externalHash
                )
            }
        }
    }

    private func expectCorruptTransaction(
        _ store: UpdateRecoveryStore,
        operation: String
    ) throws {
        let lock = try UpdateProcessLock.acquire(
            at: store.lockPath,
            operation: operation
        )
        defer { lock.release() }
        do {
            try store.recoverInterruptedTransaction(now: 200)
            Issue.record("unsafe recovery path was accepted during \(operation)")
        } catch UpdateRecoveryStore.StoreError.corruptTransaction {
            return
        } catch {
            Issue.record(
                "unsafe recovery path produced the wrong error during "
                    + "\(operation): \(error)"
            )
        }
    }
}
