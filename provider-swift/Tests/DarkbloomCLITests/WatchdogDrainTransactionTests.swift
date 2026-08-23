import Foundation
import Testing
@testable import darkbloom

private final class LockedWatchdogEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [String] {
        lock.withLock { events }
    }
}

private enum TestDrainError: Error {
    case timedOut
}

@Suite("Watchdog drain transaction")
struct WatchdogDrainTransactionTests {
    @Test("watchdog is disarmed before a successful drain")
    func disarmsBeforeDrain() async throws {
        let events = LockedWatchdogEvents()
        let transaction = WatchdogDrainTransaction(dependencies: .init(
            snapshot: {
                events.record("snapshot")
                return .init(wasLoaded: true, configPath: nil)
            },
            disarm: { events.record("disarm") },
            rearm: { _ in events.record("rearm") }
        ))

        try await transaction.run {
            events.record("drain")
        }

        #expect(events.snapshot() == ["snapshot", "disarm", "drain"])
    }

    @Test("failed drain restores a previously loaded watchdog")
    func restoresAfterFailure() async {
        let events = LockedWatchdogEvents()
        let config = URL(fileURLWithPath: "/tmp/provider.toml")
        let transaction = WatchdogDrainTransaction(dependencies: .init(
            snapshot: {
                events.record("snapshot")
                return .init(wasLoaded: true, configPath: config)
            },
            disarm: { events.record("disarm") },
            rearm: { path in
                #expect(path == config)
                events.record("rearm")
            }
        ))

        await #expect(throws: TestDrainError.timedOut) {
            try await transaction.run {
                events.record("drain")
                throw TestDrainError.timedOut
            }
        }
        #expect(events.snapshot() == ["snapshot", "disarm", "drain", "rearm"])
    }

    @Test("failed drain does not create a watchdog that was not loaded")
    func leavesOptOutAlone() async {
        let events = LockedWatchdogEvents()
        let transaction = WatchdogDrainTransaction(dependencies: .init(
            snapshot: { .init(wasLoaded: false, configPath: nil) },
            disarm: { events.record("disarm") },
            rearm: { _ in events.record("rearm") }
        ))

        await #expect(throws: TestDrainError.timedOut) {
            try await transaction.run {
                events.record("drain")
                throw TestDrainError.timedOut
            }
        }
        #expect(events.snapshot() == ["disarm", "drain"])
    }
}
