import Foundation
import XCTest
@testable import BootContinuity

final class BootCustodianTests: XCTestCase, @unchecked Sendable {
    func testDisabledPerformsNoApplicationHardwareOrStorageIO() async throws {
        let fixture = Fixture(activation: .disabled)
        let result = try await fixture.custodian.recover(context: makeContext())
        guard case .disabled = result else { return XCTFail("Expected disabled") }
        do { _ = try await fixture.custodian.prepareCandidateForBootstrap(context: makeContext()); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? BootContinuityError, .disabled) }
        XCTAssertEqual(fixture.store.reads, 0)
        XCTAssertEqual(fixture.store.inserts, 0)
        XCTAssertEqual(fixture.application.checks, 0)
        XCTAssertEqual(fixture.engine.creates, 0)
        XCTAssertEqual(fixture.engine.recovers, 0)
    }

    func testApplicationAndReleaseMismatchRejectBeforeKeychainAccess() async throws {
        let fixture = Fixture()
        fixture.application.failure = .applicationNotPermitted
        await assertCustodyError(.applicationNotPermitted) { _ = try await fixture.custodian.recover(context: makeContext()) }
        fixture.application.failure = nil
        await assertCustodyError(.releaseMismatch) { _ = try await fixture.custodian.recover(context: makeContext(release: "claimed")) }
        XCTAssertEqual(fixture.store.reads, 0)
        XCTAssertEqual(fixture.engine.creates, 0)
    }

    func testContextUsesVerifiedReleaseAndAbsentRecoveryDoesNotCreate() async throws {
        let fixture = Fixture()
        let context = try await fixture.custodian.makeContext(accountID: "account", deviceID: "device", coordinatorOrigin: "https://example.test", policyGeneration: 1)
        XCTAssertEqual(context.releaseID, fixture.application.release)
        guard case .absent = try await fixture.custodian.recover(context: context) else { return XCTFail("Expected absent") }
        XCTAssertEqual(fixture.engine.creates, 0)
        XCTAssertEqual(fixture.store.inserts, 0)
    }

    func testExplicitCandidateCanRecoverAcrossCustodianInstances() async throws {
        let fixture = Fixture()
        let context = try makeContext()
        let candidate = try await fixture.custodian.prepareCandidateForBootstrap(context: context)
        await fixture.custodian.forgetRecoveredSession()
        let next = BootContinuityCustodian(activation: .experimental, store: fixture.store, engine: fixture.engine, application: fixture.application)
        guard case let .recovered(descriptor) = try await next.recover(context: context) else { return XCTFail("Expected recovered") }
        XCTAssertEqual(candidate.publicKey, descriptor.publicKey)
        XCTAssertEqual(fixture.engine.creates, 1)
        let challenge = try BootContinuationChallenge(nonce: Data(repeating: 1, count: 32), processPublicKey: Data(repeating: 2, count: 32))
        let proof = try await next.provePossession(challenge: challenge)
        XCTAssertEqual(proof.publicKey, candidate.publicKey)
    }

    func testLockedStorageAndUnusableKeysPreserveRecordsAndNeverRotate() async throws {
        let fixture = Fixture()
        let context = try makeContext()
        _ = try await fixture.custodian.prepareCandidateForBootstrap(context: context)
        let retained = fixture.store.records
        fixture.store.failure = .keychainFailure(-25308)
        await assertCustodyError(.keychainFailure(-25308)) { _ = try await fixture.custodian.recover(context: context) }
        await assertCustodyError(.keychainFailure(-25308)) { _ = try await fixture.custodian.prepareCandidateForBootstrap(context: context) }
        fixture.store.failure = nil
        fixture.engine.keys.removeAll()
        do { _ = try await fixture.custodian.recover(context: context); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? BootContinuityError, .keyUnavailable) }
        await assertCustodyError(.recordAlreadyExists) { _ = try await fixture.custodian.prepareCandidateForBootstrap(context: context) }
        XCTAssertEqual(fixture.store.records, retained)
        XCTAssertEqual(fixture.engine.creates, 1)
        XCTAssertEqual(fixture.store.inserts, 1)
    }

    func testInsertRaceCannotActivateLosingCandidate() async throws {
        let fixture = Fixture()
        fixture.store.insertFailure = .recordAlreadyExists
        await assertCustodyError(.recordAlreadyExists) { _ = try await fixture.custodian.prepareCandidateForBootstrap(context: makeContext()) }
        let challenge = try BootContinuationChallenge(nonce: Data(repeating: 1, count: 32), processPublicKey: Data(repeating: 2, count: 32))
        await assertCustodyError(.noRecoveredSession) { _ = try await fixture.custodian.provePossession(challenge: challenge) }
        XCTAssertTrue(fixture.store.records.isEmpty)
    }

    func testRecordCopyAndMetadataRewriteCannotChangeContext() async throws {
        let fixture = Fixture()
        let original = try makeContext()
        _ = try await fixture.custodian.prepareCandidateForBootstrap(context: original)
        let foreign = try makeContext(account: "different-account")
        let record = try XCTUnwrap(fixture.store.records[DataProtectionBootIdentityStore.accountLocator(context: original)])
        let locator = DataProtectionBootIdentityStore.accountLocator(context: foreign)
        fixture.store.records[locator] = record
        do { _ = try await fixture.custodian.recover(context: foreign); XCTFail("must reject copied record") }
        catch { XCTAssertEqual(error as? BootContinuityError, .contextMismatch) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        var rewritten = try XCTUnwrap(object["context"] as? [String: Any])
        rewritten["accountID"] = foreign.accountID
        object["context"] = rewritten
        fixture.store.records[locator] = try JSONSerialization.data(withJSONObject: object)
        do { _ = try await fixture.custodian.recover(context: foreign); XCTFail("must reject rewritten record") }
        catch { XCTAssertEqual(error as? BootContinuityError, .invalidRecord) }
        XCTAssertEqual(fixture.engine.recovers, 0)
        XCTAssertEqual(fixture.engine.creates, 1)
    }

    func testRejectedRecoveryClearsEarlierInMemorySession() async throws {
        let fixture = Fixture()
        _ = try await fixture.custodian.prepareCandidateForBootstrap(context: makeContext())
        fixture.application.failure = .applicationNotPermitted
        await assertCustodyError(.applicationNotPermitted) { _ = try await fixture.custodian.recover(context: makeContext()) }
        fixture.application.failure = nil
        let challenge = try BootContinuationChallenge(nonce: Data(repeating: 1, count: 32), processPublicKey: Data(repeating: 2, count: 32))
        await assertCustodyError(.noRecoveredSession) { _ = try await fixture.custodian.provePossession(challenge: challenge) }
    }
}

private struct Fixture {
    let store = MemoryStore()
    let engine = MemoryEngine()
    let application = MemoryApplication()
    let custodian: BootContinuityCustodian
    init(activation: BootContinuityActivation = .experimental) {
        custodian = BootContinuityCustodian(activation: activation, store: store, engine: engine, application: application)
    }
}

private final class MemoryStore: BootIdentityStore, @unchecked Sendable {
    var records: [String: Data] = [:]
    var reads = 0
    var inserts = 0
    var failure: BootCustodyError?
    var insertFailure: BootCustodyError?
    func read(context: BootContinuityContext) throws -> Data? {
        reads += 1
        if let failure { throw failure }
        return records[DataProtectionBootIdentityStore.accountLocator(context: context)]
    }
    func insert(_ data: Data, context: BootContinuityContext) throws {
        inserts += 1
        if let failure = insertFailure ?? failure { throw failure }
        let key = DataProtectionBootIdentityStore.accountLocator(context: context)
        guard records[key] == nil else { throw BootCustodyError.recordAlreadyExists }
        records[key] = data
    }
}

private final class MemoryApplication: BootApplicationScope, @unchecked Sendable {
    var release = "release-sha256"
    var checks = 0
    var failure: BootCustodyError?
    func currentReleaseID() throws -> String {
        checks += 1
        if let failure { throw failure }
        return release
    }
}

private func assertCustodyError(_ error: BootCustodyError, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected \(error)", file: file, line: line) }
    catch let caught { XCTAssertEqual(caught as? BootCustodyError, error, file: file, line: line) }
}
