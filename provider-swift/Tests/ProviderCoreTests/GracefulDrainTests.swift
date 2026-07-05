import Foundation
import Testing

@testable import ProviderCore

// MARK: - OutboundRouter pending-write accounting
//
// The graceful drain's `flushOutbound` waits on this counter to deliver the
// tail of a finished request (its final `inference_complete`) before the
// transport is torn down. Pin the invariants: yields count only when a live
// connection is installed, `markWritten` never goes negative, and both
// `activate` (reconnect) and `finish` (shutdown) reset the count — a stream's
// buffered messages are abandoned on either transition.

@Suite("OutboundRouter pending-write accounting")
struct OutboundRouterPendingWriteTests {

    @Test("yield without a live connection is dropped and not counted")
    func yieldWithoutConnectionDoesNotCount() {
        let router = OutboundRouter()
        router.yield(.inferenceAccepted(requestId: "r1"))
        #expect(router.pendingCount() == 0)
    }

    @Test("yield increments, markWritten decrements, never below zero")
    func yieldMarkWrittenRoundTrip() {
        let router = OutboundRouter()
        let (stream, cont) = AsyncStream<OutboundMessage>.makeStream()
        defer { _ = stream } // keep the stream alive for the test's duration
        router.activate(cont)

        router.yield(.inferenceAccepted(requestId: "r1"))
        router.yield(.inferenceAccepted(requestId: "r2"))
        #expect(router.pendingCount() == 2)

        router.markWritten()
        #expect(router.pendingCount() == 1)
        router.markWritten()
        #expect(router.pendingCount() == 0)

        // A late/duplicate confirmation must not underflow.
        router.markWritten()
        #expect(router.pendingCount() == 0)
    }

    @Test("activate (reconnect) resets the pending count")
    func activateResetsPendingWrites() {
        let router = OutboundRouter()
        let (stream1, cont1) = AsyncStream<OutboundMessage>.makeStream()
        defer { _ = stream1 }
        router.activate(cont1)
        router.yield(.inferenceAccepted(requestId: "r1"))
        #expect(router.pendingCount() == 1)

        let (stream2, cont2) = AsyncStream<OutboundMessage>.makeStream()
        defer { _ = stream2 }
        router.activate(cont2)
        #expect(router.pendingCount() == 0)
    }

    @Test("finish (shutdown) resets the pending count")
    func finishResetsPendingWrites() {
        let router = OutboundRouter()
        let (stream, cont) = AsyncStream<OutboundMessage>.makeStream()
        defer { _ = stream }
        router.activate(cont)
        router.yield(.inferenceAccepted(requestId: "r1"))
        #expect(router.pendingCount() == 1)

        router.finish()
        #expect(router.pendingCount() == 0)
    }
}

// MARK: - DaemonState inflight request count
//
// The CLI drain message ("Provider is currently serving N requests...") reads
// this field from the daemon state file. Pin the round-trip and the
// backward-compat decode of state files written before the field existed.

@Suite("DaemonState inflight request count")
struct DaemonStateInflightCountTests {

    private func tempStateFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-darkbloom-state-\(UUID().uuidString).json")
    }

    @Test("inflightRequestCount round-trips through the state file")
    func roundTripsThroughStateFile() {
        let url = tempStateFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date().timeIntervalSince1970
        let state = DaemonState(
            pid: 4242,
            version: "0.0.0-test",
            writtenAt: now,
            startedAt: now,
            inflightRequestCount: 3
        )
        DaemonStateFile.write(state, to: url)

        let read = DaemonStateFile.read(from: url)
        #expect(read?.inflightRequestCount == 3)
        #expect(read?.pid == 4242)
    }

    @Test("state files written before the field existed decode with nil count")
    func decodesLegacyStateWithoutCount() throws {
        let url = tempStateFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // A pre-drain state file: no inflight_request_count key.
        let legacyJSON = """
        {"schema":1,"pid":7,"version":"0.5.0","written_at":1,"started_at":1,
         "warm_models":[],"inference_active":true,
         "stats":{"requests_served":0,"tokens_generated":0,"usage_gaps":0}}
        """
        try Data(legacyJSON.utf8).write(to: url)

        let read = try #require(DaemonStateFile.read(from: url))
        #expect(read.inflightRequestCount == nil)
        #expect(read.inferenceActive == true)
    }
}
