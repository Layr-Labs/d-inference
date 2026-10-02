import Foundation
import Testing
@testable import ProviderCore

private final class ProtectedStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0, closes = 0, completed = false
    var readCount: Int { lock.withLock { reads } }
    var closeCount: Int { lock.withLock { closes } }
    var done: Bool { lock.withLock { completed } }
    func read() { lock.withLock { reads += 1 } }
    func close() { lock.withLock { closes += 1 } }
    func finish() { lock.withLock { completed = true } }
}

@Suite struct ProtectedLocalStartTests {
    @Test func absentAuthorizationExpiresWithoutInventingAClaim() async throws {
        let counter = ProtectedStartCounter()
        let wait = NativePairLocalStart(next: { counter.read(); return nil },
            closeScope: { counter.close(); return Task {} })
        await #expect(throws: NativePairMemberError.self) { try await wait.wait(until: localHostDeadline(20)) }
        await wait.waitUntilClosed()
        #expect(counter.readCount > 0 && counter.closeCount == 1)
    }
    @Test func cancellationClosesBeforeAnyLaterLookupAndJoinsCleanup() async throws {
        let counter = ProtectedStartCounter(), cleanup = LocalHostLatch()
        let wait = NativePairLocalStart(next: { counter.read(); return nil }, closeScope: {
            counter.close(); return Task { await cleanup.wait() }
        })
        let pending = Task { try await wait.wait(until: localHostDeadline()) }
        let entered = try await localHostEventually { counter.readCount > 0 }
        #expect(entered); pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let reads = counter.readCount
        let joining = Task { await wait.waitUntilClosed(); counter.finish() }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!counter.done && counter.readCount == reads && counter.closeCount == 1)
        cleanup.complete(); await joining.value
        #expect(counter.done)
    }
    @Test func connectionBindingFailureCannotBeRetriedOnAnotherConnection() async throws {
        let counter = ProtectedStartCounter()
        let wait = NativePairLocalStart(next: { counter.read(); throw NativePairMemberError.binding },
            closeScope: { counter.close(); return Task {} })
        await #expect(throws: NativePairMemberError.self) { try await wait.wait(until: localHostDeadline()) }
        await #expect(throws: CancellationError.self) { try await wait.wait(until: localHostDeadline()) }
        await wait.waitUntilClosed()
        #expect(counter.readCount == 1 && counter.closeCount == 1)
    }
    @Test func cancellationBeforeWaitAndUnboundedDeadlinesNeverQueryAuthorization() async throws {
        for deadline in [UInt64(0), UInt64.max] {
            let counter = ProtectedStartCounter()
            let wait = NativePairLocalStart(next: { counter.read(); return nil },
                closeScope: { counter.close(); return Task {} })
            await #expect(throws: NativePairMemberError.self) { try await wait.wait(until: deadline) }
            await wait.waitUntilClosed()
            #expect(counter.readCount == 0 && counter.closeCount == 1)
        }
        let counter = ProtectedStartCounter()
        let wait = NativePairLocalStart(next: { counter.read(); return nil },
            closeScope: { counter.close(); return Task {} })
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.wait(until: localHostDeadline()) }
        await wait.waitUntilClosed(); #expect(counter.readCount == 0 && counter.closeCount == 1)
    }
    @Test func startupStopRetainsLateHostAndDoesNotFinishBeforeControlJoin() async throws {
        let counter = ProtectedStartCounter(), cleanup = LocalHostLatch()
        let lifecycle = ProtectedLocalStartLifecycle(closeControl: {
            counter.close(); return Task { await cleanup.wait() }
        })
        await lifecycle.stop()
        let host = localHost(LocalHostTestSession())
        await #expect(throws: CancellationError.self) { try await lifecycle.install(host) }
        let finishing = Task { let result = await lifecycle.finish(); counter.finish(); return result }
        try await Task.sleep(for: .milliseconds(10))
        #expect(counter.closeCount == 1 && !counter.done)
        cleanup.complete()
        let result = await finishing.value
        #expect(result?.cleanupComplete == true && counter.done)
    }
    @Test func stoppedStartupCancelsLateAuthorizationScope() async throws {
        let counter = ProtectedStartCounter()
        let lifecycle = ProtectedLocalStartLifecycle(closeControl: { Task {} })
        await lifecycle.stop()
        let scope = NativePairLocalStart(next: { counter.read(); return nil },
            closeScope: { counter.close(); return Task {} })
        await #expect(throws: CancellationError.self) { try await lifecycle.install(scope) }
        _ = await lifecycle.finish()
        #expect(counter.readCount == 0 && counter.closeCount == 1)
    }
}
