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
}
