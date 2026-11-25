import Foundation
import Testing

@testable import ProviderCore

/// A reconnect storm played with the provider's own `CoordinatorReconnectPolicy`
/// and `CoordinatorLinkWatch`. Every provider's socket closes at the same
/// instant after a long session, with close code 1001 (what a proxy sends when
/// it reloads), and each provider reconnects after the wait its policy draws.
/// The coordinator registers one connection at a time, in arrival order, at a
/// fixed rate, and answers a connection only once it has registered it; it
/// also spends that time on a connection that has already closed. A connection
/// whose link watch declares it dead before the answer closes, and its provider
/// reconnects again: a re-drop. The coordinator here registers 95 connections
/// per second. 4,000 providers are more than the first-frame grace alone
/// absorbs at that rate (30 s at 95 per second), so that row also needs the
/// spread of the waits. A storm whose reconnects arrive faster than the
/// coordinator registers them never drains, so the play stops at `horizon`.
/// The planned rows play the coordinator's close pacer instead: it closes one
/// socket each 1/90 s with 1012 `planned move`, and each provider reconnects at
/// once.
@Suite("Coordinator reconnect storm")
struct CoordinatorReconnectStormTests {
    static let registrationsPerSecond = 95.0
    static let horizon = 600.0
    /// The rate of the coordinator's close pacer (`linkconfig.PlannedCloseRate`
    /// of the coordinator: 9/10 of its open pace of 100 per second).
    static let plannedCloseRate = 90.0

    @Test("a fleet whose sockets close together reconnects without a single re-drop",
          arguments: [1_000, 2_500, 4_000])
    func fleetReconnectsWithoutReDrops(providers: Int) {
        let storm = Self.play(providers: providers, seed: 0x5EED_2026)
        #expect(storm.reDrops == 0,
                "\(storm.reDrops) connections closed again before the coordinator answered them")
        #expect(storm.unanswered == 0, "\(storm.unanswered) providers still waited at \(Self.horizon) s")
        // Everyone is answered once the coordinator has worked through the fleet
        // (or through the spread of the waits, when that is longer).
        let workThrough = Double(providers) / Self.registrationsPerSecond
        #expect(storm.lastAnsweredAt <= max(workThrough, 15) + 1, "last answer at \(storm.lastAnsweredAt) s")
    }

    @Test("a fleet whose planned closes the coordinator paces reconnects at once without a single re-drop",
          arguments: [1_000, 4_000])
    func pacedPlannedClosesReconnectWithoutReDrops(providers: Int) {
        let storm = Self.play(providers: providers, seed: 0x5EED_2026, plannedCloseRate: Self.plannedCloseRate)
        #expect(storm.reDrops == 0,
                "\(storm.reDrops) connections closed again before the coordinator answered them")
        #expect(storm.unanswered == 0, "\(storm.unanswered) providers still waited at \(Self.horizon) s")
        // Each provider reconnects as its close comes, so the last answer comes
        // just after the last close.
        let lastClose = Double(providers - 1) / Self.plannedCloseRate
        #expect(storm.lastAnsweredAt <= lastClose + 1, "last answer at \(storm.lastAnsweredAt) s")
    }

    struct Storm {
        var reDrops = 0
        var lastAnsweredAt = 0.0
        /// Providers whose next attempt comes at `horizon` or later.
        var unanswered = 0
    }

    /// Plays the storm. Without `plannedCloseRate` every socket closes at 0 s
    /// with 1001; with it, socket `i` closes at `i / plannedCloseRate` with the
    /// planned close.
    static func play(providers: Int, seed: UInt64, plannedCloseRate: Double? = nil) -> Storm {
        var random = SplitMix64(seed: seed)
        let liveness = CoordinatorLinkLiveness()
        let ping = liveness.pingInterval / .seconds(1)
        let registration = 1 / registrationsPerSecond
        let origin = ContinuousClock.now
        func instant(_ seconds: Double) -> ContinuousClock.Instant {
            origin.advanced(by: .microseconds(Int64((seconds * 1_000_000).rounded())))
        }

        var policies = Array(repeating: CoordinatorReconnectPolicy(), count: providers)
        var connects = ConnectQueue()
        let fleetClose = CoordinatorSessionEnd(openDuration: .seconds(3_600), closeCode: 1001)
        let plannedClose = CoordinatorSessionEnd(
            openDuration: .seconds(3_600), closeCode: CoordinatorReconnectPolicy.plannedCloseCode,
            closeReason: CoordinatorReconnectPolicy.plannedCloseReason)
        for provider in 0..<providers {
            let closedAt = plannedCloseRate.map { Double(provider) / $0 } ?? 0
            let closed = plannedCloseRate == nil ? fleetClose : plannedClose
            let wait = TimeInterval.random(in: policies[provider].nextDelayRange(after: closed), using: &random)
            connects.push(at: closedAt + wait, provider: provider)
        }

        var storm = Storm()
        var coordinatorFreeAt = 0.0
        while let (connectAt, provider) = connects.pop() {
            guard connectAt < horizon else {
                storm.unanswered = connects.count + 1
                break
            }
            let answeredAt = max(coordinatorFreeAt, connectAt) + registration
            coordinatorFreeAt = answeredAt
            // The provider sends `register` as it connects; its ping task starts
            // just after, and no frame comes in before the answer.
            let start = connectAt + 0.001
            var watch = CoordinatorLinkWatch(liveness: liveness, start: instant(start))
            var closedAt: Double?
            var tick = start + ping
            while tick < answeredAt {
                if watch.check(now: instant(tick), lastInbound: instant(connectAt)) == .dead {
                    closedAt = tick
                    break
                }
                tick += ping
            }
            guard let closedAt else {
                storm.lastAnsweredAt = max(storm.lastAnsweredAt, answeredAt)
                continue
            }
            storm.reDrops += 1
            let end = CoordinatorSessionEnd(
                openDuration: .microseconds(Int64(((closedAt - connectAt) * 1_000_000).rounded())), closeCode: nil)
            let wait = TimeInterval.random(in: policies[provider].nextDelayRange(after: end), using: &random)
            connects.push(at: closedAt + wait, provider: provider)
        }
        return storm
    }
}

/// Connection attempts by time, earliest first (a binary min-heap).
private struct ConnectQueue {
    private var heap: [(at: Double, provider: Int)] = []

    var count: Int { heap.count }

    mutating func push(at: Double, provider: Int) {
        heap.append((at, provider))
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.earlier(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let first = heap.first else { return nil }
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1, right = left + 1
                var smallest = parent
                if left < heap.count, Self.earlier(heap[left], heap[smallest]) { smallest = left }
                if right < heap.count, Self.earlier(heap[right], heap[smallest]) { smallest = right }
                guard smallest != parent else { break }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (first.at, first.provider)
    }

    private static func earlier(_ a: (at: Double, provider: Int), _ b: (at: Double, provider: Int)) -> Bool {
        a.at != b.at ? a.at < b.at : a.provider < b.provider
    }
}

/// A seeded generator, so the storm plays the same way on every run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
