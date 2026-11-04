import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM native frame commit over actual collective transport", .serialized)
struct GLM5NextStageFrameTransportTests {
    private enum Failure: Error { case afterConsumerCommit }

    @Test func bothNativeStagesCommitOnlyTheirAcknowledgedFrames() throws {
        let fixture = try GLM5NextStageSessionTests.Fixture()
        let pair = try ResidualStreamCollectiveFixture()
        let producer = QwenLayerStageGenerationControl(agreement: fixture.agreement)
        let consumer = QwenLayerStageGenerationControl(agreement: fixture.agreement)
        let send = try QwenLayerStageGenerationTransport(agreement: fixture.agreement, collective: pair.first)
        let receive = try QwenLayerStageGenerationTransport(agreement: fixture.agreement, collective: pair.last)
        defer { send.retire(); receive.retire() }
        for sequence in 0..<2 {
            let expected = try producer.beginFrame(), peerExpected = try consumer.beginFrame()
            #expect(expected == peerExpected && expected.frame.sequence == sequence)
            var sent: String?
            let received = try pair.exchange(send: {
                let (packet, row) = try runGLM5NextStageFrame(session: fixture.first, control: producer,
                    transport: send, expected: expected, check: {})
                #expect(row == nil)
                sent = packet.fingerprint
            }, receive: { _ -> (String, [Int]?) in
                let (packet, row) = try runGLM5NextStageFrame(session: fixture.last, control: consumer,
                    transport: receive, expected: peerExpected, check: {})
                return (packet.fingerprint, row?.shape)
            })
            #expect(sent == received.0)
            #expect(received.1 == (sequence == 1 ? [1, 32] : nil))
            let frontier = (sequence + 1) * 2
            #expect(fixture.first.committedTokens == frontier && fixture.last.committedTokens == frontier)
            #expect(producer.committedTokens == frontier && consumer.committedTokens == frontier)
            #expect(!producer.isFailed && !consumer.isFailed && !send.isFailed && !receive.isFailed)
        }
        try fixture.first.close(check: {}); try fixture.last.close(check: {})
        #expect(fixture.first.isClosed && fixture.last.isClosed)
    }

    @Test func lostConsumedAcknowledgementFencesBothRanksWithoutPublishingAToken() throws {
        let fixture = try GLM5NextStageSessionTests.Fixture()
        let pair = try ResidualStreamCollectiveFixture()
        let producer = QwenLayerStageGenerationControl(agreement: fixture.agreement)
        let consumer = QwenLayerStageGenerationControl(agreement: fixture.agreement)
        let send = try QwenLayerStageGenerationTransport(agreement: fixture.agreement, collective: pair.first)
        let receive = try QwenLayerStageGenerationTransport(agreement: fixture.agreement, collective: pair.last)
        let expected = try producer.beginFrame(), peerExpected = try consumer.beginFrame()
        var producerFailed = false
        let receiverFailed = try pair.exchange(send: {
            do {
                _ = try runGLM5NextStageFrame(session: fixture.first, control: producer,
                    transport: send, expected: expected, check: {})
            } catch { producerFailed = true }
        }, receive: { _ -> Bool in
            do {
                _ = try runGLM5NextStageFrame(session: fixture.last, control: consumer,
                    transport: receive, expected: peerExpected, check: {
                        // This condition becomes true only after the real native
                        // session and local control commit inside receiveBoundary.
                        // The next check precedes the real boundaryConsumed send.
                        if fixture.last.committedTokens == 2 { throw Failure.afterConsumerCommit }
                    })
                return false
            } catch Failure.afterConsumerCommit { return true }
        })
        #expect(producerFailed && receiverFailed)
        #expect(fixture.first.committedTokens == 0 && fixture.last.committedTokens == 2)
        #expect(fixture.first.isFailed && fixture.last.isFailed)
        #expect(producer.isFailed && consumer.isFailed && send.isFailed && receive.isFailed)
        #expect(producer.selectedTokenCount == 0 && consumer.selectedTokenCount == 0)
        #expect(throws: ProbeError.self) { try producer.takeCommittedToken() }
        #expect(throws: ProbeError.self) { try consumer.takeCommittedToken() }
        // Both bounded transport operations have terminated and the peer worker
        // has joined. Explicit local retirement then clears each complete cache.
        try fixture.first.close(check: {}); try fixture.last.close(check: {})
        for control in [producer, consumer] {
            try control.acknowledgeRetirement(rank: 0, disposition: .fenced)
            try control.acknowledgeRetirement(rank: 1, disposition: .fenced)
            #expect(control.isRetired)
        }
        #expect(fixture.first.isClosed && fixture.last.isClosed)
    }
}
