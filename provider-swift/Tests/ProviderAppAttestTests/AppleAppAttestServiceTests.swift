import Foundation
import XCTest
@testable import ProviderAppAttest

private final class CapturedCallback<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Result<Value, Error>) -> Void] = []
    private var immediate: Result<Value, Error>?
    private var started: (@Sendable () -> Void)?

    func configure(immediate: Result<Value, Error>? = nil, started: (@Sendable () -> Void)? = nil) {
        lock.lock()
        self.immediate = immediate
        self.started = started
        lock.unlock()
    }

    func start(_ complete: @escaping @Sendable (Result<Value, Error>) -> Void) {
        lock.lock()
        callbacks.append(complete)
        let result = immediate
        let notify = started
        lock.unlock()
        notify?()
        if let result { complete(result) }
    }

    func finish(_ index: Int, _ result: Result<Value, Error>) {
        lock.lock()
        let complete = callbacks[index]
        lock.unlock()
        complete(result)
    }
}

private struct CapturedAppAttestCallbacks: AppAttestCallbacks {
    let key = CapturedCallback<String>()
    let attestation = CapturedCallback<Data>()
    let assertion = CapturedCallback<Data>()

    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) { key.start(complete) }
    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) { attestation.start(complete) }
    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) { assertion.start(complete) }
}

final class AppleAppAttestServiceTests: XCTestCase {
    private enum Operation: CaseIterable {
        case key, attestation, assertion

        func run(_ service: AppleAppAttestService) async throws -> Data {
            switch self {
            case .key: return Data(try await service.generateKey().utf8)
            case .attestation: return try await service.attestKey("key", hash: Data())
            case .assertion: return try await service.generateAssertion("key", hash: Data())
            }
        }
    }

    func testEveryOperationBoundsMissingCallbackAndRecoversWhenAppleCompletes() async throws {
        for operation in Operation.allCases {
            let callbacks = CapturedAppAttestCallbacks()
            let service = AppleAppAttestService(callbacks: callbacks, operationTimeout: 0.01)
            do {
                _ = try await operation.run(service)
                XCTFail("missing callback must time out: \(operation)")
            } catch { XCTAssertEqual(error as? ShadowFailure, .operationTimeout) }

            do { _ = try await operation.run(service); XCTFail("timed-out Apple operation overlapped") }
            catch { XCTAssertEqual(error as? ShadowFailure, .busy) }
            switch operation {
            case .key: callbacks.key.finish(0, .success("late"))
            case .attestation: callbacks.attestation.finish(0, .success(Data()))
            case .assertion: callbacks.assertion.finish(0, .success(Data()))
            }

            callbacks.key.configure(immediate: .success("recovered"))
            callbacks.attestation.configure(immediate: .success(Data("recovered".utf8)))
            callbacks.assertion.configure(immediate: .success(Data("recovered".utf8)))
            let recovered = try await operation.run(service)
            XCTAssertEqual(recovered, Data("recovered".utf8))
        }
    }

    func testCancelledOperationRecoversAndLateCallbackCannotUnlockNewOperation() async throws {
        let callbacks = CapturedAppAttestCallbacks()
        let service = AppleAppAttestService(callbacks: callbacks, operationTimeout: 5)
        let firstStarted = expectation(description: "first Apple call started")
        callbacks.key.configure(started: { firstStarted.fulfill() })
        let first = Task { try await service.generateKey() }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail("cancelled call succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }

        do { _ = try await service.generateKey(); XCTFail("cancellation released an uncancellable Apple operation") }
        catch { XCTAssertEqual(error as? ShadowFailure, .busy) }
        callbacks.key.finish(0, .success("late"))

        let secondStarted = expectation(description: "next Apple call admitted")
        callbacks.key.configure(started: { secondStarted.fulfill() })
        let second = Task { try await service.generateKey() }
        await fulfillment(of: [secondStarted], timeout: 2)
        // A duplicate callback from the cancelled operation must not reset admission or
        // complete the second call. Both API families share the same admission.
        callbacks.key.finish(0, .success("late"))
        do { _ = try await service.attestKey("key", hash: Data()); XCTFail("overlapping Apple call admitted") }
        catch { XCTAssertEqual(error as? ShadowFailure, .busy) }
        callbacks.key.finish(1, .success("current"))
        let value = try await second.value
        XCTAssertEqual(value, "current")

        callbacks.assertion.configure(immediate: .failure(ShadowFailure.appleUnavailable))
        do { _ = try await service.generateAssertion("key", hash: Data()); XCTFail("Apple error swallowed") }
        catch { XCTAssertEqual(error as? ShadowFailure, .appleUnavailable) }
        callbacks.assertion.configure(immediate: .success(Data([1])))
        let proof = try await service.generateAssertion("key", hash: Data())
        XCTAssertEqual(proof, Data([1]))
    }

    func testAlreadyCancelledDeadlineDoesNotStartAppleCall() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let _: String = try await CallbackDeadline.call { _ in
                XCTFail("pre-cancelled operation invoked Apple")
            }
        }
        do { try await task.value; XCTFail("cancellation lost before continuation installation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
