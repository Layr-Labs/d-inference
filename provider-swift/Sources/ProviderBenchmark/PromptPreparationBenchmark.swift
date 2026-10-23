// Copyright © 2026 Eigen Labs.
//
// CPU-only prompt-preparation benchmark (`darkbloom benchmark --prompt-prep`).
// Times the production text path between the `prompt_prep_start` and
// `prompt_prep_end` profile stamps for synthetic chat and agent conversations:
// the unchanged tokenizer path, a cold prompt cache scope, the next turn of a
// conversation whose previous turn was served, and an exact repeat. Token IDs
// of every variant must equal the unchanged path's. It also times the body
// decode the admission path runs before acceptance.

import Foundation
import MLXLMCommon
import ProviderCore

public enum PromptPreparationBenchmark {
    public static func run(
        modelID: String, modelDirectory: URL, modelType: String?,
        lengths: [Int], iterations: Int
    ) async throws -> (json: String, identical: Bool) {
        // Serving re-tokenizes sampled prompts on the unchanged path in the
        // background; here that work would run beside the timed samples, and
        // every variant is compared with the unchanged path anyway.
        var environment = ProcessInfo.processInfo.environment
        environment[PromptTokenCachePolicy.verifyEnvironmentKey] = "0"
        let tokenizer = try await LocalTokenizerLoader(environment: environment).load(from: modelDirectory)
        var rows: [[String: Any]] = []
        var allIdentical = true
        for shape in [SyntheticConversation.Shape.chat, .agent, .loop] {
            for length in lengths {
                let conversation = SyntheticConversation(shape: shape, targetTokens: length)
                let body = try conversation.body(modelID: modelID, previousTurn: false)
                let current = try PromptPreparationProbe(body: body, modelType: modelType)
                let previous = try PromptPreparationProbe(
                    body: conversation.body(modelID: modelID, previousTurn: true), modelType: modelType)
                let reference = try current.promptTokens(tokenizer: tokenizer, promptCacheScope: nil)
                var uncached: [Double] = [], cold: [Double] = [], nextTurn: [Double] = [], repeated: [Double] = []
                var parse: [Double] = [], parseFields: [Double] = []
                let decodeAgrees = try PromptPreparationProbe.bodyDecodesAgree(body)
                var identical = true
                for _ in 0..<max(1, iterations) {
                    parse.append(try measure { try PromptPreparationProbe.decodeBody(body, merged: true) })
                    parseFields.append(try measure { try PromptPreparationProbe.decodeBody(body, merged: false) })
                    let (uncachedMs, uncachedTokens) = try measure {
                        try current.promptTokens(tokenizer: tokenizer, promptCacheScope: nil)
                    }
                    let (coldMs, coldTokens) = try measure {
                        try current.promptTokens(tokenizer: tokenizer, promptCacheScope: UUID().uuidString)
                    }
                    let scope = UUID().uuidString
                    _ = try previous.promptTokens(tokenizer: tokenizer, promptCacheScope: scope)
                    let (nextMs, nextTokens) = try measure {
                        try current.promptTokens(tokenizer: tokenizer, promptCacheScope: scope)
                    }
                    let (repeatMs, repeatTokens) = try measure {
                        try current.promptTokens(tokenizer: tokenizer, promptCacheScope: scope)
                    }
                    identical = identical && [uncachedTokens, coldTokens, nextTokens, repeatTokens]
                        .allSatisfy { $0 == reference }
                    uncached.append(uncachedMs)
                    cold.append(coldMs)
                    nextTurn.append(nextMs)
                    repeated.append(repeatMs)
                }
                allIdentical = allIdentical && identical && decodeAgrees
                rows.append([
                    "shape": shape.rawValue,
                    "target_tokens": length,
                    "prompt_tokens": reference.count,
                    "messages": conversation.messages.count,
                    "uncached_ms": median(uncached),
                    "cold_ms": median(cold),
                    "next_turn_ms": median(nextTurn),
                    "repeat_ms": median(repeated),
                    "parse_ms": median(parse),
                    "parse_fields_ms": median(parseFields),
                    "body_bytes": body.count,
                    "uncached_us_per_token": median(uncached) * 1000 / Double(max(1, reference.count)),
                    "identical_tokens": identical,
                    "identical_decode": decodeAgrees,
                ])
            }
        }
        let report: [String: Any] = [
            "model": modelID,
            "prompt_cache_active": PromptPreparationProbe.promptCacheIsActive(tokenizer),
            "prompt_cache_background_verification": PromptPreparationProbe.promptCacheVerifiesInBackground(tokenizer),
            "template_loop_rewrites": PromptPreparationProbe.templateLoopRewrites(tokenizer),
            "iterations": max(1, iterations),
            "active_processors": ProcessInfo.processInfo.activeProcessorCount,
            "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        return (String(decoding: data, as: UTF8.self), allIdentical)
    }

    private static func measure(_ body: () throws -> [Int]) rethrows -> (Double, [Int]) {
        let start = DispatchTime.now().uptimeNanoseconds
        let tokens = try body()
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, tokens)
    }

    private static func measure(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

/// Deterministic synthetic conversations: prose, code and JSON tool results,
/// with some non-ASCII text, sized by an approximate token target.
struct SyntheticConversation {
    enum Shape: String {
        case chat
        case agent
        /// An agent loop of short tool steps: many messages per token.
        case loop
    }

    let shape: Shape
    private(set) var messages: [[String: Any]] = []
    private var generator: TextGenerator

    init(shape: Shape, targetTokens: Int) {
        self.shape = shape
        let seedOffset: UInt64 = shape == .chat ? 0 : shape == .agent ? 1 : 2
        generator = TextGenerator(seed: UInt64(targetTokens) &* 2_654_435_761 &+ seedOffset)
        messages.append(["role": "system", "content": "You are a careful senior engineer. " + generator.prose(characters: 2400)])
        if shape == .loop {
            appendToolLoop(targetTokens: targetTokens)
            return
        }
        var characters = 0
        var turn = 0
        // About 3.6 characters per token across prose, code and JSON.
        while Double(characters) / 3.6 < Double(targetTokens) {
            let question = generator.prose(characters: 600) + "\n\n```swift\n" + generator.code(characters: 900) + "\n```"
            messages.append(["role": "user", "content": question])
            characters += question.count
            if shape == .agent {
                let id = "call_\(turn)"
                let arguments = "{\"path\": \"/workspace/Sources/Module\(turn)/File\(turn).swift\"}"
                messages.append(["role": "assistant", "content": "", "tool_calls": [[
                    "id": id, "type": "function",
                    "function": ["name": "read_file", "arguments": arguments],
                ]]])
                let result = generator.json(characters: 1800)
                messages.append(["role": "tool", "tool_call_id": id, "content": result])
                characters += result.count + arguments.count
            }
            let answer = generator.prose(characters: 900) + "\n\n" + generator.code(characters: 500)
            messages.append(["role": "assistant", "content": answer])
            characters += answer.count
            turn += 1
        }
        messages.append(["role": "user", "content": "Continue with the next step and summarize what changed."])
    }

    /// One task, then tool calls with short results; every sixth step the
    /// assistant reports and the user says to continue. Ends on a result.
    private mutating func appendToolLoop(targetTokens: Int) {
        messages.append(["role": "user", "content": generator.prose(characters: 400)])
        var characters = 2800
        var step = 0
        while Double(characters) / 3.6 < Double(targetTokens) {
            let id = "call_\(step)"
            let arguments = "{\"path\": \"/workspace/Sources/Module\(step % 7)/File\(step).swift\"}"
            messages.append(["role": "assistant", "content": "", "tool_calls": [[
                "id": id, "type": "function",
                "function": ["name": ["read_file", "search_code", "run_command"][step % 3], "arguments": arguments],
            ]]])
            let result = step % 2 == 0 ? generator.code(characters: 260) : generator.json(characters: 260)
            messages.append(["role": "tool", "tool_call_id": id, "content": result])
            characters += result.count + arguments.count + 40
            if step % 6 == 5 {
                let report = generator.prose(characters: 160)
                messages += [["role": "assistant", "content": report], ["role": "user", "content": "Continue."]]
                characters += report.count + 9
            }
            step += 1
        }
    }

    /// The previous turn ends at the user message before the final exchange
    /// (for a tool loop, before the last tool step).
    func body(modelID: String, previousTurn: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": modelID,
            "messages": previousTurn ? Array(messages.dropLast(2)) : messages,
            "max_tokens": 256,
            "stream": true,
        ]
        if shape != .chat { body["tools"] = Self.tools }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static var tools: [[String: Any]] {
        [
            "read_file", "write_file", "edit_file", "run_command", "search_code", "list_directory",
            "glob_files", "fetch_url", "run_tests", "git_diff", "todo_update", "ask_user",
        ].enumerated().map { index, name in
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": "Performs \(name.replacingOccurrences(of: "_", with: " ")) in the workspace sandbox "
                        + "and returns structured output. Paths are absolute; output is truncated past the limit. "
                        + String(repeating: "Respect the user's instructions and never modify unrelated files. ", count: 1 + index % 3),
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": "Absolute path of the target."],
                            "pattern": ["type": "string", "description": "Optional glob or regular expression."],
                            "limit": ["type": "integer", "description": "Maximum number of results."],
                        ],
                        "required": ["path"],
                    ],
                ],
            ]
        }
    }
}

private struct TextGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed | 1
    }

    private static let words = """
        the a of to and in is that for it as with be on not this by are from or at which an have \
        engine request token prompt cache model memory batch decode prefill latency throughput kernel \
        buffer scheduler stream provider coordinator attention layer matrix vector quantized expert \
        router chunk window history session tenant scope checkpoint restore budget deadline admission \
        however because therefore although meanwhile instead finally second third measured expected \
        resulting performance correctness function variable parameter returns throws async await \
        configuration environment default override fallback threshold capacity priority ordering \
        café naïve résumé Zürich 東京 데이터 données über straße 🙂 —
        """.split(separator: " ").map(String.init)

    private static let identifiers = [
        "engine", "request", "tokens", "promptCache", "scheduler", "budget", "index", "count", "result",
        "configuration", "deadline", "chunkSize", "layer", "batch", "stream", "scope", "pieces", "offset",
    ]

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }

    mutating func prose(characters: Int) -> String {
        var text = ""
        var sentence = 0
        while text.count < characters {
            let word = Self.words[next(Self.words.count)]
            text += sentence == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
            sentence += 1
            if sentence > 6 && next(5) == 0 {
                text += [". ", "? ", ", and ", "; ", ".\n"][next(5)]
                sentence = text.hasSuffix(", and ") || text.hasSuffix("; ") ? 1 : 0
            } else {
                text += " "
            }
        }
        return text
    }

    mutating func code(characters: Int) -> String {
        var text = ""
        var depth = 0
        while text.count < characters {
            let name = Self.identifiers[next(Self.identifiers.count)]
            let other = Self.identifiers[next(Self.identifiers.count)]
            let indent = String(repeating: "    ", count: depth)
            switch next(6) {
            case 0:
                text += "\(indent)func \(name)(_ \(other): Int) -> [Int] {\n"
                depth = min(depth + 1, 3)
            case 1:
                text += "\(indent)let \(name) = \(other).map { $0 * \(next(97)) + \(next(13)) }\n"
            case 2:
                text += "\(indent)if \(name) > \(next(4096)) { return [\(other)] }\n"
            case 3:
                text += "\(indent)// \(prose(characters: 40))\n"
            case 4 where depth > 0:
                depth -= 1
                text += String(repeating: "    ", count: depth) + "}\n"
            default:
                text += "\(indent)\(name)[\(next(64))] += \(other).count // \(next(1000))\n"
            }
        }
        return text
    }

    mutating func json(characters: Int) -> String {
        var entries: [String] = []
        var length = 0
        while length < characters {
            let entry = "{\"id\": \(next(100_000)), \"name\": \"\(Self.identifiers[next(Self.identifiers.count)])\", "
                + "\"value\": \(Double(next(1_000_000)) / 1000), \"ok\": \(next(2) == 0), "
                + "\"note\": \"\(prose(characters: 50).replacingOccurrences(of: "\n", with: " "))\"}"
            entries.append(entry)
            length += entry.count
        }
        return "[" + entries.joined(separator: ",\n ") + "]"
    }
}
