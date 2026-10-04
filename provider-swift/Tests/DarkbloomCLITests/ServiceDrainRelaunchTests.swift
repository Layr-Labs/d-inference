import Foundation
import Testing
@testable import darkbloom

@Suite("Drained provider relaunch")
struct ServiceDrainRelaunchTests {
    private struct RelaunchFailed: Error, Equatable {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func tick() { lock.withLock { value += 1 } }
    }

    // #1306: a failed relaunch must not leave the watchdog stopped.
    @Test("failed relaunch re-arms the watchdog once and rethrows")
    func failedRelaunchRearms() async throws {
        let rearms = Counter()
        await #expect(throws: RelaunchFailed.self) {
            try await ServiceDrain.relaunchDrainedProvider(
                relaunch: { throw RelaunchFailed() },
                rearm: { rearms.tick() })
        }
        #expect(rearms.count == 1)
    }

    @Test("successful relaunch re-arms the watchdog once")
    func successfulRelaunchRearms() async throws {
        let rearms = Counter()
        try await ServiceDrain.relaunchDrainedProvider(relaunch: {}, rearm: { rearms.tick() })
        #expect(rearms.count == 1)
    }
}
