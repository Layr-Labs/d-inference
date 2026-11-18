// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Muse Glimmer's output parsers under the checks the inbound JSON depth,
/// queue budget and TOML fixes were given: seeded random and hostile streams
/// at every chunking. The channel splitter, the tool frame, the SDK's ATEM
/// readers and the scheduler's forwarding body must never crash or stall,
/// never hold reasoning or the answer without bound, never pass framing to a
/// client, and never fail a request as the provider's error (500): a frame
/// the model gets wrong is its noncompliance (422).
@Suite("Muse Glimmer parser fuzz")
struct MuseGlimmerParserFuzzTests {
    private typealias Piece = MuseGlimmerChannelSplitter.Piece

    /// SplitMix64: the same streams on every run and every machine.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Framing, tool markup, their broken halves, and text that is hard on a
    /// text-level parser: combining marks, joiners, flags, CRLF, NUL.
    private static let fragments: [String] = [
        "<|start|>", "<|message|>", "<|eom|>", "<|eot|>", "<|end_of_text|>", "<|start|>assistant",
        "assistant", " to=self", " to=user", " to=get_weather", " to=get_weather.get_weather", " to=", "to=",
        " to=functions.lookup", "<|", "|>", "<|mes", "sage|>", "<|eo", "m|>", "<|start", "|",
        "<atem:function_calls>", "</atem:function_calls>", "\n",
        "<atem:invoke name=\"get_weather\">", "<atem:invoke name=\"get_weather.get_weather\">",
        "<atem:invoke name='docs_read'>", "<atem:invoke>", "<atem:invoke name=\"\">", "<atem:invokeX>",
        "<atem:invoke", "<atem:parameter name=\"city\">", "<atem:parameter name=\"days\">",
        "<atem:parameter name=\"tags\">", "<atem:parameter name=\"payload\">", "<atem:parameter>",
        "</atem:parameter>", "</atem:invoke>", "<atem:", "</atem:",
        "Paris", "3", "6.0", "true", "[\"a\"]", "{\"k\": [1, {\"n\": null}]}", "[[[[", "]]]]", "{\"a\":",
        " ", "  ", "\t", "\r\n", "\r", "x", "Hello", "é", "e\u{301}", "\u{301}", "🙂", "👩‍👩‍👧", "🇫🇷", "\u{200D}",
        "\u{FFFD}", "\u{0}", "<", ">", "\"", "'", "=", "名前",
    ]

    private static func randomOutput(_ generator: inout Generator, maxFragments: Int = 60) -> String {
        let count = Int.random(in: 0...maxFragments, using: &generator)
        var text = ""
        for _ in 0..<count {
            if Int.random(in: 0..<10, using: &generator) == 0 {
                // A run of random ASCII, framing characters overweighted.
                let alphabet = Array("ab <>|=/:\"'\n\tto=self")
                for _ in 0..<Int.random(in: 1...12, using: &generator) {
                    text.append(alphabet.randomElement(using: &generator)!)
                }
            } else {
                text += fragments.randomElement(using: &generator)!
            }
        }
        return text
    }

    // MARK: - Splitter

    private struct Outcome: Equatable {
        var reasoning = ""
        var content = ""
        var invokes: [String] = []
        var malformed = 0
    }

    /// Feeds `chunks` to a fresh splitter, checking every piece as it leaves.
    private func split(
        _ chunks: [String], truncated: Bool = false, label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Outcome {
        var splitter = MuseGlimmerChannelSplitter()
        var outcome = Outcome()
        func record(_ pieces: [Piece]) {
            for piece in pieces {
                switch piece {
                case .reasoning(let text), .content(let text):
                    for marker in MuseGlimmerChannelSplitter.markers where text.contains(marker) {
                        Issue.record("\(label): \(marker) left in \(text.debugDescription)", sourceLocation: sourceLocation)
                    }
                    if case .reasoning = piece { outcome.reasoning += text } else { outcome.content += text }
                case .invoke(let element):
                    if !element.hasPrefix(MuseGlimmerChannelSplitter.invokeOpen)
                        || !element.hasSuffix(MuseGlimmerChannelSplitter.invokeClose)
                    {
                        Issue.record("\(label): invoke \(element.debugDescription)", sourceLocation: sourceLocation)
                    }
                    outcome.invokes.append(element)
                case .malformedToolFrame:
                    outcome.malformed += 1
                }
            }
        }
        for chunk in chunks { record(splitter.parse(chunk)) }
        record(splitter.finish(truncated: truncated))
        #expect(splitter.bufferedCharacterCount == 0, "\(label): held after finish", sourceLocation: sourceLocation)
        return outcome
    }

    private static func characterChunks(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<next]))
            index = next
        }
        return chunks
    }

    /// Chunks that may cut a grapheme between its scalars, as a detokenizer can.
    private static func scalarChunks(_ text: String, size: Int) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return stride(from: 0, to: scalars.count, by: size).map { start in
            var chunk = String.UnicodeScalarView()
            chunk.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
            return String(chunk)
        }
    }

    private static func randomChunks(_ text: String, _ generator: inout Generator) -> [String] {
        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let size = Int.random(in: 1...24, using: &generator)
            let next = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[index..<next]))
            index = next
        }
        return chunks
    }

    @Test("random framed streams: no framing leaves, and every chunking at character boundaries agrees")
    func randomStreams() {
        var generator = Generator(state: 0x4D75_7365_2130)
        var mismatches = 0
        for caseIndex in 0..<600 {
            let output = Self.randomOutput(&generator)
            for truncated in [false, true] {
                let label = "case \(caseIndex) truncated \(truncated) \(output.debugDescription)"
                let whole = split([output], truncated: truncated, label: label)
                var chunkings = [1, 2, 3, 5, 7, 13, 64].map { Self.characterChunks(output, size: $0) }
                chunkings.append(Self.randomChunks(output, &generator))
                for chunks in chunkings where split(chunks, truncated: truncated, label: label) != whole {
                    mismatches += 1
                    Issue.record("\(label): chunking \(chunks.map(\.count)) differs from one piece")
                }
                // Cut between scalars: the safety checks inside `split` only.
                for size in [1, 2, 5] {
                    _ = split(Self.scalarChunks(output, size: size), truncated: truncated, label: label)
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test("random bytes, invalid UTF-8 and multi-byte characters split across pieces")
    func randomBytes() {
        var generator = Generator(state: 0x0B17_E5)
        let hot: [UInt8] = Array("<|>atem:/to=self \n".utf8) + [0xC3, 0xA9, 0xF0, 0x9F, 0x99, 0x82, 0xFF, 0x80, 0xE2]
        for caseIndex in 0..<1_000 {
            let length = Int.random(in: 0...600, using: &generator)
            let bytes: [UInt8] = (0..<length).map { _ in
                Bool.random(using: &generator) ? hot.randomElement(using: &generator)! : UInt8.random(in: 0...255, using: &generator)
            }
            // A careless detokenizer decodes each piece alone: broken sequences become U+FFFD.
            var chunks: [String] = []
            var start = 0
            while start < bytes.count {
                let end = min(bytes.count, start + Int.random(in: 1...9, using: &generator))
                chunks.append(String(decoding: bytes[start..<end], as: UTF8.self))
                start = end
            }
            let label = "bytes case \(caseIndex)"
            _ = split(chunks, label: label)
            _ = split([String(decoding: bytes, as: UTF8.self)], truncated: true, label: label)
        }
        // A real answer whose multi-byte characters arrive one byte at a time.
        let answer = "Zürich 🙂 名前 👩‍👩‍👧 🇫🇷"
        let framed = Array((" to=user<|message|>" + answer).utf8)
        let oneByteAtATime = framed.map { String(decoding: [$0], as: UTF8.self) }
        let outcome = split(oneByteAtATime, label: "byte at a time")
        #expect(!outcome.content.isEmpty && outcome.invokes.isEmpty)
        #expect(split([String(decoding: framed, as: UTF8.self)], label: "whole").content == answer)
    }

    @Test("stray and duplicated channel headers stay bounded and never reach the answer")
    func strayHeaders() {
        let cases: [String] = [
            String(repeating: "<|start|>", count: 20_000) + "assistant to=user<|message|>Ok.",
            String(repeating: "<|start|>assistant", count: 5_000) + " to=user<|message|>Ok.",
            " to=user<|message|>" + String(repeating: "<|message|>", count: 20_000) + "Ok.",
            " to=self to=self to=user to=self<|message|>R<|eom|><|start|>assistant to=user to=user<|message|>A",
            String(repeating: " to=self<|message|>r<|eom|>", count: 5_000) + "<|start|>assistant to=user<|message|>A",
            String(repeating: "<|eom|>", count: 20_000) + " to=user<|message|>Ok.",
            String(repeating: "<|eot|><|end_of_text|>", count: 10_000),
            " to=self<|message|>" + String(repeating: " to=", count: 20_000) + "<|eom|>",
            " to=user<|message|>" + String(repeating: "to=get_weather ", count: 10_000),
            "<|start|>" + String(repeating: "x", count: 100_000) + "<|message|>hidden<|eom|><|start|>assistant to=user<|message|>Ok.",
        ]
        for (index, output) in cases.enumerated() {
            for size in [1, 7, 4_096] {
                var splitter = MuseGlimmerChannelSplitter()
                var maximumHeld = 0
                for chunk in Self.characterChunks(output, size: size) {
                    for piece in splitter.parse(chunk) {
                        if case .content(let text) = piece {
                            for marker in MuseGlimmerChannelSplitter.markers {
                                #expect(!text.contains(marker), "case \(index) size \(size)")
                            }
                        }
                    }
                    maximumHeld = max(maximumHeld, splitter.bufferedCharacterCount)
                }
                _ = splitter.finish()
                // A held tail is at most a header or a marker's first characters.
                #expect(maximumHeld <= MuseGlimmerChannelSplitter.maximumHeaderCharacters + size + 16,
                        "case \(index) size \(size) held \(maximumHeld)")
            }
        }
    }

    /// Wall time of `body`, printed for the evidence log.
    private func timed(_ label: String, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure(body)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("MUSE-FUZZ-TIMING \(label) \(String(format: "%.3f", seconds)) s")
        return seconds
    }

    @Test("huge arguments and unterminated frames stream in linear time, exact")
    func hugeArguments() {
        // 512 KiB: about the most text a 131072-token output can hold.
        let size = 512 * 1_024
        let spaced = String(repeating: "word ", count: size / 5)
        let blob = String(repeating: "QUJD", count: size / 4)
        let header = " to=get_weather<|message|><atem:function_calls>\n<atem:invoke name=\"get_weather\">\n"
            + "<atem:parameter name=\"city\">"
        for (name, value) in [("spaced", spaced), ("blob", blob), ("to-prefixed", "to=" + blob)] {
            let complete = header + value + "</atem:parameter>\n</atem:invoke>\n</atem:function_calls><|eot|>"
            var outcome = Outcome()
            let seconds = timed("complete-\(name)") {
                outcome = split(Self.characterChunks(complete, size: 4), label: "huge \(name)")
            }
            #expect(seconds < 120, "complete \(name) took \(seconds) s")
            #expect(outcome.invokes.count == 1 && outcome.malformed == 0)
            let reading = ATEMReferenceReader(tools: Self.sdkTools).read(outcome.invokes.first ?? "")
            #expect(reading.calls.first?.toolCall.function.arguments["city"] == .string(value))
            // The same value as the answer: streamed out, never held.
            var splitter = MuseGlimmerChannelSplitter()
            var maximumHeld = 0
            var streamed = 0
            let answerSeconds = timed("answer-\(name)") {
                for chunk in Self.characterChunks(" to=user<|message|>" + value, size: 4) {
                    for piece in splitter.parse(chunk) { if case .content(let text) = piece { streamed += text.count } }
                    maximumHeld = max(maximumHeld, splitter.bufferedCharacterCount)
                }
                for piece in splitter.finish() { if case .content(let text) = piece { streamed += text.count } }
            }
            #expect(answerSeconds < 120)
            #expect(streamed == value.count)
            #expect(maximumHeld <= MuseGlimmerChannelSplitter.maximumHeaderCharacters + 16, "\(name) held \(maximumHeld)")
            // Never closed: malformed at a stop, dropped at the token limit.
            let open = header + value
            var stopped = Outcome()
            var cut = Outcome()
            let openSeconds = timed("unterminated-\(name)") {
                stopped = split(Self.characterChunks(open, size: 4), label: "open \(name)")
                cut = split(Self.characterChunks(open, size: 4), truncated: true, label: "open cut \(name)")
            }
            #expect(openSeconds < 240)
            #expect(stopped == Outcome(malformed: 1))
            #expect(cut == Outcome())
        }
    }

    @Test("repeated stray closing tags on a tool channel do not stall the stream")
    func repeatedStrayCloses() {
        // About 40 000 output tokens of stray markup, one tag per piece.
        for (name, unit) in [("close", "</atem:invoke>"), ("near-open-close", "<atem:invokeX</atem:invoke>"),
                             ("open-close-unbounded", "<atem:invoke</atem:invoke>")] {
            for count in [5_000, 10_000] {
                var outcome = Outcome()
                let seconds = timed("stray-\(name)-\(count)") {
                    outcome = split([" to=get_weather<|message|>"] + Array(repeating: unit, count: count),
                                    label: "stray \(name)")
                }
                #expect(seconds < 60, "\(name) x\(count) took \(seconds) s")
                #expect(outcome.malformed == 1 && outcome.reasoning.isEmpty && outcome.content.isEmpty)
            }
        }
    }

    // MARK: - Tool frame and the SDK's ATEM readers

    private static var sdkTools: [[String: any Sendable]] {
        let string: [String: any Sendable] = ["type": "string"]
        let weatherProperties: [String: any Sendable] = [
            "city": string,
            "days": ["type": "integer"] as [String: any Sendable],
            "detail": ["type": "boolean"] as [String: any Sendable],
            "tags": ["type": "array", "items": string] as [String: any Sendable],
        ]
        let weather: [String: any Sendable] = [
            "name": "get_weather",
            "parameters": ["type": "object", "required": ["city"] as [any Sendable],
                           "properties": weatherProperties] as [String: any Sendable],
        ]
        let storeProperties: [String: any Sendable] = [
            "payload": [:] as [String: any Sendable],
            "note": ["anyOf": [["type": "array"] as [String: any Sendable], string] as [any Sendable]]
                as [String: any Sendable],
        ]
        let store: [String: any Sendable] = [
            "name": "store",
            "parameters": ["type": "object", "properties": storeProperties] as [String: any Sendable],
        ]
        return [["type": "function", "function": weather], ["type": "function", "function": store]]
    }

    private static func nested(_ depth: Int, object: Bool) -> String {
        object
            ? String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
            : String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
    }

    private static func depth(of value: MLXLMCommon.JSONValue) -> Int {
        switch value {
        case .array(let items): 1 + (items.first.map(depth) ?? 0)
        case .object(let fields): 1 + (fields.values.first.map(depth) ?? 0)
        default: 0
        }
    }

    @Test("random invokes through the tool frame, the reference reader and the strict parser")
    func randomInvokes() throws {
        var generator = Generator(state: 0xA7E3)
        let reader = ATEMReferenceReader(tools: Self.sdkTools)
        let strict = ATEMToolCallParser()
        let declared: Set<String> = ["get_weather", "store"]
        for _ in 0..<3_000 {
            let body = Self.randomOutput(&generator, maxFragments: 40)
            let element = "<atem:invoke name=\"get_weather.get_weather\">" + body + "</atem:invoke>"
            for text in [body, element] {
                let reading = reader.read(text)
                for call in reading.calls { #expect(!call.toolCall.function.name.isEmpty) }
                let block = MuseGlimmerToolFrame.block(invoke: text, declaredNames: declared)
                _ = strict.parse(content: block, tools: Self.sdkTools)
                _ = strict.parseEOS(text, tools: Self.sdkTools)
                _ = try JSONEncoder().encode(reading.calls.map(\.toolCall))
            }
        }
    }

    /// The arrays and objects a decoded argument value may open: its call's
    /// arguments then nest at most `JSONNestingLimit.maximumDepth` (64), so
    /// the call can be replayed, and encoding it stays far from the bottom of
    /// a cooperative thread's 512 KiB stack (`JSONEncoder` exhausted it
    /// between 160 and 192 levels of objects in a release build, between 128
    /// and 160 in a debug one).
    private static let valueDepthBound = JSONNestingLimit.maximumDepth - 1

    @Test("deeply nested argument values never exhaust the stack: past the bound they stay text")
    func deepNesting() throws {
        let reader = ATEMReferenceReader(tools: Self.sdkTools)
        let strict = ATEMToolCallParser()
        for depth in [16, Self.valueDepthBound, Self.valueDepthBound + 1, 160, 200, 256, 512, 513, 4_096, 100_000] {
            for object in [false, true] {
                let value = Self.nested(depth, object: object)
                for parameter in ["payload", "note", "tags"] {
                    let tool = parameter == "tags" ? "get_weather" : "store"
                    let city = tool == "get_weather" ? "<atem:parameter name=\"city\">Paris</atem:parameter>\n" : ""
                    let element = "<atem:invoke name=\"\(tool)\">\n" + city
                        + "<atem:parameter name=\"\(parameter)\">\(value)</atem:parameter>\n</atem:invoke>"
                    let reading = reader.read(element)
                    let call = try #require(reading.calls.first, "depth \(depth) \(parameter)")
                    let decoded = try #require(call.toolCall.function.arguments[parameter])
                    if case .string = decoded {
                        // Undecoded text is kept as written.
                        #expect(decoded == .string(value))
                    } else {
                        #expect(Self.depth(of: decoded) <= Self.valueDepthBound, "depth \(depth) \(parameter)")
                        if parameter == "payload" {
                            // An untyped parameter keeps the decoded value whole.
                            #expect(Self.depth(of: decoded) == depth, "depth \(depth) \(parameter)")
                        }
                    }
                    if parameter == "payload" {
                        #expect((depth <= Self.valueDepthBound) == (decoded != .string(value)), "depth \(depth)")
                    }
                    print("MUSE-FUZZ-DEPTH \(depth) \(object ? "object" : "array") \(parameter): "
                          + (decoded == .string(value) ? "kept as text" : "decoded, depth \(Self.depth(of: decoded))"))
                    // Hashing, equality and encoding walk the whole value, as
                    // the router's `JSONEncoder.openAIServer` does.
                    #expect(call.toolCall == call.toolCall)
                    _ = Set([call.toolCall])
                    _ = try JSONEncoder.openAIServer.encode(call.toolCall.function.arguments)
                    // The strict parser types values through the same normalization.
                    let strictCall = strict.parse(
                        content: MuseGlimmerToolFrame.block(invoke: element, declaredNames: ["get_weather", "store"]),
                        tools: Self.sdkTools)
                    if let strictValue = strictCall?.function.arguments[parameter], strictValue != .string(value) {
                        #expect(Self.depth(of: strictValue) <= Self.valueDepthBound, "strict depth \(depth) \(parameter)")
                    }
                    _ = try strictCall.map { try JSONEncoder.openAIServer.encode($0.function.arguments) }
                }
            }
        }
    }

    @Test("a hostile parameter schema is read in bounded time")
    func hostileSchemas() throws {
        // Deep anyOf, a reference cycle, and one definition reached by many spellings of its path.
        // 28 anyOf levels: about the deepest a request under the inbound 64-level limit can carry.
        var deep: [String: any Sendable] = ["type": "integer"]
        for _ in 0..<28 {
            deep = ["anyOf": [deep, ["type": "string"] as [String: any Sendable]] as [any Sendable]]
        }
        var definitions: [String: any Sendable] = ["d0": ["type": "number"] as [String: any Sendable]]
        for level in 1..<64 {
            let previous = "#/definitions/d\(level - 1)"
            let doubled = "#/definitions//d\(level - 1)"
            let first: [String: any Sendable] = ["$ref": previous]
            let second: [String: any Sendable] = ["$ref": doubled]
            let both: [String: any Sendable] = ["allOf": [first, second] as [any Sendable]]
            definitions["d\(level)"] = ["anyOf": [first, second, both] as [any Sendable]] as [String: any Sendable]
        }
        definitions["loop"] = ["$ref": "#/definitions/loop"] as [String: any Sendable]
        let properties: [String: any Sendable] = [
            "deep": deep, "chain": ["$ref": "#/definitions/d63"] as [String: any Sendable],
            "loop": ["$ref": "#/definitions/loop"] as [String: any Sendable],
        ]
        let parameters: [String: any Sendable] = [
            "type": "object", "definitions": definitions, "properties": properties,
        ]
        let function: [String: any Sendable] = ["name": "f", "parameters": parameters]
        let tools: [[String: any Sendable]] = [["type": "function", "function": function]]
        let reader = ATEMReferenceReader(tools: tools)
        let invokes = String(repeating: "<atem:invoke name=\"f\"><atem:parameter name=\"deep\">7</atem:parameter>"
            + "<atem:parameter name=\"chain\">6.0</atem:parameter><atem:parameter name=\"loop\">[1]</atem:parameter>"
            + "</atem:invoke>\n", count: 2_000)
        var calls = 0
        let seconds = timed("hostile-schema-2000-calls") { calls = reader.read(invokes).calls.count }
        #expect(calls == 2_000)
        #expect(seconds < 60, "took \(seconds) s")
    }

    @Test("values that hold closing markup: the reader keeps them; the stream refuses or returns them, never fails")
    func closingMarkupInValues() throws {
        let element = "<atem:invoke name=\"get_weather\">\n<atem:parameter name=\"city\">a</atem:invoke>b"
            + "</atem:parameter>\n</atem:invoke>"
        let reading = ATEMReferenceReader(tools: Self.sdkTools).read(element)
        #expect(reading.calls.first?.toolCall.function.arguments["city"] == .string("a</atem:invoke>b"))
        let outcome = split([" to=get_weather<|message|><atem:function_calls>\n" + element
                             + "\n</atem:function_calls>"], label: "closing markup in a value")
        print("MUSE-FUZZ-NOTE closing-markup-in-value splitter invokes=\(outcome.invokes.count) "
              + "malformed=\(outcome.malformed) first=\(outcome.invokes.first?.debugDescription ?? "nil")")
    }

    #if DEBUG
    // MARK: - The scheduler's forwarding body

    private static let modelID = MuseGlimmerModelPolicy.catalogModelID
    private static let modelType = MuseGlimmerModelPolicy.modelType

    private static var tools: [[String: Any]] { [
        ["type": "function", "function": [
            "name": "get_weather", "description": "Weather for a city.",
            "parameters": ["type": "object", "required": ["city"], "properties": [
                "city": ["type": "string"], "days": ["type": "integer"],
                "detail": ["type": "boolean"], "tags": ["type": "array", "items": ["type": "string"]]]]]],
        ["type": "function", "function": [
            "name": "docs_read", "description": "Read one document.",
            "parameters": ["type": "object", "required": ["path"],
                           "properties": ["path": ["type": "string"]]]]],
        ["type": "function", "function": [
            "name": "store", "description": "Store anything.",
            "parameters": ["type": "object", "properties": ["payload": [String: Any](), "note": [
                "anyOf": [["type": "array"], ["type": "string"]]],
                "list": ["type": "array", "items": ["type": "integer"]],
                "record": ["type": "object", "properties": [
                    "list": ["type": "array", "items": ["type": "integer"]]]]]]]],
    ] }

    /// A forced tool choice compiles a grammar, which refuses `anyOf` at
    /// admission, so `store` goes without `note`.
    private static var forcedTools: [[String: Any]] {
        tools.map { tool in
            guard var function = tool["function"] as? [String: Any], function["name"] as? String == "store",
                  var parameters = function["parameters"] as? [String: Any],
                  var properties = parameters["properties"] as? [String: Any]
            else { return tool }
            properties["note"] = nil
            parameters["properties"] = properties
            function["parameters"] = parameters
            var tool = tool
            tool["function"] = function
            return tool
        }
    }

    /// Strict mode refuses `anyOf` at admission (a 400), so `store` is left out.
    private static var strictTools: [[String: Any]] {
        tools.filter { (($0["function"] as? [String: Any])?["name"] as? String) != "store" }.map { tool in
            var tool = tool
            var function = tool["function"] as! [String: Any]
            function["strict"] = true
            tool["function"] = function
            return tool
        }
    }

    private struct Fixture {
        let name: String
        let request: OpenAIChatCompletionRequest
        let prepared: ToolChoicePromptPolicy.Prepared
        let controls: ChatTemplateControls
        let reference: Bool

        init(_ name: String, tools: [[String: Any]]? = MuseGlimmerParserFuzzTests.tools,
             extra: [String: Any] = [:], reference: Bool = true) throws {
            self.name = name
            self.reference = reference
            var body: [String: Any] = [
                "model": MuseGlimmerParserFuzzTests.modelID, "stream": true,
                "messages": [["role": "user", "content": "Weather in Paris?"]],
            ]
            if let tools { body["tools"] = tools }
            body.merge(extra) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: body)
            request = try ProviderLoop.decodeOpenAIRequest(data, modelType: MuseGlimmerParserFuzzTests.modelType)
            controls = ProviderLoop.extractChatTemplateControls(from: data)
            var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: MuseGlimmerParserFuzzTests.modelType)
            prepared.declaredTools = controls.declaredTools
            self.prepared = prepared
        }

        var withholdsReasoning: Bool {
            ProviderPromptContractPipeline.withholdsReasoning(
                request, controls: controls, modelType: MuseGlimmerParserFuzzTests.modelType)
        }
    }

    private static func fixtures() throws -> [Fixture] {
        [
            try Fixture("auto"),
            try Fixture("auto, strict parser", reference: false),
            try Fixture("required", tools: Self.forcedTools, extra: ["tool_choice": "required"]),
            try Fixture("named", tools: Self.forcedTools,
                        extra: ["tool_choice": ["type": "function", "function": ["name": "docs_read"]]]),
            try Fixture("none", extra: ["tool_choice": "none"]),
            try Fixture("strict tools", tools: Self.strictTools),
            try Fixture("parallel_tool_calls false", extra: ["parallel_tool_calls": false]),
            try Fixture("no tools", tools: nil),
            try Fixture("reasoning withheld", extra: ["reasoning": ["exclude": true]]),
        ]
    }

    private struct StreamOutcome: Equatable {
        var reasoning = ""
        var content = ""
        var calls: [String] = []
        /// The HTTP status of a refusal.
        var refused: Int?
    }

    /// The scheduler's own forwarding body over a scripted engine stream. A
    /// refusal must be the model's noncompliance (422).
    private func stream(
        _ fixture: Fixture, _ chunks: [String], finish: String = "stop", label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> StreamOutcome {
        var events: [GenerationEvent] = chunks.map { .chunk($0) }
        events.append(.info(promptTokens: 40, completionTokens: 30, tokensPerSecond: 50, finishReason: finish))
        let scripted = events
        let upstream = AsyncStream<GenerationEvent> { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
        var outcome = StreamOutcome()
        do {
            let handler = try ToolStreamPreparation.makeHandler(
                request: fixture.request, prepared: fixture.prepared, modelType: Self.modelType)
            var scheduler = MultiModelBatchSchedulerEngine(registryProvider: { [:] })
            scheduler.museGlimmerReferenceToolCalls = fixture.reference
            let output = try scheduler._testMakeEventStream(
                upstream: upstream, cancelUpstream: {}, prepared: fixture.prepared,
                releaseBox: OneShotRelease(release: { _ in }, modelId: Self.modelID), toolHandler: handler,
                withholdReasoning: fixture.withholdsReasoning, nativeGlimmerChannels: true)
            for try await event in output {
                switch event {
                case .content(let text): outcome.content += text
                case .parsed(let parsed):
                    outcome.content += parsed.content
                    outcome.reasoning += parsed.reasoningContent ?? ""
                case .toolCall(let call):
                    outcome.calls.append(call.function.name + String(describing: call.function.arguments.sorted { $0.key < $1.key }))
                case .toolCallDelta(let delta):
                    if let call = delta.completed {
                        outcome.calls.append(call.function.name + String(describing: call.function.arguments.sorted { $0.key < $1.key }))
                    }
                case .logprobs, .info: break
                }
            }
        } catch let error as MultiModelBatchSchedulerEngineError {
            let status = ProviderLoop.mapInferenceErrorToStatus(error)
            if status != 422 {
                Issue.record("\(label) [\(fixture.name)]: \(error) is \(status), not 422", sourceLocation: sourceLocation)
            }
            if case .generationFailed = error {
                Issue.record("\(label) [\(fixture.name)]: provider failure \(error)", sourceLocation: sourceLocation)
            }
            if case .invalidToolPayload = error {
                Issue.record("\(label) [\(fixture.name)]: invalidToolPayload \(error)", sourceLocation: sourceLocation)
            }
            return StreamOutcome(refused: Int(status))
        } catch {
            Issue.record("\(label) [\(fixture.name)]: unexpected \(error)", sourceLocation: sourceLocation)
            return StreamOutcome(refused: -1)
        }
        for text in [outcome.reasoning, outcome.content] {
            for marker in MuseGlimmerChannelSplitter.markers where text.contains(marker) {
                Issue.record("\(label) [\(fixture.name)]: \(marker) reached the client", sourceLocation: sourceLocation)
            }
        }
        return outcome
    }

    @Test("random outputs through every tool choice: a call, an answer or a 422, the same at every chunking")
    func randomOutputsThroughTheScheduler() async throws {
        var generator = Generator(state: 0x5C4E_D)
        let fixtures = try Self.fixtures()
        var mismatches = 0
        var counts: [String: Int] = [:]
        for caseIndex in 0..<120 {
            var output = Self.randomOutput(&generator, maxFragments: 40)
            // Half the cases start the way the model starts: a header after the generation prompt.
            if Bool.random(using: &generator) {
                output = [" to=self<|message|>", " to=get_weather<|message|><atem:function_calls>\n",
                          " to=user<|message|>"].randomElement(using: &generator)! + output
            }
            let finish = Int.random(in: 0..<4, using: &generator) == 0 ? "length" : "stop"
            let label = "case \(caseIndex) \(finish) \(output.debugDescription)"
            for fixture in fixtures {
                let whole = await stream(fixture, [output], finish: finish, label: label)
                let kind = whole.refused.map { "refused \($0)" } ?? (whole.calls.isEmpty ? "text" : "calls")
                counts[kind, default: 0] += 1
                for size in [1, 7] {
                    let chunked = await stream(fixture, Self.characterChunks(output, size: size), finish: finish, label: label)
                    if chunked != whole {
                        mismatches += 1
                        Issue.record("\(label) [\(fixture.name)]: chunk \(size) \(chunked) vs whole \(whole)")
                    }
                }
            }
        }
        print("MUSE-FUZZ-OUTCOMES \(counts.sorted { $0.key < $1.key })")
        #expect(mismatches == 0)
    }

    @Test("hostile tool frames through every tool choice: never a provider failure")
    func hostileFramesThroughTheScheduler() async throws {
        let fixtures = try Self.fixtures()
        let header = " to=store<|message|><atem:function_calls>\n<atem:invoke name=\"store\">\n"
        var outputs: [(String, String)] = [
            ("deep array", header + "<atem:parameter name=\"payload\">" + Self.nested(100_000, object: false)
                + "</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"),
            ("deep object 200", header + "<atem:parameter name=\"payload\">" + Self.nested(200, object: true)
                + "</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"),
            ("deep object 512", header + "<atem:parameter name=\"payload\">" + Self.nested(512, object: true)
                + "</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"),
            ("deep list 200", header + "<atem:parameter name=\"list\">" + Self.nested(200, object: false)
                + "</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"),
            ("deep list 512", header + "<atem:parameter name=\"list\">" + Self.nested(512, object: false)
                + "</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"),
            ("deep list in a record", header + "<atem:parameter name=\"record\">{\"list\": \""
                + Self.nested(300, object: false) + "\"}</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"),
            ("deep note 513", header + "<atem:parameter name=\"note\">" + Self.nested(513, object: false)
                + "</atem:parameter>\n</atem:invoke>\n</atem:function_calls>"),
            ("unterminated invoke", header + "<atem:parameter name=\"payload\">" + String(repeating: "x", count: 50_000)),
            ("unterminated parameter", header + "<atem:parameter name=\"payload\">1</atem:invoke>"),
            ("stray closes", " to=get_weather<|message|>" + String(repeating: "</atem:invoke>", count: 2_000)),
            ("closing markup in a value", header + "<atem:parameter name=\"payload\">a</atem:invoke>b</atem:parameter>\n"
                + "</atem:invoke>\n</atem:function_calls>"),
            ("doubled header", " to=self to=get_weather<|message|><atem:function_calls>\n<atem:invoke name=\"get_weather\">"
                + "<atem:parameter name=\"city\">Paris</atem:parameter></atem:invoke></atem:function_calls>"),
            ("empty recipient", " to=<|message|><atem:invoke name=\"get_weather\"></atem:invoke>"),
            ("reasoning before the call, bare header", " to=self<|message|>I will call it to=get_weather<|message|>"
                + "<atem:function_calls><atem:invoke name=\"get_weather\"><atem:parameter name=\"city\">Paris"
                + "</atem:parameter></atem:invoke></atem:function_calls>"),
            ("preamble then call", " to=user<|message|>Let me check.<|eom|><|start|>assistant to=get_weather<|message|>"
                + "<atem:function_calls><atem:invoke name=\"get_weather\"><atem:parameter name=\"city\">Paris"
                + "</atem:parameter></atem:invoke></atem:function_calls>"),
            ("two calls", String(repeating: " to=get_weather<|message|><atem:function_calls><atem:invoke name=\"get_weather\">"
                + "<atem:parameter name=\"city\">Paris</atem:parameter></atem:invoke></atem:function_calls><|eom|>"
                + "<|start|>assistant", count: 2)),
            ("2000 invokes", " to=get_weather<|message|><atem:function_calls>" + String(repeating:
                "<atem:invoke name=\"get_weather\"><atem:parameter name=\"city\">P</atem:parameter></atem:invoke>", count: 2_000)
                + "</atem:function_calls>"),
            ("stray think tags", " to=self<|message|></think><think><tool_call>{}</tool_call><|eom|><|start|>assistant to=user"
                + "<|message|></think>Answer<tool_call>"),
        ]
        outputs.append(("random invalid UTF-8", String(decoding: (0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 131) },
                                                      as: UTF8.self)))
        for (name, output) in outputs {
            for fixture in fixtures {
                for finish in ["stop", "length"] {
                    let clock = ContinuousClock()
                    let start = clock.now
                    let outcome = await stream(fixture, Self.characterChunks(output, size: 16), finish: finish, label: name)
                    let elapsed = clock.now - start
                    #expect(elapsed < .seconds(120), "\(name) [\(fixture.name)] took \(elapsed)")
                    print("MUSE-FUZZ-HOSTILE \(name) [\(fixture.name)] \(finish): "
                          + (outcome.refused.map { "refused \($0)" } ?? "calls \(outcome.calls.count), content \(outcome.content.count) chars")
                          + " in \(elapsed)")
                }
            }
        }
    }
    #endif
}
