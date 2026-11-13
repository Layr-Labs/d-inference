// Copyright © 2026 Eigen Labs.
//
// Forced tool calls for GPT-OSS (Harmony): `tool_choice` "required" or a named
// function. The model reasons in its analysis channel as it does unforced;
// after that message the sampler admits only the Harmony call header of a
// declared function, then one JSON object of that function's compiled schema,
// then `<|call|>`. The stream's parser and validator check the call again
// before it is exposed (`ToolConstraintValidation`).

import Foundation
import MLXLMCommon

/// The process switch and the catalog build GPT-OSS forced calls are served for.
enum GPTOSSForcedToolCalls {
    /// An off word (`off`, `false`, `0`, `none`, `no` or `disabled`, in any
    /// case, surrounding space ignored) restores 0.10.12: forced choice is
    /// refused and the model is not advertised for it. Read once at launch.
    static let environmentKey = "DARKBLOOM_GPTOSS_FORCED_TOOLS"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    /// The catalog build advertised to the coordinator. Another GPT-OSS build
    /// still serves forced calls on the local API when its tokenizer verifies.
    static let catalogModelID = "gpt-oss-20b"
    static let modelType = "gpt_oss"

    static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    static func applies(to context: ChatTemplateFixContext, enabled: Bool = enabled) -> Bool {
        enabled && context.modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == modelType
    }

    static func advertises(_ model: ModelInfo, enabled: Bool = enabled) -> Bool {
        enabled && model.id == catalogModelID && model.modelType == modelType
    }
}

/// The Harmony control tokens and exact header sequences a forced call needs,
/// resolved from the loaded tokenizer and checked by round trip.
struct GPTOSSHarmonyFraming: Sendable {
    /// Where the rendered prompt leaves the model: a new assistant message.
    static let promptBoundary = "<|start|>assistant"
    static let analysisHeaderText = "<|channel|>analysis<|message|>"

    /// The call header Harmony gives a function (the served template's
    /// "Calls to these tools must go to the commentary channel").
    static func callHeaderText(_ name: String) -> String {
        "<|start|>assistant<|channel|>commentary to=functions.\(name) <|constrain|>json<|message|>"
    }

    let end: Int
    /// The first message after the prompt boundary.
    let analysisHeader: [Int]
    /// One per function name, in the order given.
    let callHeaders: [[Int]]

    init(tokenizer: any MLXLMCommon.Tokenizer, names: [String], firstAddedTokenID: Int) throws {
        func control(_ spelling: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(spelling), id >= firstAddedTokenID,
                  tokenizer.convertIdToToken(id) == spelling,
                  tokenizer.encode(text: spelling, addSpecialTokens: false) == [id],
                  tokenizer.decode(tokenIds: [id], skipSpecialTokens: false) == spelling else {
                throw ToolConstraintSchemaError.invalid("GPT-OSS vocabulary does not match the Harmony control tokens")
            }
            return id
        }
        let start = try control("<|start|>"), channel = try control("<|channel|>")
        let message = try control("<|message|>"), constrain = try control("<|constrain|>")
        end = try control("<|end|>")
        func header(_ text: String, opener: Int, controls: Set<Int>) throws -> [Int] {
            let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
            guard tokens.first == opener, tokens.last == message, tokens.filter({ $0 == message }).count == 1,
                  tokens.allSatisfy({ $0 < firstAddedTokenID || controls.contains($0) }),
                  tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == text else {
                throw ToolConstraintSchemaError.invalid("GPT-OSS tokenizer does not encode the Harmony headers exactly")
            }
            return tokens
        }
        analysisHeader = try header(Self.analysisHeaderText, opener: channel, controls: [channel, message])
        callHeaders = try names.map {
            try header(Self.callHeaderText($0), opener: start, controls: [start, channel, constrain, message])
        }
    }
}

/// Token automaton of one forced GPT-OSS response:
/// `<|channel|>analysis<|message|>` reasoning `<|end|>`, then a declared
/// function's call header, its arguments and `<|call|>`. Reasoning is free text
/// that never spells a Harmony control token; the analysis must end within the
/// output kept back for the call (`analysisReserve`) and once `analysisCap`
/// tokens are out. Arguments are delegated to a `JSONAnswerConstraint` of the
/// function's schema, which admits `<|call|>` only once the object is
/// complete. A call cut by the budget is never completed or repaired.
final class GPTOSSForcedToolConstraint: CBv2TokenConstraint, @unchecked Sendable {
    /// Arguments budget kept back while the model reasons.
    static let argumentsAllowance = 128
    /// Output after which the analysis ends whatever the budget, so a
    /// reasoning loop (the loop guard is off for constrained output) reaches
    /// the call instead of running to the context limit. The longest forced
    /// GPT-OSS response measured was 3,519 tokens.
    static let analysisCap = 16_384
    /// The arguments' delegate interns at most its own maximum; the analysis
    /// windows and header prefixes add a few hundred more.
    static let maximumStates = 2 * JSONAnswerConstraint.maximumStates
    private static let maximumTokenSets = 4

    private enum Phase: Hashable {
        case analysisHeader(Int)
        /// The suffix of the reasoning that still starts a Harmony spelling.
        case analysis(window: [UInt8])
        case callHeader(node: Int)
        case arguments(tool: Int, state: Int)
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
    /// Output kept back for `<|end|>`, the longest call header, the arguments
    /// allowance and `<|call|>`.
    let analysisReserve: Int
    private let framing: GPTOSSHarmonyFraming
    private let vocabulary: JSONAnswerVocabulary
    private let markers = JSONAnswerProfile.gptOSS.contentMarkers
    private let argumentConstraints: [JSONAnswerConstraint]
    private let callHeaderTrie: [CallHeaderNode]
    private let lock = NSLock()
    private var phases: [Phase] = [.analysisHeader(0)]
    private var phaseIndex: [Phase: Int] = [.analysisHeader(0): 0]
    private var analysisTokenSets: [(rejected: Set<Int>, tokens: [Int])] = []

    init(mode: ToolConstraintMode, tools: [CompiledToolSchema], tokenizer: any MLXLMCommon.Tokenizer,
         vocabulary: JSONAnswerVocabulary, maxTokens: Int) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS forced tool calls require a positive output budget")
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
            throw ToolConstraintSchemaError.invalid("GPT-OSS call framing requires required or named tool choice")
        }
        guard !selected.isEmpty, selected.count <= ToolConstraintSchemaCompiler.maxTools,
              selected.allSatisfy({ ToolChoicePromptPolicy.isValidFunctionName($0.name) }) else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS call framing requires valid declared function names")
        }
        let profile = JSONAnswerProfile.gptOSS
        framing = try GPTOSSHarmonyFraming(tokenizer: tokenizer, names: selected.map(\.name),
            firstAddedTokenID: profile.bpeIDs.upperBound)
        guard !vocabulary.stopTokenIDs.contains(framing.end) else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS analysis must not end the request")
        }
        argumentConstraints = try selected.map {
            try JSONAnswerConstraint(format: JSONAnswerFormat(arguments: $0, profile: profile), profile: profile,
                vocabulary: vocabulary, initialPhase: .answer, maxTokens: maxTokens)
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
        fallbackTokenID = vocabulary.fallbackTokenID
        analysisReserve = 1 + (framing.callHeaders.map(\.count).max() ?? 0) + Self.argumentsAllowance + 1
    }

    /// The constraint for a prepared forced request whose rendered prompt
    /// ends at the assistant boundary. Refusals are typed 400s.
    static func make(prepared: ToolChoicePromptPolicy.Prepared, tokenizer: TokenizerHandle, maxTokens: Int,
                     stopTokenIDs: Set<Int>, promptTokens: [Int]?) throws -> GPTOSSForcedToolConstraint {
        guard let promptTokens, !promptTokens.isEmpty,
              tokenizer.inner.decode(tokenIds: Array(promptTokens.suffix(32)), skipSpecialTokens: false)
                  .hasSuffix(GPTOSSHarmonyFraming.promptBoundary) else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "GPT-OSS forced tool calls require the rendered assistant boundary",
                refusal: .unsupportedForcedToolChoice)
        }
        guard let tools = prepared.compiledTools else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "required tool_choice schema was not compiled", refusal: .unsupportedForcedToolChoice)
        }
        do {
            let vocabulary = try JSONAnswerVocabulary.cached(for: tokenizer, profile: .gptOSS,
                stopTokenIDs: stopTokenIDs)
            return try GPTOSSForcedToolConstraint(mode: prepared.mode, tools: tools, tokenizer: tokenizer.inner,
                vocabulary: vocabulary, maxTokens: maxTokens)
        } catch let error as ToolConstraintSchemaError {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                error.localizedDescription, refusal: .unsupportedForcedToolChoice)
        }
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return [] }
        switch phases[state] {
        case .analysisHeader(let position):
            return [framing.analysisHeader[position]]
        case .analysis(let window):
            return analysisMustEnd(remainingTokens: remainingTokens) ? [framing.end] : analysisTokens(window)
        case .callHeader(let node):
            return callHeaderTrie[node].next.keys.sorted()
        case .arguments(let tool, let inner):
            return argumentConstraints[tool].allowedTokenIDs(state: inner, remainingTokens: remainingTokens)
        }
    }

    /// The allowed set depends on the budget only through `remainingTokens > 0`
    /// and, while reasoning, whether the analysis must end. Interned state ids
    /// are never reused.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return nil }
        if case .analysis = phases[state], analysisMustEnd(remainingTokens: remainingTokens) { return -1 }
        return state
    }

    /// Within the call's reserve, or once `analysisCap` tokens are out.
    private func analysisMustEnd(remainingTokens: Int) -> Bool {
        remainingTokens <= analysisReserve || maxTokens - remainingTokens >= Self.analysisCap
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens.
    var allowsChainedDecode: Bool { true }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard phases.indices.contains(state) else { return nil }
        let next: Phase
        switch phases[state] {
        case .analysisHeader(let position):
            guard tokenID == framing.analysisHeader[position] else { return nil }
            next = position + 1 < framing.analysisHeader.count ? .analysisHeader(position + 1) : .analysis(window: [])
        case .analysis(let window):
            if tokenID == framing.end {
                next = .callHeader(node: 0)
            } else {
                guard vocabulary.pieces.indices.contains(tokenID), !vocabulary.stopTokenIDs.contains(tokenID),
                      !vocabulary.pieces[tokenID].isEmpty,
                      let advanced = advance(window, vocabulary.pieces[tokenID]) else { return nil }
                next = .analysis(window: advanced)
            }
        case .callHeader(let node):
            guard let child = callHeaderTrie[node].next[tokenID] else { return nil }
            if let tool = callHeaderTrie[child].tool {
                next = .arguments(tool: tool, state: argumentConstraints[tool].initialState)
            } else {
                next = .callHeader(node: child)
            }
        case .arguments(let tool, let inner):
            guard let advanced = argumentConstraints[tool].nextState(state: inner, tokenID: tokenID) else { return nil }
            if advanced == -1 { return -1 }
            next = .arguments(tool: tool, state: advanced)
        }
        if let known = phaseIndex[next] { return known }
        guard phases.count < Self.maximumStates else { return nil }
        phases.append(next)
        phaseIndex[next] = phases.count - 1
        return phases.count - 1
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return phases.count }

    /// Reasoning pieces: every piece except one that would complete a Harmony
    /// spelling (only pieces holding a marker's final byte can), and `<|end|>`.
    private func analysisTokens(_ window: [UInt8]) -> [Int] {
        let rejected = Set(vocabulary.reasoningSensitive.filter { advance(window, vocabulary.pieces[$0]) == nil })
        if let index = analysisTokenSets.firstIndex(where: { $0.rejected == rejected }) {
            let entry = analysisTokenSets.remove(at: index)
            analysisTokenSets.append(entry)
            return entry.tokens
        }
        var tokens = rejected.isEmpty ? vocabulary.pieceTokenIDs
            : vocabulary.pieceTokenIDs.filter { !rejected.contains($0) }
        tokens.insert(framing.end, at: tokens.firstIndex { $0 > framing.end } ?? tokens.endIndex)
        if analysisTokenSets.count == Self.maximumTokenSets { analysisTokenSets.removeFirst() }
        analysisTokenSets.append((rejected, tokens))
        return tokens
    }

    /// The longest suffix of `window + piece` that still starts a Harmony
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
