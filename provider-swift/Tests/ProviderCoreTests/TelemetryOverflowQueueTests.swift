// Cross-process safety for the telemetry overflow queue.
//
// Two processes share the queue file: the daemon (panic hook pushes,
// TelemetryClient drains) and the persistent watchdog (crash-loop guard trip
// events). A drain is read-then-replace, so an unsynchronized push landing
// between the read and the replace is silently clobbered. The fix is an
// exclusive `flock` on a stable sidecar lock file around every mutation.
//
// A second process cannot be spawned cheaply in a unit test, but the race is
// faithfully reproduced with two INDEPENDENT queue instances on one path:
// each has its own in-process NSLock, so only the cross-process file lock
// serializes them — exactly the watchdog/daemon topology.

import Foundation
import Testing

@testable import ProviderCore

@Suite("telemetry overflow queue: cross-process safety")
struct TelemetryOverflowQueueCrossProcessTests {

    private func tempQueuePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-queue-\(UUID().uuidString).jsonl")
    }

    private func event(_ i: Int) -> TelemetryEvent {
        TelemetryEvent(
            source: .provider, severity: .info, kind: .log,
            message: "event \(i)")
    }

    @Test("a push racing a drain from a SEPARATE instance is never clobbered")
    func concurrentPushAndDrainLoseNothing() async {
        let path = tempQueuePath()
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path.path + ".lock"))
        }
        // Two instances on one path model the two processes: separate
        // NSLocks, shared file — only the flock serializes them.
        let daemon = TelemetryOverflowQueue(path: path)
        let watchdog = TelemetryOverflowQueue(path: path)

        let pushes = 200
        let drained = await withTaskGroup(of: [TelemetryEvent].self) { group -> Int in
            // The "watchdog": pushes under its own lock only.
            group.addTask {
                for i in 0 ..< pushes { watchdog.push(self.event(i)) }
                return []
            }
            // The "daemon": drains concurrently in small bites — each drain
            // is a full read-then-replace window a push could fall into.
            group.addTask {
                var got: [TelemetryEvent] = []
                for _ in 0 ..< 50 {
                    got += daemon.drain(limit: 7)
                    await Task.yield()
                }
                return got
            }
            var total = 0
            for await events in group { total += events.count }
            return total
        }

        // Whatever was not drained mid-race must still be on disk.
        let remaining = daemon.drain(limit: .max).count
        #expect(
            drained + remaining == pushes,
            "pushed \(pushes), drained \(drained), remaining \(remaining) — a drain clobbered concurrent pushes")
    }

    @Test("drain returns events in push order and removes the file when empty")
    func drainOrderAndCleanup() {
        let path = tempQueuePath()
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path.path + ".lock"))
        }
        let queue = TelemetryOverflowQueue(path: path)
        for i in 0 ..< 5 { queue.push(event(i)) }
        let first = queue.drain(limit: 2)
        #expect(first.map(\.message) == ["event 0", "event 1"])
        let rest = queue.drain(limit: 10)
        #expect(rest.map(\.message) == ["event 2", "event 3", "event 4"])
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
