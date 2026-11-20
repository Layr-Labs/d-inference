import Foundation
import Testing
@testable import ProviderCore

/// `ResponseTextBuffer` holds the response text the inference handler gathers:
/// it reads back exactly what was appended, hashes like the `String` form, and
/// leaves no copy behind when it grows or is released.
@Suite(.serialized) struct ResponseTextBufferTests {
    @Test func readsBackWhatWasAppended() {
        let pieces = ["plain ascii, ", "é (combining: e\u{301}), ", "emoji 🧑‍🔬 ", "漢字", "", "\u{1F}tool_call:{}\u{1F}"]
        let buffer = ResponseTextBuffer()
        #expect(buffer.isEmpty)
        for piece in pieces {
            buffer.append(piece)
        }
        buffer.append(pieces[2].dropFirst(6))
        let expected = pieces.joined() + pieces[2].dropFirst(6)
        #expect(!buffer.isEmpty)
        #expect(buffer.count == expected.utf8.count)
        #expect(buffer.withText { $0 } == expected)

        let copy = ResponseTextBuffer()
        copy.append(contentsOf: buffer)
        copy.append(contentsOf: ResponseTextBuffer())
        #expect(copy.withText { $0 } == expected)
        #expect(ResponseTextBuffer().withText { $0 }.isEmpty)
    }

    @Test(arguments: ["", "short answer", String(repeating: "long answer, ", count: 5_000),
                      "reasoning first then 答え 🙂\u{1F}tool_call:{\"id\":\"call_1\"}\u{1F}"])
    func hashesLikeTheStringForm(body: String) {
        let buffer = ResponseTextBuffer()
        // Appended in uneven pieces, as frames arrive.
        var rest = Substring(body)
        while !rest.isEmpty {
            let piece = rest.prefix(7)
            buffer.append(piece)
            rest = rest.dropFirst(piece.count)
        }
        for tokens: UInt64 in [0, 1, 4_096] {
            let fromString = computeResponseAttestation(
                identity: nil, requestId: "req-1", completionTokens: tokens, responseBody: body)
            let fromBuffer = computeResponseAttestation(
                identity: nil, requestId: "req-1", completionTokens: tokens, response: buffer)
            #expect(fromBuffer.hash == fromString.hash)
            #expect(fromBuffer.signature == nil)
        }
    }

    @Test func growingAndReleasingLeaveNoCopy() {
        let text = UnheldText.random(count: 32)
        let size = 256 * 1024
        let repeats = size / (text.count + 1)
        do { // `buffer` is released before the last scan.
            let buffer = ResponseTextBuffer()
            text.withRepeated(prefix: "", suffix: "", size: size) { bytes in
                // Small appends make the buffer grow many times.
                var offset = 0
                while offset < bytes.count {
                    let end = min(bytes.count, offset + 333)
                    buffer.append(utf8: UnsafeMutableRawBufferPointer(rebasing: bytes[offset ..< end]))
                    offset = end
                }
            }
            // Every repeat once, in the live buffer; none in the storage it left while growing.
            #expect(ProcessMemoryScan.copies(of: text).count == repeats)
            withExtendedLifetime(buffer) {}
        }
        ProcessMemoryScan.expectNoCopies(of: text, after: "the buffer was released")
    }
}
