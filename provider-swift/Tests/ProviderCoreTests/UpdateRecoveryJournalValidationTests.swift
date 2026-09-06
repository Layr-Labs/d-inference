import Foundation
import Testing
@testable import ProviderCore

@Suite("Update recovery journal validation", .serialized)
struct UpdateRecoveryJournalValidationTests {
    private enum MetadataCorruption: CaseIterable {
        case unsupportedSchema
        case schemaOneCarriesGeneration
        case schemaTwoMissingGeneration
        case generationHasWrongType
        case targetGenerationMismatch

        var expectedReason: String? {
            switch self {
            case .unsupportedSchema:
                return "unsupported schema"
            case .schemaOneCarriesGeneration:
                return "schema 1 unexpectedly records"
            case .schemaTwoMissingGeneration:
                return "missing its resulting install generation"
            case .generationHasWrongType:
                return nil
            case .targetGenerationMismatch:
                return "generation does not match its target"
            }
        }

        func apply(to object: inout [String: Any]) throws {
            switch self {
            case .unsupportedSchema:
                object["schema"] = 99
            case .schemaOneCarriesGeneration:
                object["schema"] = 1
            case .schemaTwoMissingGeneration:
                object.removeValue(forKey: "resulting_install_generation")
            case .generationHasWrongType:
                object["resulting_install_generation"] = "not-a-generation"
            case .targetGenerationMismatch:
                guard var target = object["target"] as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                target["install_generation"] = 999
                object["target"] = target
            }
        }
    }

    private enum UnsafeStagingPath: CaseIterable {
        case absoluteSibling
        case parentTraversal
        case installRootItself
        case symlinkEscape
    }

    @Test("corrupt schema and generation metadata fail closed on every restart")
    func corruptMetadataIsRetainedForDiagnosis() throws {
        for corruption in MetadataCorruption.allCases {
            let journal = try UpdateRecoveryJournalFixture()
            defer { journal.cleanup() }
            var object = try journal.transactionObject()
            try corruption.apply(to: &object)
            try journal.writeTransactionObject(object)

            let journalBytes = try Data(contentsOf: journal.transactionPath)
            let stateBefore = try journal.store.loadState()
            let liveBefore = try journal.base.liveBinaryContents()

            for attempt in 0..<2 {
                try expectCorruptTransaction(
                    journal.store,
                    operation: "metadata-\(corruption)-\(attempt)",
                    expectedReason: corruption.expectedReason
                )
                #expect(try Data(contentsOf: journal.transactionPath) == journalBytes)
                #expect(try journal.store.loadState() == stateBefore)
                #expect(try journal.base.liveBinaryContents() == liveBefore)
                #expect(try journal.base.persistentStateIsIntact())
                #expect(
                    FileManager.default.fileExists(
                        atPath: journal.staged.stagingRoot.path
                    )
                )
            }
        }
    }

    @Test("untrusted staging paths are rejected before a valid live target is finalized")
    func stagingPathEscapesFailClosedBeforeLiveFastPath() throws {
        for pathCase in UnsafeStagingPath.allCases {
            let journal = try UpdateRecoveryJournalFixture()
            defer { journal.cleanup() }
            var object = try journal.transactionObject()
            let target = try journal.targetRecord(from: object)
            try journal.installExactTargetCopyAsLive()
            #expect(try journal.store.liveMatches(target, layout: .app))

            let outside = journal.base.root.appendingPathComponent(
                "outside-\(pathCase)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            let outsideSentinel = outside.appendingPathComponent("sentinel")
            try Data("outside-must-remain".utf8).write(to: outsideSentinel)

            let untrustedPath: String
            switch pathCase {
            case .absoluteSibling:
                untrustedPath = outside.path
            case .parentTraversal:
                untrustedPath =
                    journal.base.installRoot.path + "/../\(outside.lastPathComponent)"
            case .installRootItself:
                untrustedPath = journal.base.installRoot.path
            case .symlinkEscape:
                let link = journal.base.installRoot.appendingPathComponent(
                    ".update-staging-symlink-escape"
                )
                try FileManager.default.createSymbolicLink(
                    at: link,
                    withDestinationURL: outside
                )
                untrustedPath = link.path
            }
            object["staging_root"] = untrustedPath
            try journal.writeTransactionObject(object)

            let journalBytes = try Data(contentsOf: journal.transactionPath)
            let stateBefore = try journal.store.loadState()
            let liveBefore = try journal.base.liveBinaryContents()

            for attempt in 0..<2 {
                try expectCorruptTransaction(
                    journal.store,
                    operation: "staging-path-\(pathCase)-\(attempt)",
                    expectedReason: "staging"
                )
                #expect(try Data(contentsOf: journal.transactionPath) == journalBytes)
                #expect(try journal.store.loadState() == stateBefore)
                #expect(try journal.base.liveBinaryContents() == liveBefore)
                #expect(try journal.store.liveMatches(target, layout: .app))
                #expect(
                    try String(contentsOf: outsideSentinel, encoding: .utf8)
                        == "outside-must-remain"
                )
                #expect(
                    FileManager.default.fileExists(
                        atPath: journal.staged.stagingRoot.path
                    )
                )
            }
        }
    }

    private func expectCorruptTransaction(
        _ store: UpdateRecoveryStore,
        operation: String,
        expectedReason: String?
    ) throws {
        let lock = try UpdateProcessLock.acquire(
            at: store.lockPath,
            operation: operation
        )
        defer { lock.release() }
        do {
            try store.recoverInterruptedTransaction(now: 200)
            Issue.record("corrupt transaction was accepted during \(operation)")
        } catch UpdateRecoveryStore.StoreError.corruptTransaction(let reason) {
            if let expectedReason {
                #expect(
                    reason.contains(expectedReason),
                    "unexpected refusal for \(operation): \(reason)"
                )
            }
        } catch {
            Issue.record(
                "corrupt transaction produced the wrong error during \(operation): \(error)"
            )
        }
    }
}
