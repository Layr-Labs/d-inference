import ArgumentParser
import Darwin
import Foundation
import Testing
@testable import darkbloom

/// A rank 0 told to stop while it is still starting: the signal handler is installed first, a SIGTERM that arrives
/// before the serving task exists is latched (never lost), and a start step checks the latch before it begins.
@Suite("Distributed start signals", .serialized)
struct DistributedStartSignalsTests {
    @Test func aStopBeforeServingIsLatchedAndEndsTheStart() throws {
        let signals = try DistributedStartSignals()
        defer { signals.close() }
        #expect(!signals.terminated)
        try signals.requireNotTerminated()
        raise(SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while !signals.terminated, Date() < deadline { usleep(10_000) }
        #expect(signals.terminated, "the SIGTERM was latched")
        #expect(throws: ExitCode.self) { try signals.requireNotTerminated() }
        // The action attached later runs at once (the stop is acted on, not waited out).
        final class Flag: @unchecked Sendable { let lock = NSLock(); var value = false }
        let acted = Flag()
        signals.attach { acted.lock.withLock { acted.value = true } }
        #expect(acted.lock.withLock { acted.value })
    }
}
