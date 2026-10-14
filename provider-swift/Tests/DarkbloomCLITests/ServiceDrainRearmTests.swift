import Foundation
import Testing

@testable import darkbloom

/// `ServiceDrain.relaunchDrainedProvider` must restore crash recovery once the
/// drain has committed, whether the relaunch succeeds or fails. A relaunch that
/// stops the old instance but then fails to start the new one otherwise leaves
/// the provider down with automatic recovery disabled.
@Suite("ServiceDrain relaunch re-arm")
struct ServiceDrainRearmTests {

    /// Records how the re-arm hook was invoked. A reference type keeps the
    /// counter valid across the async relaunch call.
    private final class RearmSpy: @unchecked Sendable {
        var count = 0
        var lastConfig: String??
    }

    private enum RelaunchFailure: Error, Equatable { case loadFailed }

    @Test("a failed drained relaunch re-arms crash recovery and rethrows")
    func failedRelaunchRearms() async {
        let spy = RearmSpy()
        await #expect(throws: RelaunchFailure.loadFailed) {
            try await ServiceDrain.relaunchDrainedProvider(
                explicitConfig: "/tmp/provider.toml",
                rearm: { config in spy.count += 1; spy.lastConfig = .some(config) }
            ) {
                throw RelaunchFailure.loadFailed
            }
        }
        #expect(spy.count == 1)
        #expect(spy.lastConfig == .some("/tmp/provider.toml"))
    }

    @Test("a successful drained relaunch re-arms crash recovery exactly once")
    func successfulRelaunchRearms() async throws {
        let spy = RearmSpy()
        try await ServiceDrain.relaunchDrainedProvider(
            explicitConfig: nil,
            rearm: { config in spy.count += 1; spy.lastConfig = .some(config) }
        ) {
            // relaunch succeeds without throwing
        }
        #expect(spy.count == 1)
        #expect(spy.lastConfig == .some(.none))
    }
}
