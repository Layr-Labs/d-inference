import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class SandboxServiceShutdownTests: XCTestCase {
    private enum Failure: Error { case startup, cleanup }
    private actor Events {
        var values: [String] = []
        func record(_ value: String) { values.append(value) }
    }

    func testNormalExitAwaitsShutdown() async throws {
        let events = Events()
        try await SandboxServiceShutdown.run {
            await events.record("service")
        } shutdown: {
            try await Task.sleep(for: .milliseconds(20))
            await events.record("shutdown")
        }
        let values = await events.values
        XCTAssertEqual(values, ["service", "shutdown"])
    }

    func testStartupFailureStillRunsShutdownAndPreservesCause() async {
        let events = Events()
        do {
            try await SandboxServiceShutdown.run {
                throw Failure.startup
            } shutdown: { await events.record("shutdown") }
            XCTFail("expected startup failure")
        } catch Failure.startup { } catch { XCTFail("unexpected error: \(error)") }
        let values = await events.values
        XCTAssertEqual(values, ["shutdown"])
    }

    func testCancellationAwaitsUncancelledCleanup() async {
        let events = Events()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let service = Task {
            try await SandboxServiceShutdown.run {
                continuation.yield(()); continuation.finish()
                try await Task.sleep(for: .seconds(30))
            } shutdown: {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
                await events.record("shutdown")
            }
        }
        for await _ in started { break }
        service.cancel()
        do {
            try await service.value
            XCTFail("expected cancellation")
        } catch is CancellationError { } catch { XCTFail("unexpected error: \(error)") }
        let values = await events.values
        XCTAssertEqual(values, ["shutdown"])
    }

    func testCancellationBeforeStartupSkipsWorkButStillCleansRuntime() async {
        let events = Events()
        let service = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SandboxServiceShutdown.run {
                await events.record("unexpected startup")
            } shutdown: {
                try Task.checkCancellation()
                await events.record("shutdown")
            }
        }
        do {
            try await service.value
            XCTFail("expected cancellation")
        } catch is CancellationError { } catch { XCTFail("unexpected error: \(error)") }
        let values = await events.values
        XCTAssertEqual(values, ["shutdown"])
    }

    func testFailedStopProofCannotBeReportedAsCleanCancellation() async {
        do {
            try await SandboxServiceShutdown.run {
                throw CancellationError()
            } shutdown: { throw Failure.cleanup }
            XCTFail("expected cleanup failure")
        } catch SandboxRuntimeError.cleanupFailed(let operation, let primary, let cleanup) {
            XCTAssertEqual(operation, "sandbox service shutdown")
            XCTAssertTrue(primary.contains("CancellationError"))
            XCTAssertEqual(cleanup, "cleanup")
        } catch { XCTFail("unexpected error: \(error)") }
    }
}
