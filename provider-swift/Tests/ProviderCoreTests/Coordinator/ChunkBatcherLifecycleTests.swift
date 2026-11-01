import Foundation
import Network
import Testing
@testable import ProviderCore

@Suite("ChunkBatcherLifecycleTests", .serialized)
struct ChunkBatcherLifecycleTests {
    @Test("reconnect does not deliver frames enqueued while unbound",
          arguments: [0, 1, 64, 1399, 1400, 4096])
    func reconnectDropsUnboundFrames(size: Int) {
        let batcher = ChunkBatcher()
        let oldConnection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let newConnection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { oldConnection.cancel(); newConnection.cancel() }
        let oldFrames = FrameRecorder()
        let newFrames = FrameRecorder()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let primer = Data(repeating: 0xA0, count: ChunkBatcher.flushThresholdBytes)
        batcher.bind(connection: oldConnection) { frames in
            oldFrames.append(frames)
            entered.signal()
            #expect(release.wait(timeout: .now() + .seconds(10)) == .success)
        }
        batcher.enqueue(primer)
        guard entered.wait(timeout: .now() + .seconds(10)) == .success else {
            release.signal()
            Issue.record("old session did not enter its sink")
            return
        }

        // Hold the real serial queue in its sink so all three operations are
        // queued before the stale frame can schedule a deferred flush. No
        // sleep or private queue access controls this interleaving.
        batcher.unbind(ifCurrent: oldConnection)
        batcher.enqueue(Data(repeating: 0xB0, count: size))
        batcher.bind(connection: newConnection) { newFrames.append($0) }
        release.signal()
        batcher.flush()

        #expect(oldFrames.snapshot() == [primer])
        #expect(newFrames.snapshot().isEmpty,
                "a disconnected request's frame reached the new session")

        let fresh = Data([0xC0])
        batcher.enqueue(fresh)
        batcher.flush()
        #expect(newFrames.snapshot() == [fresh])
    }

    @Test("unbound flush drops frames and subsequent bind still works")
    func disconnectedFlushDropsFrames() {
        let batcher = ChunkBatcher()
        batcher.enqueue(Data([1]))
        batcher.flush()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { connection.cancel() }
        let frames = FrameRecorder()
        batcher.bind(connection: connection) { frames.append($0) }
        batcher.enqueue(Data([2]))
        batcher.flush()
        #expect(frames.snapshot() == [Data([2])])
    }

    @Test("stale teardown preserves the replacement connection")
    func staleUnbindPreservesNewConnection() {
        let batcher = ChunkBatcher()
        let oldConnection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let newConnection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { oldConnection.cancel(); newConnection.cancel() }
        let frames = FrameRecorder()
        batcher.bind(connection: oldConnection) { _ in }
        batcher.unbind(ifCurrent: oldConnection)
        batcher.bind(connection: newConnection) { frames.append($0) }
        batcher.unbind(ifCurrent: oldConnection)
        batcher.enqueue(Data([3]))
        batcher.flush()
        #expect(frames.snapshot() == [Data([3])])
    }

    @Test("flush preserves same-session bytes and order", arguments: [1, 200])
    func flushPreservesFrames(count: Int) {
        let batcher = ChunkBatcher()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { connection.cancel() }
        let frames = FrameRecorder()
        batcher.bind(connection: connection) { frames.append($0) }
        let expected = (0..<count).map { Data(repeating: UInt8($0 % 256), count: $0 % 3 == 0 ? 4096 : 8) }
        for frame in expected { batcher.enqueue(frame) }
        batcher.flush()
        #expect(frames.snapshot() == expected)
        batcher.flush()
        #expect(frames.snapshot() == expected)
    }

    @Test("concurrent requests retain every frame and each request's order")
    func concurrentRequestsPreserveOrder() {
        let batcher = ChunkBatcher()
        let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        defer { connection.cancel() }
        let frames = FrameRecorder()
        batcher.bind(connection: connection) { frames.append($0) }
        DispatchQueue.concurrentPerform(iterations: 4) { request in
            for sequence in 0..<40 {
                batcher.enqueue(Data([UInt8(request), UInt8(sequence)]))
            }
        }
        batcher.flush()
        let delivered = frames.snapshot()
        #expect(delivered.count == 160)
        for request in 0..<4 {
            #expect(delivered.filter { $0.first == UInt8(request) }
                == (0..<40).map { Data([UInt8(request), UInt8($0)]) })
        }
    }
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []

    func append(_ batch: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(contentsOf: batch)
    }

    func snapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}
