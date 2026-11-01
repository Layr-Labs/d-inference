import Testing
@testable import DarkbloomClusterRuntime

/// The one-call token callback as a two-half channel: every published token
/// gets exactly its own answer, read once.
@Suite("Committed-token channel")
struct ClusterCommittedTokenChannelTests {
    @Test func eachPublishedTokenIsAnsweredOnce() throws {
        var seen: [[Int]] = []
        let answers = try ClusterCommittedTokenChannel.answering({ ordinal, token, frontier in
            seen.append([ordinal, token, frontier])
            return token != 7
        }) { channel -> [Bool] in
            try channel.publish(0, 5, 10)
            let first = try channel.answer()
            try channel.publish(1, 7, 11)
            return [first, try channel.answer()]
        }
        #expect(seen == [[0, 5, 10], [1, 7, 11]])
        #expect(answers == [true, false])
    }

    @Test func anAnswerWithoutItsTokenIsRefused() throws {
        try ClusterCommittedTokenChannel.answering({ _, _, _ in true }) { channel in
            #expect(throws: (any Error).self) { _ = try channel.answer() }
            try channel.publish(0, 1, 1)
            #expect(try channel.answer())
            #expect(throws: (any Error).self) { _ = try channel.answer() }
        }
    }
}
