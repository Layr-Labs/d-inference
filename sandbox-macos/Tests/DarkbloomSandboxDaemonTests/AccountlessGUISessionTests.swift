import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessGUISessionTests: XCTestCase {
    private enum Failure: Error { case sessionLost, cleanupFailed }

    func testSessionLossCannotHideTheOperationsCleanupFailure() async throws {
        let started = Gate()
        do {
            let _: Int = try await AccountlessGUISession.run(operation: {
                await started.signal()
                do { try await Task.sleep(for: .seconds(10)); return 1 }
                catch { throw Failure.cleanupFailed }
            }, monitor: {
                await started.wait(); throw Failure.sessionLost
            })
            XCTFail("cleanup failure must propagate")
        } catch {
            guard case Failure.cleanupFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testSessionLossWaitsForSuccessfulCancellationCleanup() async throws {
        let started = Gate(), cleaned = Gate()
        do {
            let _: Int = try await AccountlessGUISession.run(operation: {
                await started.signal()
                do { try await Task.sleep(for: .seconds(10)); return 1 }
                catch { await cleaned.signal(); throw CancellationError() }
            }, monitor: {
                await started.wait(); throw Failure.sessionLost
            })
            XCTFail("session loss must propagate")
        } catch {
            guard case Failure.sessionLost = error else { return XCTFail("unexpected error: \(error)") }
            let didClean = await cleaned.signaled
            XCTAssertTrue(didClean)
        }
    }

    func testSuccessfulOperationCancelsMonitorAndReturnsItsResult() async throws {
        let value = try await AccountlessGUISession.run(operation: { 17 },
            monitor: { try await Task.sleep(for: .seconds(10)) })
        XCTAssertEqual(value, 17)
    }

    private actor Gate {
        var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func signal() {
            signaled = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if signaled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
