import Foundation
import Testing
@testable import ProviderCore
@testable import darkbloom

private final class LockedDrainCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    private var waits: [Int32] = []

    func signal(_ label: String) {
        lock.withLock { labels.append(label) }
    }

    func wait(_ pid: Int32) {
        lock.withLock { waits.append(pid) }
    }

    func snapshot() -> (labels: [String], waits: [Int32]) {
        lock.withLock { (labels, waits) }
    }
}

@Suite("Provider drain client")
struct ProviderDrainClientTests {
    @Test("loaded job without a process needs no signal")
    func noRunningProcess() async throws {
        let calls = LockedDrainCalls()
        let client = ProviderDrainClient(dependencies: .init(
            snapshots: {
                [ProviderLaunchSnapshot(label: LaunchAgent.label, runs: 1, process: nil)]
            },
            signal: { calls.signal($0) },
            waitForExit: { identity, _ in calls.wait(identity.pid); return true }
        ))

        #expect(try await client.drain(timeout: .milliseconds(1)) == .notRunning)
        #expect(calls.snapshot().labels.isEmpty)
        #expect(calls.snapshot().waits.isEmpty)
    }

    @Test("all launchd provider identities drain before success")
    func drainsEveryLoadedProvider() async throws {
        let calls = LockedDrainCalls()
        let first = ProcessIdentity(pid: 41, startTimeMicros: 1)
        let second = ProcessIdentity(pid: 42, startTimeMicros: 2)
        let client = ProviderDrainClient(dependencies: .init(
            snapshots: {
                [
                    ProviderLaunchSnapshot(label: LaunchAgent.label, runs: 1, process: first),
                    ProviderLaunchSnapshot(label: "dev.darkbloom.provider", runs: 1, process: second),
                ]
            },
            signal: { calls.signal($0) },
            waitForExit: { identity, _ in calls.wait(identity.pid); return true }
        ))

        #expect(try await client.drain(timeout: .milliseconds(1)) == .drained)
        #expect(Set(calls.snapshot().labels) == Set([LaunchAgent.label, "dev.darkbloom.provider"]))
        #expect(Set(calls.snapshot().waits) == Set([first.pid, second.pid]))
    }

    @Test("timeout reports the exact process and never force kills")
    func timeoutReportsIdentity() async throws {
        let identity = ProcessIdentity(pid: 77, startTimeMicros: 9)
        let client = ProviderDrainClient(dependencies: .init(
            snapshots: {
                [ProviderLaunchSnapshot(label: LaunchAgent.label, runs: 1, process: identity)]
            },
            signal: { _ in },
            waitForExit: { _, _ in false }
        ))

        #expect(
            try await client.drain(timeout: .milliseconds(1))
                == .timedOut([identity]))
    }
}

private actor RelayCallCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

@Suite("Provider termination relay")
struct ProviderTerminationRelayTests {
    @Test("concurrent signals share one drain")
    func coalescesSignals() async {
        let relay = ProviderTerminationRelay()
        let calls = RelayCallCounter()
        await relay.install {
            await calls.increment()
            try? await Task.sleep(for: .milliseconds(30))
            return .drained
        }

        async let first = relay.request()
        async let second = relay.request()
        #expect(await first == .drained)
        #expect(await second == .drained)
        #expect(await calls.value() == 1)
    }
}
