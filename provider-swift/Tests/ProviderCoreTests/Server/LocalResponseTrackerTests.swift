import Foundation
import Hummingbird
import NIOCore
import HTTPTypes
import Testing
@testable import ProviderCore

private actor BodyFinishGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private struct SlowFinalWriter: ResponseBodyWriter {
    let gate: BodyFinishGate
    mutating func write(_ buffer: ByteBuffer) async throws {}
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws { await gate.wait() }
}

@Suite("Local response drain ownership")
struct LocalResponseTrackerTests {
    @Test func holdsThroughSlowFinalWriteAndReleasesExactlyOnce() async throws {
        let tracker = LocalResponseTracker()
        let lease = try tracker.admit()
        let response = lease.wrap(Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "done"))))
        tracker.setAccepting(false)
        #expect(throws: (any Error).self) { try tracker.admit() }
        let gate = BodyFinishGate()
        let write = Task { try await response.body.write(SlowFinalWriter(gate: gate)) }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(tracker.activeCount == 1)
        await gate.release()
        try await write.value
        #expect(tracker.activeCount == 0)
        lease.release()
        #expect(tracker.activeCount == 0)
    }
}
