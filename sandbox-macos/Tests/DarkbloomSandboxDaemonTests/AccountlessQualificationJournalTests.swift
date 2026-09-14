import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessQualificationJournalTests: XCTestCase {
    func testIntentIsStableAndRecoveryDoesNotRequireGuestPackageToRemainReadable() async throws {
        let f = try await fixture(), path = try directory(f)
        let initial: AccountlessQualificationIntent
        do {
            let journal = try open(f, path: path)
            XCTAssertTrue(journal.isNew); initial = journal.intent
            XCTAssertThrowsError(try open(f, path: path))
        }
        let reopened = try AccountlessQualificationJournal(directory: path, permit: f.boot.permit, collection: collection(f),
            capacityDirectory: URL(fileURLWithPath: "/operator/capacity"), guestReleaseDirectory: URL(fileURLWithPath: "/operator/release"),
            guestReleaseSHA256: missingRelease())
        XCTAssertFalse(reopened.isNew); XCTAssertEqual(reopened.intent, initial)
        XCTAssertNil(try reopened.lease()); XCTAssertNil(try reopened.ready())
        XCTAssertThrowsError(try reopened.recordPublished())
        try reopened.recordAborted(); XCTAssertTrue(try reopened.aborted())
        XCTAssertThrowsError(try reopened.recordLease(lease(initial)))
    }

    func testAllocationGapResolvesOnlyExactOriginalLeaseIncludingExpiryAndResources() async throws {
        let f = try await fixture(), path = try directory(f)
        let journal = try open(f, path: path), intent = journal.intent, original = try lease(journal.intent)
        XCTAssertEqual(try AccountlessQualificationRecovery.activeLease(intent: intent, saved: nil, leases: [original]), original)
        try journal.recordLease(original)
        XCTAssertEqual(try journal.lease(), original)
        XCTAssertNil(try AccountlessQualificationRecovery.activeLease(intent: intent, saved: original, leases: []))
        for field in ["expiry", "cpu", "sandbox", "name"] {
            let changed = try lease(intent, mutation: field)
            XCTAssertThrowsError(try AccountlessQualificationRecovery.activeLease(intent: intent, saved: original, leases: [changed]), field)
        }
        let fenced = try lease(intent, token: 2)
        XCTAssertEqual(try AccountlessQualificationRecovery.activeLease(intent: intent, saved: original, leases: [fenced]), fenced)
        XCTAssertThrowsError(try AccountlessQualificationRecovery.activeLease(intent: intent, saved: fenced, leases: [original]))
        XCTAssertThrowsError(try AccountlessQualificationRecovery.activeLease(intent: intent, saved: original, leases: [original, fenced]))
    }

    func testConflictingInputsAndOrphanRecordsDoNotCreateAnAttempt() async throws {
        let f = try await fixture(), path = try directory(f)
        do { _ = try open(f, path: path) }
        XCTAssertThrowsError(try AccountlessQualificationJournal(directory: path, permit: f.boot.permit, collection: collection(f),
            capacityDirectory: URL(fileURLWithPath: "/another/capacity"), guestReleaseDirectory: URL(fileURLWithPath: "/operator/release"),
            guestReleaseSHA256: String(repeating: "a", count: 64)))
        let orphan = try directory(f)
        try Data("{}".utf8).write(to: orphan.appendingPathComponent("lease.json"))
        XCTAssertEqual(chmod(orphan.appendingPathComponent("lease.json").path, 0o600), 0)
        XCTAssertThrowsError(try open(f, path: orphan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.appendingPathComponent("intent.json").path))
    }

    func testUnknownSameNamePathsNeverCountAsAbsent() async throws {
        let f = try await fixture(), storage = try directory(f)
        try AccountlessQualificationRecovery.requireAbsent(name: "clone", storage: storage)
        let path = storage.appendingPathComponent("clone")
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/missing/target")
        XCTAssertThrowsError(try AccountlessQualificationRecovery.requireAbsent(name: "clone", storage: storage))
        try FileManager.default.removeItem(at: path)
        try Data().write(to: path)
        XCTAssertThrowsError(try AccountlessQualificationRecovery.requireAbsent(name: "clone", storage: storage))
    }

    private func open(_ f: AccountlessCollectionTestFixture, path: URL) throws -> AccountlessQualificationJournal {
        try .init(directory: path, permit: f.boot.permit, collection: collection(f),
            capacityDirectory: URL(fileURLWithPath: "/operator/capacity"), guestReleaseDirectory: URL(fileURLWithPath: "/operator/release"),
            guestReleaseSHA256: String(repeating: "a", count: 64), now: Date(timeIntervalSince1970: 2_000_000_000))
    }
    private func collection(_ f: AccountlessCollectionTestFixture) throws -> AccountlessCollectionRecord {
        let journal = try f.journal()
        if try journal.completion() == nil {
            try f.collector(journal).collect(dataDirectory: f.data, volumeUUID: f.volumeUUID)
            try journal.recordDetached(f.boot.staging.cleanup, aborted: false)
        }
        return try AccountlessCollectionRecord.make(journal: journal)
    }
    private func directory(_ f: AccountlessCollectionTestFixture) throws -> URL {
        let path = f.directory.deletingLastPathComponent().appendingPathComponent("qualification-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }
    private func fixture() async throws -> AccountlessCollectionTestFixture {
        let f = try await AccountlessCollectionTestFixture(); addTeardownBlock { f.remove() }; return f
    }
    private func missingRelease() throws -> String { throw POSIXError(.ENOENT) }
    private func lease(_ intent: AccountlessQualificationIntent, token: UInt64 = 1, mutation: String = "") throws -> SandboxCapacityLease {
        let candidate = try intent.permit.candidate()
        return .init(scope: .init(sandboxID: mutation == "sandbox" ? SandboxID() : intent.sandboxID,
            generation: intent.generation, fencingToken: SandboxFencingToken(rawValue: token)!),
            virtualMachineName: mutation == "name" ? "another" : intent.cloneName,
            cpuCount: mutation == "cpu" ? candidate.resources.cpuCount + 1 : candidate.resources.cpuCount,
            memoryBytes: candidate.resources.memoryBytes, workspaceBytes: candidate.resources.workspaceBytes,
            bootDiskBytes: candidate.disk.size, reservedGrowthBytes: try SandboxStorageReservation.growthBytes(
                bootDiskBytes: candidate.disk.size, workspaceBytes: candidate.resources.workspaceBytes),
            issuedAt: intent.expiresAt.addingTimeInterval(-300),
            expiresAt: intent.expiresAt.addingTimeInterval(mutation == "expiry" ? 1 : 0))
    }
}
