// MLXLMServer's canonical encoder bounds its own metadata holdback
// (EventBoundLogprobsTests). The GLM and Nemotron relays still buffer
// through `EngineV2LogprobsChannel`, so its cap, drop-oldest eviction and
// `droppedCount` stay covered here.

import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("EngineV2 logprobs channel bounding")
struct EngineV2LogprobsChannelCapTests {

    private func entry(_ token: String) -> SSETokenLogprob {
        SSETokenLogprob(token: token, logprob: -0.1, bytes: nil, topLogprobs: [])
    }

    @Test("undrained channel is capped at maxEntries with drop-oldest")
    func channelCapsWithDropOldest() {
        let channel = EngineV2LogprobsChannel()
        let cap = EngineV2LogprobsChannel.maxEntries
        // Append cap + 10 entries, tagged by index, without ever draining.
        for i in 0..<(cap + 10) {
            channel.append([entry("t\(i)")])
        }
        let drained = channel.drain()
        // Buffer never exceeds the cap; the 10 OLDEST were dropped.
        #expect(drained.count == cap)
        #expect(channel.droppedCount == 10)
        // The freshest entries are retained (drop-oldest): first kept is t10,
        // last is t<cap+9>.
        #expect(drained.first?.token == "t10")
        #expect(drained.last?.token == "t\(cap + 9)")
    }

    @Test("under the cap nothing is dropped; drain empties the buffer")
    func channelUnderCapNoDrops() {
        let channel = EngineV2LogprobsChannel()
        for i in 0..<100 { channel.append([entry("t\(i)")]) }
        #expect(channel.droppedCount == 0)
        #expect(channel.drain().count == 100)
        #expect(channel.drain().isEmpty)
    }
}
