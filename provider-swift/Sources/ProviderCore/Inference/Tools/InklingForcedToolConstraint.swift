// Copyright © 2026 Eigen Labs.
//
// Forced tool calls for Inkling 2 (`inkling2_loop`): `tool_choice` "required"
// or a named function. Inkling's template has no tool-choice control, so the
// sampler frames the call: the model may think first, as it does unforced;
// then it may only open a call message of a declared function, write one JSON
// body `{"name": NAME, "args": {...}}` of that function's compiled schema and
// close the message. Its channel lexer and the shared validator check every
// call again before it is exposed (`Inkling2OutputChannels`).

import Foundation
import MLXLMCommon

/// The process switch for Inkling 2's sampler-framed forced calls.
enum InklingForcedToolCalls {
    /// An off word (`off`, `false`, `0`, `none`, `no` or `disabled`, in any
    /// case, surrounding space ignored) restores 0.10.18: required and named
    /// calls are forced by the prompt alone and a text answer is refused after
    /// generation. Read once at launch.
    static let environmentKey = "DARKBLOOM_INKLING_FORCED_TOOLS"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    static func applies(modelType: String?, enabled: Bool = enabled) -> Bool {
        enabled && Inkling2PromptContract.applies(modelType: modelType)
    }
}

/// Inkling 2's message tokens and the spelling of each declared function
/// name, resolved from the loaded tokenizer and checked by round trip.
struct InklingCallFraming: Sendable {
    static let messageModelText = "<|message_model|>"
    static let endMessageText = "<|end_message|>"

    let messageModel: Int
    let contentThinking: Int
    let endMessage: Int
    let invokeToolJSON: Int
    let endOfSampling: Int
    /// One per function name, in the order given: the name's pieces, then
    /// `<|content_invoke_tool_json|>`.
    let callHeaders: [[Int]]

    init(tokenizer: any MLXLMCommon.Tokenizer, names: [String], firstAddedTokenID: Int) throws {
        func control(_ spelling: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(spelling), id >= firstAddedTokenID,
                  tokenizer.convertIdToToken(id) == spelling,
                  tokenizer.encode(text: spelling, addSpecialTokens: false) == [id],
                  tokenizer.decode(tokenIds: [id], skipSpecialTokens: false) == spelling else {
                throw ToolConstraintSchemaError.invalid("Inkling vocabulary does not match its message tokens")
            }
            return id
        }
        messageModel = try control(Self.messageModelText)
        contentThinking = try control("<|content_thinking|>")
        endMessage = try control(Self.endMessageText)
        invokeToolJSON = try control("<|content_invoke_tool_json|>")
        endOfSampling = try control("<|content_model_end_sampling|>")
        callHeaders = try names.map { name in
            let tokens = tokenizer.encode(text: name, addSpecialTokens: false)
            guard !tokens.isEmpty, tokens.allSatisfy({ $0 < firstAddedTokenID }),
                  tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == name else {
                throw ToolConstraintSchemaError.invalid("Inkling tokenizer does not encode a function name exactly")
            }
            return tokens + [try control("<|content_invoke_tool_json|>")]
        }
    }
}

/// Token automaton of one forced Inkling 2 response. From the prompt's end:
/// `<|message_model|>`, then either a thought (`<|content_thinking|>` free text
/// `<|end_message|>`, at most one, before any call) or a declared function's
/// name and `<|content_invoke_tool_json|>`; the call body is delegated to a
/// `JSONAnswerConstraint` of `{"name": NAME, "args": <the function's compiled
/// schema>}` that admits `<|end_message|>` only once the object is complete.
/// After a call: another call when parallel calls are allowed, or
/// `<|content_model_end_sampling|>`. No answer text (`<|content_text|>`), tool
/// error or text call can be opened. The thought ends within the output kept
/// back for the call (`thoughtReserve`) and once `thoughtCap` tokens are out.
/// A call cut by the budget is never completed or repaired.
final class InklingForcedToolConstraint: CBv2TokenConstraint, @unchecked Sendable {
    /// Arguments budget kept back while the model thinks.
    static let argumentsAllowance = 128
    /// Output after which the thought ends whatever the budget, so a thinking
    /// loop (the loop guard is off for constrained output) reaches the call.
    static let thoughtCap = 16_384
    /// Calls one response may make when parallel calls are allowed.
    static let maximumCalls = 16
    static let maximumStates = 2 * JSONAnswerConstraint.maximumStates
    private static let maximumTokenSets = 4

    private enum Phase: Hashable {
        /// Between messages: `calls` made so far, and whether the thought is over.
        case boundary(calls: Int, thought: Bool)
        /// After `<|message_model|>`: a call name, or the thought when allowed.
        case header(calls: Int, thought: Bool)
        /// The suffix of the thought that still starts a message spelling.
        case thought(window: [UInt8])
        case callHeader(calls: Int, node: Int)
        case arguments(calls: Int, tool: Int, state: Int)
    }

    private struct CallHeaderNode {
        var next: [Int: Int] = [:]
        /// Set where a declared function's whole header ends.
        var tool: Int?
    }

    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let allowsParallel: Bool
    /// Output kept back for `<|end_message|>`, the next `<|message_model|>`,
    /// the longest call header, the arguments allowance, the call's
    /// `<|end_message|>` and the end of sampling.
    let thoughtReserve: Int
    /// Output a further call needs before it may open.
    let callReserve: Int
    private let framing: InklingCallFraming
    private let vocabulary: JSONAnswerVocabulary
    private let markers = JSONAnswerProfile.inkling2Arguments.contentMarkers
    private let argumentConstraints: [JSONAnswerConstraint]
    private let callHeaderTrie: [CallHeaderNode]
    private let lock = NSLock()
    private var phases: [Phase]
    private var phaseIndex: [Phase: Int]
    private var thoughtTokenSets: [(rejected: Set<Int>, tokens: [Int])] = []

    /// `opensInMessage`: the rendered prompt already ends with
    /// `<|message_model|>`, so output starts at the message's header.
    init(mode: ToolConstraintMode, tools: [CompiledToolSchema], allowsParallel: Bool,
         tokenizer: any MLXLMCommon.Tokenizer, vocabulary: JSONAnswerVocabulary, maxTokens: Int,
         opensInMessage: Bool = false) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("Inkling forced tool calls require a positive output budget")
        }
        let selected: [CompiledToolSchema]
        switch mode {
        case .required:
            self.mode = .required
            selected = tools
        case .named(let name):
            self.mode = .named
            selected = tools.filter { $0.name == name }
        case .none, .auto:
            throw ToolConstraintSchemaError.invalid("Inkling call framing requires required or named tool choice")
        }
        guard !selected.isEmpty, selected.count <= ToolConstraintSchemaCompiler.maxTools,
              selected.allSatisfy({ ToolChoicePromptPolicy.isValidFunctionName($0.name) }) else {
            throw ToolConstraintSchemaError.invalid("Inkling call framing requires valid declared function names")
        }
        let profile = JSONAnswerProfile.inkling2Arguments
        framing = try InklingCallFraming(tokenizer: tokenizer, names: selected.map(\.name),
            firstAddedTokenID: profile.bpeIDs.upperBound)
        guard vocabulary.stopTokenIDs.contains(framing.endOfSampling),
              vocabulary.answerEOS == [framing.endMessage] else {
            throw ToolConstraintSchemaError.invalid("Inkling forced calls require its end of sampling as a stop token")
        }
        argumentConstraints = try selected.map { tool in
            let body = CompiledToolSchema(name: tool.name, parameters: .object(properties: [
                .init(name: "name", schema: .string(values: [tool.name], nullable: false), required: true),
                .init(name: "args", schema: tool.parameters, required: true),
            ], allowsAdditional: false, nullable: false))
            return try JSONAnswerConstraint(format: JSONAnswerFormat(arguments: body, profile: profile),
                profile: profile, vocabulary: vocabulary, initialPhase: .answer, maxTokens: maxTokens)
        }
        var trie = [CallHeaderNode()]
        for (tool, tokens) in framing.callHeaders.enumerated() {
            var node = 0
            for token in tokens {
                if let child = trie[node].next[token] {
                    node = child
                } else {
                    trie.append(CallHeaderNode())
                    trie[node].next[token] = trie.count - 1
                    node = trie.count - 1
                }
            }
            trie[node].tool = tool
        }
        callHeaderTrie = trie
        self.vocabulary = vocabulary
        self.maxTokens = maxTokens
        self.allowsParallel = allowsParallel
        fallbackTokenID = framing.endOfSampling
        let longestHeader = framing.callHeaders.map(\.count).max() ?? 0
        callReserve = 1 + longestHeader + Self.argumentsAllowance + 1 + 1
        thoughtReserve = 1 + callReserve
        let initial: Phase = opensInMessage ? .header(calls: 0, thought: false) : .boundary(calls: 0, thought: false)
        phases = [initial]
        phaseIndex = [initial: 0]
    }

    /// The constraint for a prepared forced request whose rendered prompt ends
    /// between messages (`<|end_message|>`) or at an open model message
    /// (`<|message_model|>`). Refusals are typed 400s.
    static func make(prepared: ToolChoicePromptPolicy.Prepared, tokenizer: TokenizerHandle, maxTokens: Int,
                     stopTokenIDs: Set<Int>, promptTokens: [Int]?) throws -> InklingForcedToolConstraint {
        let tail = promptTokens.map { tokenizer.inner.decode(tokenIds: Array($0.suffix(8)), skipSpecialTokens: false) }
        guard let tail, tail.hasSuffix(InklingCallFraming.endMessageText)
                || tail.hasSuffix(InklingCallFraming.messageModelText) else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "Inkling forced tool calls require the rendered message boundary",
                refusal: .unsupportedForcedToolChoice)
        }
        guard let tools = prepared.compiledTools else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "required tool_choice schema was not compiled", refusal: .unsupportedForcedToolChoice)
        }
        do {
            let profile = JSONAnswerProfile.inkling2Arguments
            // The call body ends at `<|end_message|>`, which never ends the
            // request: only the body's delegate reads it as its terminator.
            let vocabulary = try JSONAnswerVocabulary.cached(for: tokenizer, profile: profile,
                stopTokenIDs: stopTokenIDs.union(profile.answerEOS.map(\.id)))
            return try InklingForcedToolConstraint(mode: prepared.mode, tools: tools,
                allowsParallel: prepared.allowsParallelCalls, tokenizer: tokenizer.inner, vocabulary: vocabulary,
                maxTokens: maxTokens, opensInMessage: tail.hasSuffix(InklingCallFraming.messageModelText))
        } catch let error as ToolConstraintSchemaError {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                error.localizedDescription, refusal: .unsupportedForcedToolChoice)
        }
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return [] }
        switch phases[state] {
        case .boundary(let calls, _):
            guard calls > 0 else { return [framing.messageModel] }
            return opensAnotherCall(calls: calls, remainingTokens: remainingTokens)
                ? [framing.endOfSampling, framing.messageModel].sorted() : [framing.endOfSampling]
        case .header(let calls, let thought):
            var allowed = callHeaderTrie[0].next.keys.sorted()
            if calls == 0, !thought, remainingTokens > thoughtReserve {
                allowed = (allowed + [framing.contentThinking]).sorted()
            }
            return allowed
        case .thought(let window):
            return thoughtMustEnd(remainingTokens: remainingTokens) ? [framing.endMessage] : thoughtTokens(window)
        case .callHeader(_, let node):
            return callHeaderTrie[node].next.keys.sorted()
        case .arguments(_, let tool, let inner):
            return argumentConstraints[tool].allowedTokenIDs(state: inner, remainingTokens: remainingTokens)
        }
    }

    /// The thought's and the call header's sets depend on the budget only
    /// through `remainingTokens > 0` and whether the thought must end; the
    /// message boundary and header (a few ids) are recomputed. Interned state
    /// ids are never reused.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return nil }
        switch phases[state] {
        case .boundary, .header:
            return nil
        case .thought:
            return thoughtMustEnd(remainingTokens: remainingTokens) ? -1 : state
        case .callHeader, .arguments:
            return state
        }
    }

    private func thoughtMustEnd(remainingTokens: Int) -> Bool {
        remainingTokens <= thoughtReserve || maxTokens - remainingTokens >= Self.thoughtCap
    }

    private func opensAnotherCall(calls: Int, remainingTokens: Int) -> Bool {
        allowsParallel && calls < Self.maximumCalls && remainingTokens > callReserve
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens.
    var allowsChainedDecode: Bool { true }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard phases.indices.contains(state) else { return nil }
        let next: Phase
        switch phases[state] {
        case .boundary(let calls, let thought):
            if calls > 0, tokenID == framing.endOfSampling { return -1 }
            guard tokenID == framing.messageModel, calls == 0 || allowsParallel, calls < Self.maximumCalls else {
                return nil
            }
            next = .header(calls: calls, thought: thought)
        case .header(let calls, let thought):
            if tokenID == framing.contentThinking {
                guard calls == 0, !thought else { return nil }
                next = .thought(window: [])
            } else {
                guard let child = callHeaderTrie[0].next[tokenID] else { return nil }
                next = callHeaderPhase(calls: calls, node: child)
            }
        case .thought(let window):
            if tokenID == framing.endMessage {
                next = .boundary(calls: 0, thought: true)
            } else {
                guard vocabulary.pieces.indices.contains(tokenID), !vocabulary.stopTokenIDs.contains(tokenID),
                      !vocabulary.pieces[tokenID].isEmpty,
                      let advanced = advance(window, vocabulary.pieces[tokenID]) else { return nil }
                next = .thought(window: advanced)
            }
        case .callHeader(let calls, let node):
            guard let child = callHeaderTrie[node].next[tokenID] else { return nil }
            next = callHeaderPhase(calls: calls, node: child)
        case .arguments(let calls, let tool, let inner):
            guard let advanced = argumentConstraints[tool].nextState(state: inner, tokenID: tokenID) else {
                return nil
            }
            if advanced == -1 {
                // The delegate's only terminator is `<|end_message|>`.
                guard tokenID == framing.endMessage else { return nil }
                next = .boundary(calls: calls + 1, thought: true)
            } else {
                next = .arguments(calls: calls, tool: tool, state: advanced)
            }
        }
        if let known = phaseIndex[next] { return known }
        guard phases.count < Self.maximumStates else { return nil }
        phases.append(next)
        phaseIndex[next] = phases.count - 1
        return phases.count - 1
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return phases.count }

    private func callHeaderPhase(calls: Int, node: Int) -> Phase {
        if let tool = callHeaderTrie[node].tool {
            return .arguments(calls: calls, tool: tool, state: argumentConstraints[tool].initialState)
        }
        return .callHeader(calls: calls, node: node)
    }

    /// Thought pieces: every piece except one that would complete a message
    /// spelling (only pieces holding a marker's final byte can), and
    /// `<|end_message|>`.
    private func thoughtTokens(_ window: [UInt8]) -> [Int] {
        let rejected = Set(vocabulary.reasoningSensitive.filter { advance(window, vocabulary.pieces[$0]) == nil })
        if let index = thoughtTokenSets.firstIndex(where: { $0.rejected == rejected }) {
            let entry = thoughtTokenSets.remove(at: index)
            thoughtTokenSets.append(entry)
            return entry.tokens
        }
        var tokens = rejected.isEmpty ? vocabulary.pieceTokenIDs
            : vocabulary.pieceTokenIDs.filter { !rejected.contains($0) }
        tokens.insert(framing.endMessage, at: tokens.firstIndex { $0 > framing.endMessage } ?? tokens.endIndex)
        if thoughtTokenSets.count == Self.maximumTokenSets { thoughtTokenSets.removeFirst() }
        thoughtTokenSets.append((rejected, tokens))
        return tokens
    }

    /// The longest suffix of `window + piece` that still starts a message
    /// spelling, or nil when the piece completes one.
    private func advance(_ window: [UInt8], _ piece: [UInt8]) -> [UInt8]? {
        var window = window
        for byte in piece {
            window.append(byte)
            while !window.isEmpty && !markers.contains(where: { $0.starts(with: window) }) {
                window.removeFirst()
            }
            if markers.contains(where: { $0.count <= window.count && window.suffix($0.count).elementsEqual($0) }) {
                return nil
            }
        }
        return window
    }
}
