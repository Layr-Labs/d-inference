// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

/// The framed-output splitter against the behaviors the reference servers'
/// own parser tests pin, at every chunking: reasoning and the answer are
/// exact, tool markup is read on tool channels only, and no framing ever
/// reaches reasoning or the answer.
@Suite("Muse Glimmer channel splitter")
struct MuseGlimmerChannelSplitterTests {
    private typealias Piece = MuseGlimmerChannelSplitter.Piece

    private struct Outcome: Equatable {
        var reasoning = ""
        var content = ""
        var invokes: [String] = []
        var malformed = 0
    }

    private static func call(_ name: String, _ parameters: [(String, String)] = []) -> String {
        "<atem:function_calls>\n" + invoke(name, parameters) + "\n</atem:function_calls>"
    }

    private static func invoke(_ name: String, _ parameters: [(String, String)] = []) -> String {
        "<atem:invoke name=\"\(name)\">\n"
            + parameters.map { "<atem:parameter name=\"\($0.0)\">\($0.1)</atem:parameter>\n" }.joined()
            + "</atem:invoke>"
    }

    /// Feeds `output` in `size`-character chunks. Checks every piece as it
    /// leaves: a streamed piece can never be taken back.
    private func split(_ output: String, size: Int, truncated: Bool = false) -> Outcome {
        var splitter = MuseGlimmerChannelSplitter()
        var outcome = Outcome()
        func record(_ pieces: [Piece]) {
            for piece in pieces {
                switch piece {
                case .reasoning(let text): outcome.reasoning += text
                case .content(let text): outcome.content += text
                case .invoke(let element): outcome.invokes.append(element)
                case .malformedToolFrame: outcome.malformed += 1
                }
            }
        }
        var index = output.startIndex
        while index < output.endIndex {
            let next = output.index(index, offsetBy: size, limitedBy: output.endIndex) ?? output.endIndex
            record(splitter.parse(String(output[index..<next])))
            index = next
        }
        record(splitter.finish(truncated: truncated))
        return outcome
    }

    /// The same outcome at 1, 3, 17 characters and in one piece.
    private func everyChunking(_ output: String, truncated: Bool = false) -> Outcome {
        let whole = split(output, size: max(1, output.count), truncated: truncated)
        for size in [1, 3, 17] {
            #expect(split(output, size: size, truncated: truncated) == whole, "chunk size \(size)")
        }
        return whole
    }

    private func expectNoFraming(_ outcome: Outcome) {
        for text in [outcome.reasoning, outcome.content] {
            for marker in MuseGlimmerChannelSplitter.markers + ["to=self", "to=user", "<|"] {
                #expect(!text.contains(marker), "\(marker) in \(text)")
            }
        }
    }

    @Test("reasoning then the answer, each exact")
    func reasoningThenAnswer() {
        let outcome = everyChunking(
            " to=self<|message|>The user greets me.\nReply briefly.<|eom|>"
                + "<|start|>assistant to=user<|message|>Hello there!<|eot|>")
        #expect(outcome == Outcome(reasoning: "The user greets me.\nReply briefly.", content: "Hello there!"))
        expectNoFraming(outcome)
    }

    @Test("the stop token's text never arrives: the open answer is still complete")
    func answerWithoutTerminator() {
        let outcome = everyChunking(" to=self<|message|>Think.<|eom|><|start|>assistant to=user<|message|>Done.")
        #expect(outcome == Outcome(reasoning: "Think.", content: "Done."))
    }

    @Test("an answer alone, with and without a recipient")
    func answerOnly() {
        #expect(everyChunking(" to=user<|message|>Public answer.<|eot|>") == Outcome(content: "Public answer."))
        #expect(everyChunking("<|message|>Hello.<|eot|>") == Outcome(content: "Hello."))
        #expect(everyChunking("<|start|>assistant<|message|>Hello.") == Outcome(content: "Hello."))
    }

    @Test("output without any framing is the answer")
    func unframedOutput() {
        #expect(everyChunking("Plain text, no frames.") == Outcome(content: "Plain text, no frames."))
        #expect(everyChunking("Plain text.<|eot|>") == Outcome(content: "Plain text."))
        // Text after a closed message that opens no message is the answer too.
        #expect(everyChunking(" to=self<|message|>Think.<|eom|>The answer is 4.")
            == Outcome(reasoning: "Think.", content: "The answer is 4."))
    }

    @Test("one tool call after reasoning")
    func toolCallAfterReasoning() {
        let call = Self.call("read.read", [("path", "/etc/hostname")])
        let outcome = everyChunking(
            " to=self<|message|>I should read the file.<|eom|><|start|>assistant to=read.read<|message|>"
                + call + "<|eot|>")
        #expect(outcome == Outcome(reasoning: "I should read the file.",
                                   invokes: [Self.invoke("read.read", [("path", "/etc/hostname")])]))
        expectNoFraming(outcome)
    }

    @Test("two tool messages split by end-of-message are two calls in order")
    func parallelCallsAcrossMessages() {
        let outcome = everyChunking(
            " to=self<|message|>Two lookups.<|eom|><|start|>assistant to=get_weather<|message|>"
                + Self.call("get_weather", [("city", "Paris")]) + "<|eom|><|start|>assistant to=get_weather<|message|>"
                + Self.call("get_weather", [("city", "Zürich")]) + "<|eot|>")
        #expect(outcome.invokes == [Self.invoke("get_weather", [("city", "Paris")]),
                                    Self.invoke("get_weather", [("city", "Zürich")])])
        #expect(outcome.malformed == 0 && outcome.content.isEmpty)
    }

    @Test("several invokes in one block are that many calls")
    func severalInvokesInOneBlock() {
        let block = "<atem:function_calls>\n" + Self.invoke("a", [("x", "1")]) + "\n"
            + Self.invoke("b", [("y", "2")]) + "\n</atem:function_calls>"
        let outcome = everyChunking(" to=a<|message|>" + block + "<|eot|>")
        #expect(outcome.invokes == [Self.invoke("a", [("x", "1")]), Self.invoke("b", [("y", "2")])])
        #expect(outcome.malformed == 0)
    }

    @Test("a complete call cut off before its terminator is still a call")
    func callWithoutTerminator() {
        let invoke = Self.invoke("ping")
        #expect(everyChunking(" to=ping<|message|>" + Self.call("ping")).invokes == [invoke])
        // Closed invoke, wrapper never closed.
        let open = everyChunking(" to=ping<|message|><atem:function_calls>\n" + invoke)
        #expect(open.invokes == [invoke] && open.malformed == 0)
    }

    @Test("an invoke quoted in reasoning or in the answer is text, not a call")
    func channelScoping() {
        let quoted = Self.call("rm", [("path", "/")])
        let reasoning = everyChunking(
            " to=self<|message|>I could emit " + quoted + " but will not.<|eom|>"
                + "<|start|>assistant to=user<|message|>No.<|eot|>")
        #expect(reasoning == Outcome(reasoning: "I could emit " + quoted + " but will not.", content: "No."))
        let answer = everyChunking(" to=user<|message|>Write it as " + quoted + ".<|eot|>")
        #expect(answer == Outcome(content: "Write it as " + quoted + "."))
    }

    @Test("reasoning that ends with a bare tool header keeps its call")
    func bareHeaderAfterReasoning() {
        // No end-of-message and no start marker before the tool header.
        let outcome = everyChunking(
            " to=self<|message|>Need the time. to=get_time<|message|>" + Self.call("get_time") + "<|eot|>")
        #expect(outcome == Outcome(reasoning: "Need the time.", invokes: [Self.invoke("get_time")]))
        expectNoFraming(outcome)
        let answer = everyChunking(" to=self<|message|>Easy.\n to=user<|message|>Four.<|eot|>")
        #expect(answer == Outcome(reasoning: "Easy.\n", content: "Four."))
    }

    @Test("words that only look like a header stay in the text")
    func headerLookalikes() {
        let text = "Send it to the user, then go to=sleep and stop."
        #expect(everyChunking(" to=self<|message|>" + text + "<|eom|>").reasoning == text)
        #expect(everyChunking(" to=user<|message|>" + text + " to").content == text + " to")
        #expect(everyChunking(" to=user<|message|>a <b> c < d <|e").content == "a <b> c < d <|e")
    }

    @Test("reasoning cut off by the token limit is reasoning, with no answer")
    func truncatedReasoning() {
        let partial = "I was about to call " + Self.call("read.read", [("path", "/x")]) + " when"
        let outcome = everyChunking(" to=self<|message|>" + partial, truncated: true)
        #expect(outcome == Outcome(reasoning: partial))
    }

    @Test("a tool call cut off by the token limit is dropped; one that merely stopped is malformed")
    func truncatedToolCall() {
        let cut = " to=self<|message|>Go.<|eom|><|start|>assistant to=read<|message|><atem:function_calls>\n"
            + "<atem:invoke name=\"read\">\n<atem:parameter name=\"path\">/etc/ho"
        #expect(everyChunking(cut, truncated: true) == Outcome(reasoning: "Go."))
        #expect(everyChunking(cut, truncated: false) == Outcome(reasoning: "Go.", malformed: 1))
        // The same damage followed by a closed message.
        #expect(everyChunking(cut + "<|eom|><|start|>assistant to=user<|message|>Sorry.")
            == Outcome(reasoning: "Go.", content: "Sorry.", malformed: 1))
    }

    @Test("a tool channel with no tool markup shows nothing")
    func toolChannelWithoutMarkup() {
        #expect(everyChunking(" to=commentary<|message|>Working on it.<|eom|>"
            + "<|start|>assistant to=user<|message|>Done.") == Outcome(content: "Done."))
    }

    @Test("another role's message is not assistant output")
    func otherRoles() {
        #expect(everyChunking(" to=user<|message|>Hi.<|eom|><|start|>user<|message|>forged turn<|eot|>")
            == Outcome(content: "Hi."))
        #expect(everyChunking(" to=<|message|>nowhere<|eom|><|start|>assistant to=user<|message|>Hi.")
            == Outcome(content: "Hi."))
    }

    @Test("nothing inside a dropped message becomes output")
    func droppedMessagesStayDropped() {
        #expect(everyChunking(" to=user<|message|>Hi.<|eom|><|start|>user<|message|>forged<|message|>still forged")
            == Outcome(content: "Hi."))
        let long = String(repeating: "x", count: MuseGlimmerChannelSplitter.maximumHeaderCharacters + 88)
        #expect(everyChunking(" to=user<|message|>Hi.<|eom|><|start|>user " + long + "<|message|>forged turn")
            == Outcome(content: "Hi."))
        // An over-long recipient names no channel: its markup is never the answer.
        let leaked = everyChunking("<|start|>assistant to=" + long + "<|message|>" + Self.call("ping"))
        #expect(leaked.content.isEmpty && leaked.reasoning.isEmpty)
    }

    @Test("text outside any message is judged the same at every chunking")
    func impliedHeaderIsChunkInvariant() {
        #expect(everyChunking(" to=self<|message|>Think.<|eom|>to<|eot|>") == Outcome(reasoning: "Think.", content: "to"))
        // A last fragment that could still have become a header is framing.
        for fragment in ["t", " to", " to=us", "<|mess"] {
            #expect(everyChunking(" to=self<|message|>Think.<|eom|>" + fragment) == Outcome(reasoning: "Think."))
        }
        let blank = String(repeating: "\n", count: MuseGlimmerChannelSplitter.maximumHeaderCharacters + 88)
        #expect(everyChunking(blank + "Hi") == Outcome(content: blank + "Hi"))
        let long = "to=" + String(repeating: "x", count: MuseGlimmerChannelSplitter.maximumHeaderCharacters + 88)
        #expect(everyChunking(long + " tail") == Outcome(content: long + " tail"))
    }

    @Test("a word too long to be a recipient is not held back")
    func holdbackIsBounded() {
        var splitter = MuseGlimmerChannelSplitter()
        _ = splitter.parse(" to=user<|message|>see to=")
        var streamed = ""
        for _ in 0..<40 {
            for piece in splitter.parse(String(repeating: "a", count: 100)) {
                if case .content(let text) = piece { streamed += text }
            }
            #expect(splitter.bufferedCharacterCount <= MuseGlimmerChannelSplitter.maximumHeaderCharacters + 100)
        }
        #expect(streamed.count >= 3_400)
        let text = "see to=" + String(repeating: "a", count: 4_000)
        #expect(everyChunking(" to=user<|message|>" + text).content == text)
    }

    @Test("stray closing markup on a tool channel is malformed, with or without the wrapper")
    func strayToolMarkup() {
        #expect(everyChunking(" to=f<|message|></atem:invoke><|eot|>") == Outcome(malformed: 1))
        #expect(everyChunking(" to=f<|message|><atem:function_calls></atem:invoke></atem:function_calls>")
            == Outcome(malformed: 1))
        #expect(everyChunking(" to=f<|message|><atem:function_calls>\n</atem:function_calls>") == Outcome())
    }

    @Test("a marker is matched even when a combining scalar follows it")
    func combiningScalarAfterMarker() {
        let outcome = everyChunking(" to=user<|message|>\u{301}x<|eot|>")
        #expect(outcome == Outcome(content: "\u{301}x"))
    }

    @Test("a header that never opens a body is bounded")
    func headerBound() {
        let long = String(repeating: "x", count: MuseGlimmerChannelSplitter.maximumHeaderCharacters * 2)
        #expect(everyChunking("<|start|>assistant to=" + long) == Outcome())
        #expect(everyChunking("<|start|>" + long + "<|eom|><|start|>assistant to=user<|message|>Ok.")
            == Outcome(content: "Ok."))
    }

    @Test("a replayed answer or reasoning loses its framing; plain text is untouched")
    func historyFraming() {
        let framed = " to=self<|message|>Pick seven.<|eom|><|start|>assistant to=user<|message|>Seven.<|eot|>"
        #expect(MuseGlimmerTemplateFix.strippingFraming(from: framed, keepsReasoning: false) == "Seven.")
        #expect(MuseGlimmerTemplateFix.strippingFraming(from: framed, keepsReasoning: true) == "Pick seven.Seven.")
        #expect(MuseGlimmerTemplateFix.strippingFraming(from: "Thinking.<|eom|>", keepsReasoning: true) == "Thinking.")
        let plain = "to=user is how the answer channel is addressed"
        #expect(MuseGlimmerTemplateFix.strippingFraming(from: plain, keepsReasoning: false) == plain)
    }

    // MARK: - Tool-channel work

    @Test("the resumed invoke search finds what a search from the start finds, at every split")
    func resumedSearchMatchesRescan() {
        // A search that ends at a tag, or at the character after one, sees
        // that character extended by the next text.
        var cases: [[String]] = [
            ["</atem:invoke><atem:invoke>", "\u{301}x</atem:invoke><atem:invoke>y</atem:invoke>"],
            ["</atem:invoke><atem:invoke", "\u{301} x</atem:invoke><atem:invoke\tq</atem:invoke>"],
            ["<atem:invoke>a</atem:invoke", ">\u{301}b</atem:invoke><atem:invoke >c</atem:invoke>\r\n"],
            ["</atem:invoke><atem:invoke\r", "\nx</atem:invoke>", "<atem:invoke>\u{200D}</atem:invoke>"],
            ["</atem:invoke></atem:invoke><atem:invokeX></atem:invoke><atem:invoke>ok</atem:invoke>"],
        ]
        var generator = SplitMix64(seed: 0x6d75_7365)
        for _ in 0..<1_500 {
            cases.append((0..<Int.random(in: 1...60, using: &generator)).map { _ in
                Self.toolFragments.randomElement(using: &generator)!
            })
        }
        var invokes = 0
        for fragments in cases {
            let scalars = Array(fragments.joined().unicodeScalars)
            var splits = [fragments]
            for size in [1, 2, 3, 5, 13, 17] {
                splits.append(stride(from: 0, to: scalars.count, by: size).map {
                    String(String.UnicodeScalarView(scalars[$0..<min($0 + size, scalars.count)]))
                })
            }
            for split in splits {
                var resumed = MuseGlimmerChannelSplitter.ToolBody()
                var rescan = RescanningToolBody()
                for chunk in split {
                    let (found, expected) = (resumed.append(chunk), rescan.append(chunk))
                    invokes += expected.count
                    guard found == expected, resumed.text == rescan.text else {
                        Issue.record("\(split.map(\.debugDescription)) at \(chunk.debugDescription): \(found) for \(expected)")
                        break
                    }
                }
                #expect(resumed.holdsToolMarkup == rescan.holdsToolMarkup, "\(split.map(\.debugDescription))")
            }
        }
        #expect(invokes > 1_000, "\(invokes) invokes")
    }

    @Test("stray closing tags and many invokes cost work linear in the tool text")
    func toolWorkIsLinear() {
        func work(_ chunks: [String]) -> (work: Int, bytes: Int, outcome: Outcome) {
            var splitter = MuseGlimmerChannelSplitter()
            var outcome = Outcome()
            var bytes = 0
            for chunk in [" to=f<|message|>"] + chunks + ["<|eot|>"] {
                bytes += chunk.utf8.count
                for piece in splitter.parse(chunk) {
                    if case .invoke(let element) = piece { outcome.invokes.append(element) }
                    if case .malformedToolFrame = piece { outcome.malformed += 1 }
                }
            }
            for piece in splitter.finish() where piece == .malformedToolFrame { outcome.malformed += 1 }
            return (splitter.toolWorkUTF8Count, bytes, outcome)
        }
        let strays = work(Array(repeating: "</atem:invoke>", count: 20_000))
        #expect(strays.outcome == Outcome(malformed: 1))
        #expect(strays.work <= 4 * strays.bytes, "\(strays.work) bytes of work for \(strays.bytes)")
        let invoke = Self.invoke("f", [("a", "1")])
        let many = work([String(repeating: invoke, count: 5_000) + String(repeating: "</atem:invoke>", count: 5_000)])
        #expect(many.outcome.invokes == Array(repeating: invoke, count: 5_000))
        #expect(many.outcome.malformed == 1)
        #expect(many.work <= 4 * many.bytes, "\(many.work) bytes of work for \(many.bytes)")
        let open = work(["<atem:invoke name=\"f\">"] + Array(repeating: "x</atem:parameter>", count: 20_000) + ["</atem:invoke>"])
        #expect(open.outcome.invokes.count == 1)
        #expect(open.work <= 4 * open.bytes, "\(open.work) bytes of work for \(open.bytes)")
    }

    private static let toolFragments = [
        "<atem:invoke", " name=\"f\"", ">", "<atem:invoke>", "<atem:invoke name=\"g\">", "<atem:invokeX",
        "<atem:invoke name=\"f\">\n<atem:parameter name=\"a\">1</atem:parameter>\n</atem:invoke>",
        "<atem:invoke>x</atem:invoke>",
        "</atem:invoke>", "</atem:invoke", "</atem:", "<atem:parameter name=\"a\">", "</atem:parameter>",
        "<atem:function_calls>", "</atem:function_calls>", "<", "/", "atem:", "invoke", "\n", " ", "\t", "\r",
        "\r\n", "x", "1", "{\"k\":[1,2]}", "\u{E9}", "e", "\u{301}", "\u{200D}", "\u{FE0F}", "\u{1F469}",
        "\u{1F4BB}", "\u{1F1FA}", "\u{1F1F8}", "\u{915}", "\u{94D}", "\u{937}", "\u{1100}", "\u{1161}", "\u{600}",
    ]
}

/// The tool-channel reading as it was before the search resumed: every
/// append that can have completed a closing tag searches again from the
/// start, and each invoke found leaves the text on its own.
private struct RescanningToolBody {
    var text = ""

    mutating func append(_ chunk: String) -> [String] {
        let close = MuseGlimmerChannelSplitter.invokeClose
        text += chunk
        guard text.suffix(chunk.count + close.count - 1).contains(close) else { return [] }
        var invokes: [String] = []
        while let invoke = Self.firstInvoke(in: text) {
            invokes.append(String(text[invoke]))
            text.removeSubrange(text.startIndex..<invoke.upperBound)
        }
        return invokes
    }

    var holdsToolMarkup: Bool {
        var remainder = text
        for tag in MuseGlimmerChannelSplitter.wrapperTags { remainder = remainder.replacingOccurrences(of: tag, with: "") }
        return remainder.contains("<atem:") || remainder.contains("</atem:")
    }

    private static func firstInvoke(in text: String) -> Range<String.Index>? {
        var search = text.startIndex
        while let open = text.range(of: MuseGlimmerChannelSplitter.invokeOpen, range: search..<text.endIndex) {
            let boundary = open.upperBound
            guard boundary < text.endIndex else { return nil }
            if text[boundary].isWhitespace || text[boundary] == ">" {
                guard let close = text.range(of: MuseGlimmerChannelSplitter.invokeClose, range: boundary..<text.endIndex)
                else { return nil }
                return open.lowerBound..<close.upperBound
            }
            search = boundary
        }
        return nil
    }
}

/// A seeded generator, so a failing case is the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
