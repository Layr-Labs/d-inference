import Foundation
import XCTest
@testable import ProviderAppAttest

private final class AssertionInvocationSpy: AppAttestCallbacks, @unchecked Sendable {
    private let lock = NSLock()
    private let immediate: Result<Data, Error>?
    private var invocations: [(String, Data)] = []
    private var completions: [@Sendable (Result<Data, Error>) -> Void] = []

    init(immediate: Result<Data, Error>? = .success(Data([1, 2, 3]))) { self.immediate = immediate }
    var count: Int { lock.withLock { invocations.count } }
    var lastKey: String? { lock.withLock { invocations.last?.0 } }
    var lastHash: Data? { lock.withLock { invocations.last?.1 } }

    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) { complete(.success("key")) }
    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        complete(.success(Data([4, 5, 6])))
    }
    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        lock.withLock {
            invocations.append((id, hash))
            completions.append(complete)
        }
        if let immediate { complete(immediate) }
    }
    func complete(_ index: Int, with result: Result<Data, Error>) {
        let callback = lock.withLock { completions[index] }
        callback(result)
    }
}

private final class AssertionFaultObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AppAttestWorkerClient.QualificationAssertionEvent.Phase] = []
    var phases: [AppAttestWorkerClient.QualificationAssertionEvent.Phase] { lock.withLock { values } }
    func record(_ phase: AppAttestWorkerClient.QualificationAssertionEvent.Phase) { lock.withLock { values.append(phase) } }
}

final class QualificationAssertionCallbacksTests: XCTestCase {
    func testUnarmedWorkerForwardsCallbacksAndQualificationPermissionIsRequired() async throws {
        let spy = AssertionInvocationSpy()
        let wrapper = QualificationAssertionCallbacks(qualificationAllowed: false, underlying: spy)
        XCTAssertThrowsError(try wrapper.armNextAssertion { _ in XCTFail("not armed") }) {
            XCTAssertEqual($0 as? AppAttestWorkerError, .qualificationRequired)
        }
        let service = AppleAppAttestService(callbacks: wrapper, operationTimeout: 0.1)
        let key = try await service.generateKey()
        let attestation = try await service.attestKey(key, hash: Data([7]))
        let proof = try await service.generateAssertion(key, hash: Data([8]))
        XCTAssertEqual(key, "key")
        XCTAssertEqual(attestation, Data([4, 5, 6]))
        XCTAssertEqual(proof, Data([1, 2, 3]))
        XCTAssertEqual(spy.count, 1)
        XCTAssertEqual(spy.lastHash, Data([8]))
        let held = await service.operationHeldSince()
        XCTAssertNil(held)
    }

    func testDiscardedInlineCallbackNeverReleasesRealAdapterGate() async throws {
        let spy = AssertionInvocationSpy(), observations = AssertionFaultObservations()
        let wrapper = QualificationAssertionCallbacks(qualificationAllowed: true, underlying: spy)
        try wrapper.armNextAssertion { phase in
            XCTAssertEqual(spy.count, 1, "entry evidence must follow the actual adapter invocation")
            observations.record(phase)
        }
        let service = AppleAppAttestService(callbacks: wrapper, operationTimeout: 0.01)
        let hash = Data(repeating: 9, count: 32)
        do { _ = try await service.generateAssertion("existing-key", hash: hash); XCTFail("discarded callback completed") }
        catch { XCTAssertEqual(error as? ShadowFailure, .operationTimeout) }
        let held = await service.operationHeldSince()
        XCTAssertNotNil(held)
        XCTAssertEqual(spy.count, 1)
        XCTAssertEqual(spy.lastKey, "existing-key")
        XCTAssertEqual(spy.lastHash, hash)
        XCTAssertEqual(observations.phases, [.submitted, .callbackDiscarded])
        do { _ = try await service.generateAssertion("existing-key", hash: hash); XCTFail("overlapped held operation") }
        catch { XCTAssertEqual(error as? ShadowFailure, .busy) }
        do { _ = try await service.generateKey(); XCTFail("assertion fault must hold the shared Apple gate") }
        catch { XCTAssertEqual(error as? ShadowFailure, .busy) }
        spy.complete(0, with: .success(Data([99])))
        let stillHeld = await service.operationHeldSince()
        XCTAssertEqual(stillHeld, held, "even a late duplicate callback must never finish the old gate")
        XCTAssertEqual(spy.count, 1)
        XCTAssertEqual(observations.phases, [.submitted, .callbackDiscarded])
    }

    func testAsynchronousErrorCallbackIsAlsoWithheldAndReportedOnce() async throws {
        let spy = AssertionInvocationSpy(immediate: nil), observations = AssertionFaultObservations()
        let wrapper = QualificationAssertionCallbacks(qualificationAllowed: true, underlying: spy)
        let submitted = expectation(description: "real adapter invocation submitted")
        try wrapper.armNextAssertion { phase in
            observations.record(phase)
            if phase == .submitted { submitted.fulfill() }
        }
        let service = AppleAppAttestService(callbacks: wrapper, operationTimeout: 0.1)
        let operation = Task { try await service.generateAssertion("existing-key", hash: Data([1])) }
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(observations.phases, [.submitted])
        spy.complete(0, with: .failure(ShadowFailure.appleUnavailable))
        spy.complete(0, with: .success(Data([42])))
        do { _ = try await operation.value; XCTFail("error/duplicate callbacks must not escape the fault") }
        catch { XCTAssertEqual(error as? ShadowFailure, .operationTimeout) }
        XCTAssertEqual(observations.phases, [.submitted, .callbackDiscarded])
        let held = await service.operationHeldSince()
        XCTAssertNotNil(held)
    }

    func testFaultIsOncePerWorkerAndDoesNotConsumeOtherAppleOperations() async throws {
        let wrapper = QualificationAssertionCallbacks(qualificationAllowed: true, underlying: AssertionInvocationSpy())
        try wrapper.armNextAssertion { _ in }
        XCTAssertThrowsError(try wrapper.armNextAssertion { _ in })
        let service = AppleAppAttestService(callbacks: wrapper, operationTimeout: 0.01)
        _ = try await service.generateKey()
        _ = try await service.attestKey("key", hash: Data())
        XCTAssertTrue(wrapper.requiresNextAssertion)
        do { _ = try await service.generateAssertion("key", hash: Data()); XCTFail("armed assertion completed") }
        catch { XCTAssertEqual(error as? ShadowFailure, .operationTimeout) }
        XCTAssertFalse(wrapper.requiresNextAssertion)
        XCTAssertThrowsError(try wrapper.armNextAssertion { _ in })
    }

    func testFreshWorkerAdapterIsUnarmedWithoutFinishingTheOldGate() async throws {
        let spy = AssertionInvocationSpy()
        let old = QualificationAssertionCallbacks(qualificationAllowed: true, underlying: spy)
        try old.armNextAssertion { _ in }
        let oldService = AppleAppAttestService(callbacks: old, operationTimeout: 0.01)
        do { _ = try await oldService.generateAssertion("persisted-key", hash: Data([1])); XCTFail("old callback escaped") }
        catch { XCTAssertEqual(error as? ShadowFailure, .operationTimeout) }
        let oldHeld = await oldService.operationHeldSince()
        let replacement = QualificationAssertionCallbacks(qualificationAllowed: true, underlying: spy)
        let newService = AppleAppAttestService(callbacks: replacement, operationTimeout: 0.1)
        let proof = try await newService.generateAssertion("persisted-key", hash: Data([2]))
        XCTAssertEqual(proof, Data([1, 2, 3]))
        XCTAssertEqual(spy.lastKey, "persisted-key")
        XCTAssertEqual(spy.lastHash, Data([2]))
        XCTAssertEqual(spy.count, 2)
        let stillHeld = await oldService.operationHeldSince()
        XCTAssertEqual(stillHeld, oldHeld)
        XCTAssertNotNil(stillHeld)
        // Process tests separately require actual kill/reap before replacement;
        // these independent fake transports do not qualify real Apple recovery.
    }
}
