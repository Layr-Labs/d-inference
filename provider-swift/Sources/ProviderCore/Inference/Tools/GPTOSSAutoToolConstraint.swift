// Copyright © 2026 Eigen Labs.
//
// GPT-OSS (Harmony) calls under `tool_choice` "auto": once a message header's
// recipient reaches ` to=functions.`, the sampler admits only a declared
// function's name, then the rest of that header, then one JSON object of the
// function's compiled schema and `<|call|>`. Reasoning, commentary
// preambles, final answers and every other header are sampled as without the
// grammar (their masks admit every id), so the model still decides whether
// to call. The stream's parser and validator read the call as before.

import Foundation
import MLXLMCommon
import MLXLMServer

/// The process switch and the admission of GPT-OSS `auto` requests to
/// `GPTOSSAutoToolConstraint`.
enum GPTOSSAutoToolGrammar {
    static let redControlKeepsHints = true

    /// An off word (`off`, `false`, `0`, `none`, `no` or `disabled`, any case,
    /// surrounding space ignored) restores unconstrained `auto` calls. Read
    /// once at launch. Not `DARKBLOOM_GPTOSS_`: that prefix is part of the SSD
    /// prefix cache's checkpoint identity, so flipping this switch would start
    /// a fresh cache for every model.
    static let environmentKey = "DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])
    /// An off word (as `environmentKey`) keeps free arguments for every
    /// function whose schema is outside the compiled subset as written, as
    /// before `widenedArguments`. Read once at launch.
    static let widenEnvironmentKey = "DARKBLOOM_HARMONY_AUTO_TOOL_WIDEN"
    static let widens = isEnabled(ProcessInfo.processInfo.environment[widenEnvironmentKey])

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "harmony-auto-tool-grammar")

    static func isEnabled(_ value: String?) -> Bool {
        GPTOSSForcedToolCalls.isEnabled(value)
    }

    /// Cheap pre-check: an `auto` GPT-OSS request that declares tools.
    static func isCandidate(prepared: ToolChoicePromptPolicy.Prepared, modelType: String?,
                            enabled: Bool = enabled) -> Bool {
        enabled && modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == GPTOSSForcedToolCalls.modelType && prepared.mode == .auto && prepared.tools?.isEmpty == false
    }

    /// The constraint for an eligible request, or nil (calls as generated, as
    /// before). `runsTokenConstraints`: the slot's engine samples under one
    /// (not a cluster pair, not a native-tracked engine). `logitsWidth`: the
    /// model's (`EngineV2Bridge.logitsWidth`); a free mask admits every id of
    /// the vocabulary, so the grammar runs only when the two are equal.
    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        tokenizer: TokenizerHandle,
        maxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        runsTokenConstraints: Bool,
        logitsWidth: Int? = nil,
        enabled: Bool = enabled
    ) -> GPTOSSAutoToolConstraint? {
        guard isCandidate(prepared: prepared, modelType: modelType, enabled: enabled),
              let tools = prepared.tools else { return nil }
        guard runsTokenConstraints else { return declined("the engine does not run token constraints") }
        guard let promptTokens, !promptTokens.isEmpty,
              tokenizer.inner.decode(tokenIds: Array(promptTokens.suffix(32)), skipSpecialTokens: false)
                  .hasSuffix(GPTOSSHarmonyFraming.promptBoundary) else {
            return declined("unrecognized prompt boundary")
        }
        let vocabulary: JSONAnswerVocabulary
        let framing: GPTOSSHarmonyFraming
        do {
            vocabulary = try JSONAnswerVocabulary.cached(for: tokenizer, profile: .gptOSS, stopTokenIDs: stopTokenIDs)
            framing = try GPTOSSHarmonyFraming(tokenizer: tokenizer.inner, names: [],
                firstAddedTokenID: JSONAnswerProfile.gptOSS.bpeIDs.upperBound)
        } catch {
            return declined("tokenizer does not match the Harmony contract")
        }
        guard logitsWidth == vocabulary.pieces.count else {
            // A wiring change that loses the width turns the grammar off everywhere: say so loudly.
            logger.warning("GPT-OSS auto tool calls served unconstrained: the model's logits width does not match the vocabulary")
            return nil
        }
        let arguments = compiledArguments(declared: prepared.declaredTools ?? tools, rendered: tools)
        guard let constraint = try? GPTOSSAutoToolConstraint(names: tools.map(\.function.name), arguments: arguments,
            framing: framing, vocabulary: vocabulary, maxTokens: maxTokens) else {
            return declined("no positive output budget or no valid function name")
        }
        return constraint
    }

    /// Each rendered tool's arguments schema, compiled from its declaration
    /// with local `$ref`s inlined (`ToolSchemaRefResolution`, bounded), or nil
    /// where that tool's arguments stay as generated, while its name is still
    /// constrained: a schema outside the compiled subset even once widened
    /// (`widenedArguments`), or a rendered schema (what the prompt shows) that
    /// still holds a `$ref`. The legacy repair types such a reference as a
    /// string (`string[]` in the prompt), so holding the arguments to the
    /// referenced object would contradict the prompt. Once the coordinator or
    /// the local API inlines the references, the rendered schema holds none
    /// and the arguments are constrained.
    static func compiledArguments(declared: [OpenAITool], rendered: [OpenAITool],
                                  widens: Bool = widens) -> [CompiledToolSchema?] {
        let byName = Dictionary(declared.map { ($0.function.name, $0) }, uniquingKeysWith: { first, _ in first })
        return rendered.map { tool in
            guard let declaration = byName[tool.function.name], !holdsReference(tool) else { return nil }
            let resolved = withoutRenderHintTypes(resolvingRefs(declaration))
            if let exact = try? ToolConstraintSchemaCompiler.compile(tools: [resolved], mode: .auto).first {
                return exact
            }
            return widens ? widenedArguments(resolved) : nil
        }
    }

    /// The declaration with each `type` that only names a render hint
    /// removed: the type the ingress repair writes beside a union naming one
    /// of its branches, a mixed `enum`, a `not` of that type or an
    /// `if`/`then`/`else` typed otherwise
    /// (`QwenParserLiteralReading.rendersSiblingType`, the rule the call
    /// parser and the strict check already read). Compiled as a hard type it
    /// held a union's arguments to its first branch (`"-4200"` for `-4200`).
    /// Every other node, and a declaration without such a type, is returned
    /// unchanged.
    static func withoutRenderHintTypes(_ tool: OpenAITool) -> OpenAITool {
        guard !redControlKeepsHints, let parameters = tool.function.parameters else { return tool }
        let unhinted = withoutRenderHintTypes(parameters, depth: 0)
        guard unhinted != parameters else { return tool }
        var copy = tool
        copy.function.parameters = unhinted
        return copy
    }

    private static func withoutRenderHintTypes(_ schema: MLXLMCommon.JSONValue, depth: Int) -> MLXLMCommon.JSONValue {
        guard depth <= ToolConstraintSchemaCompiler.maxDepth, case .object(var object) = schema else { return schema }
        if QwenParserLiteralReading.rendersSiblingType(object) {
            object.removeValue(forKey: "type")
        }
        for key in ["anyOf", "oneOf", "allOf", "prefixItems"] {
            guard case .array(let branches)? = object[key] else { continue }
            object[key] = .array(branches.map { withoutRenderHintTypes($0, depth: depth + 1) })
        }
        for key in ["properties", "patternProperties", "$defs", "definitions"] {
            guard case .object(let entries)? = object[key] else { continue }
            object[key] = .object(entries.mapValues { withoutRenderHintTypes($0, depth: depth + 1) })
        }
        for key in ["items", "additionalProperties", "not", "if", "then", "else"] {
            guard case .object? = object[key] else { continue }
            object[key] = withoutRenderHintTypes(object[key]!, depth: depth + 1)
        }
        return .object(object)
    }

    /// A schema outside the subset as written, in the shapes agent clients
    /// send every day (Pydantic's `anyOf` with `null`, zod's root `$schema`,
    /// `minimum`, `format`, …): compiled through `ResponseSchemaRewrite`
    /// exactly, else without its value assertions, after
    /// `withoutUnionRepair`. The grammar then holds the structure, types,
    /// enums and required keys, and leaves a value assertion it cannot spell
    /// to the model; these arguments were as generated before. Every node of
    /// the rewritten schema must state what it accepts
    /// (`requireExplicitResponseTypes`): the compiler reads an untyped node as
    /// a string, which would refuse values the declaration accepts (`{}` in
    /// `Optional[Any]`, a `minimum` the rewrite dropped from an untyped node).
    /// Nil when the rewrite, that check or the compiler refuses (a wider
    /// `anyOf`, an allow-all `{}`, …): the arguments stay as generated.
    static func widenedArguments(_ tool: OpenAITool) -> CompiledToolSchema? {
        guard let parameters = tool.function.parameters else { return nil }
        let unrepaired = withoutUnionRepair(parameters, depth: 0, unwraps: 0)
        for relaxing in [false, true] {
            guard let rewritten = ResponseSchemaRewrite.subset(unrepaired, relaxingAssertions: relaxing) else { continue }
            var candidate = tool
            candidate.function.parameters = rewritten
            if let compiled = try? ToolConstraintSchemaCompiler.compile(tools: [candidate], mode: .auto).first,
               (try? ToolConstraintSchemaCompiler.requireExplicitResponseTypes(rewritten, path: "parameters")) != nil {
                return compiled
            }
        }
        return nil
    }

    /// Ingress normalization (the coordinator's and `ToolSchemaNormalization`)
    /// writes a render type beside a nullable union: `type` (the first other
    /// branch's), `nullable`, and for an object an empty `properties`. The
    /// caller's schema holds only the union, which is what a client checks
    /// the arguments against. Where the other branch states its own type or
    /// values (`type`, `enum` or `const`), dropping those three keys lets
    /// `ResponseSchemaRewrite` read the union as written, and only widens what
    /// the node admits; otherwise (`properties` or `items` alone assert no
    /// type) the node is kept, and the rewrite refuses it. `depth` counts
    /// levels as the compiler does (`properties`, `items`; a `$defs` or
    /// `definitions` entry one deeper); `unwraps` the unions and compositions
    /// entered in a row, bounded as the rewrite bounds them.
    static func withoutUnionRepair(_ schema: MLXLMCommon.JSONValue, depth: Int, unwraps: Int) -> MLXLMCommon.JSONValue {
        guard depth <= ToolConstraintSchemaCompiler.maxDepth, unwraps <= ResponseSchemaRewrite.maximumUnwraps,
              case .object(var object) = schema else { return schema }
        if case .array(let branches)? = object["anyOf"], branches.count == 2, branches.contains(where: isNullBranch),
           branches.contains(where: { !isNullBranch($0) && statesItsType($0) }) {
            object.removeValue(forKey: "type")
            object.removeValue(forKey: "nullable")
            if object["properties"] == .object([:]) { object.removeValue(forKey: "properties") }
        }
        for composition in ["anyOf", "allOf"] {
            guard case .array(let branches)? = object[composition] else { continue }
            object[composition] = .array(branches.map { withoutUnionRepair($0, depth: depth, unwraps: unwraps + 1) })
        }
        for container in ["properties", "$defs", "definitions"] {
            guard case .object(let entries)? = object[container] else { continue }
            object[container] = .object(entries.mapValues { withoutUnionRepair($0, depth: depth + 1, unwraps: 0) })
        }
        if let items = object["items"] { object["items"] = withoutUnionRepair(items, depth: depth + 1, unwraps: 0) }
        return .object(object)
    }

    private static func isNullBranch(_ branch: MLXLMCommon.JSONValue) -> Bool {
        guard case .object(let object) = branch else { return false }
        return object["type"] == .string("null")
    }

    private static func statesItsType(_ branch: MLXLMCommon.JSONValue) -> Bool {
        guard case .object(let object) = branch else { return false }
        if let type = object["type"], type != .null { return true }
        return object["enum"] != nil || object["const"] != nil
    }

    /// Whether the tool's encoded form spells a `"$ref"` (a key; a string
    /// value of that spelling also counts, which only leaves arguments free).
    static func holdsReference(_ tool: OpenAITool) -> Bool {
        guard let data = try? JSONEncoder().encode(tool) else { return true }
        return data.range(of: Data("\"$ref\"".utf8)) != nil
    }

    /// The declaration with its local `$ref`s inlined where the bounds allow;
    /// itself when it has none or does not round-trip.
    static func resolvingRefs(_ tool: OpenAITool) -> OpenAITool {
        guard let data = try? JSONEncoder().encode(tool), data.range(of: Data("\"$ref\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) else { return tool }
        var tools: [Any] = [object]
        guard ToolSchemaRefResolution.resolve(&tools, mode: .inline).inlined > 0,
              let resolved = try? JSONSerialization.data(withJSONObject: tools[0]),
              let decoded = try? JSONDecoder().decode(OpenAITool.self, from: resolved) else { return tool }
        return decoded
    }

    /// Fixed reasons only: never names, schemas, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> GPTOSSAutoToolConstraint? {
        logger.info("GPT-OSS auto tool calls served unconstrained: \(reason)")
        return nil
    }
}

/// Token automaton of a GPT-OSS `auto` response. Message bodies and headers
/// are free spans: every id is admitted, and only the header bytes are
/// watched for ` to=functions.`. From there the call is constrained:
///
/// ```
/// <|start|>assistant to=functions.NAME<|channel|>commentary json<|message|>{…}<|call|>
/// <|start|>assistant<|channel|>commentary to=functions.NAME <|constrain|>json<|message|>{…}<|call|>
/// ```
///
/// NAME follows a byte trie over the declared names and ends where
/// `HarmonyToolCallParser` ends it (a space, `<|constrain|>`, `<|message|>`,
/// or `<|channel|>` then `commentary`); the rest of the header spells no
/// Harmony marker; after `<|message|>` the arguments are a
/// `JSONAnswerConstraint` of the function's schema, which admits `<|call|>`
/// only once the object is complete. A function whose schema did not compile
/// keeps free arguments. Never forces a call, closes one, or repairs one the
/// budget cut. Should the header, name and call-header states run out, the
/// rest of the answer is released to free sampling, as without the grammar;
/// should a call's argument grammar run out of states (its own bound), the
/// request fails as an impossible state, as a forced call's does.
final class GPTOSSAutoToolConstraint: CBv2TokenConstraint, @unchecked Sendable {
    enum Phase: Hashable {
        /// A message header (the prompt opens the first one): the suffix of
        /// its bytes that still starts ` to=functions.`.
        case header(window: [UInt8])
        /// A message body, or a call's arguments without a compiled schema.
        case body
        /// The function name typed so far.
        case name([UInt8])
        /// After a complete name and `<|channel|>`: bytes of `commentary` matched.
        case channel(tool: Int, matched: Int)
        /// The rest of a call header, until `<|message|>`.
        case rest(tool: Int, window: [UInt8])
        case arguments(tool: Int, state: Int)
    }

    /// The recipient as both call headers spell it, after the role or the
    /// channel (`HarmonyToolCallParser`'s start tags).
    static let recipient = Array(" to=functions.".utf8)
    private static let commentary = Array("commentary".utf8)
    /// The arguments' delegates intern at most their own maximum each; the
    /// header windows and names add a few hundred more.
    static let maximumStates = 2 * JSONAnswerConstraint.maximumStates
    /// After resource exhaustion every later token is free (`releasedState`).
    static let releasedState = Int.max
    /// The mask cache key of every state whose mask is the whole vocabulary.
    static let freeMaskKey = -2
    private static let maximumMaskEntries = 8

    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let names: [[UInt8]]
    private let argumentSchemas: [CompiledToolSchema?]
    private let argumentConstraints: [JSONAnswerConstraint?]
    private let framing: GPTOSSHarmonyFraming
    private let vocabulary: JSONAnswerVocabulary
    private let markers = JSONAnswerProfile.gptOSS.contentMarkers
    /// Every id of the model's vocabulary: a free span's mask.
    private let allTokenIDs: [Int]
    /// `<|channel|>`, `<|constrain|>` and `<|message|>`, ascending: the
    /// controls a complete name or the rest of a call header may meet. All
    /// sort above the pieces, so appending them keeps a mask ascending.
    private let callHeaderControls: [Int]
    /// Pieces holding `.`, the recipient's last byte: the only ones a header
    /// state can refuse.
    private let recipientSensitive: [Int]
    private let lock = NSLock()
    private var phases: [Phase] = [.header(window: [])]
    private var phaseIndex: [Phase: Int] = [.header(window: []): 0]
    private var allowedCache: [(state: Int, tokens: [Int])] = []
    /// Header masks by the pieces they refuse.
    private var headerMasks: [(rejected: Set<Int>, tokens: [Int])] = []
    /// The pieces each header state refuses (`headerRejected`).
    private var headerRejections: [Int: Set<Int>] = [:]

    init(names: [String], arguments: [CompiledToolSchema?], framing: GPTOSSHarmonyFraming,
         vocabulary: JSONAnswerVocabulary, maxTokens: Int) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS auto tool calls require a positive output budget")
        }
        guard !names.isEmpty, names.count == arguments.count, names.count <= ToolConstraintSchemaCompiler.maxTools,
              names.allSatisfy(ToolChoicePromptPolicy.isValidFunctionName), Set(names).count == names.count else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS auto tool calls require valid declared function names")
        }
        guard !vocabulary.stopTokenIDs.contains(framing.end) else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS messages must not end the request")
        }
        let profile = JSONAnswerProfile.gptOSS
        self.names = names.map { Array($0.utf8) }
        argumentSchemas = arguments
        argumentConstraints = arguments.map { schema in
            schema.flatMap {
                try? JSONAnswerConstraint(format: JSONAnswerFormat(arguments: $0, profile: profile), profile: profile,
                    vocabulary: vocabulary, initialPhase: .answer, maxTokens: maxTokens)
            }
        }
        self.framing = framing
        self.vocabulary = vocabulary
        self.maxTokens = maxTokens
        fallbackTokenID = vocabulary.fallbackTokenID
        let masks = Self.vocabularyMasks(for: vocabulary)
        allTokenIDs = masks.allTokenIDs
        callHeaderControls = [framing.channel, framing.constrain, framing.message].sorted()
        recipientSensitive = masks.recipientSensitive
    }

    /// The work that depends only on the vocabulary, done once per
    /// vocabulary instance rather than per request.
    final class VocabularyMasks: Sendable {
        /// Every id of the vocabulary: a free span's mask.
        let allTokenIDs: [Int]
        /// Pieces holding `.`, the recipient's last byte: the only ones a
        /// header state can refuse.
        let recipientSensitive: [Int]

        init(_ vocabulary: JSONAnswerVocabulary) {
            allTokenIDs = Array(0..<vocabulary.pieces.count)
            recipientSensitive = vocabulary.pieceTokenIDs.filter { vocabulary.pieces[$0].contains(0x2E) }
        }
    }

    private final class VocabularyMasksCache: @unchecked Sendable {
        private struct Entry {
            weak var vocabulary: JSONAnswerVocabulary?
            let masks: VocabularyMasks
        }
        private let lock = NSLock()
        private var entries: [Entry] = []

        /// Held weakly: an entry leaves with its vocabulary, so a reused
        /// address never finds another vocabulary's masks.
        func masks(for vocabulary: JSONAnswerVocabulary) -> VocabularyMasks {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.vocabulary == nil }
            if let entry = entries.first(where: { $0.vocabulary === vocabulary }) { return entry.masks }
            let masks = VocabularyMasks(vocabulary)
            entries.append(Entry(vocabulary: vocabulary, masks: masks))
            return masks
        }
    }

    private static let masksCache = VocabularyMasksCache()

    static func vocabularyMasks(for vocabulary: JSONAnswerVocabulary) -> VocabularyMasks {
        masksCache.masks(for: vocabulary)
    }

    /// The same grammar for another output budget: the continuation the loop
    /// guard submits after ending a thought, whose prompt ends at the next
    /// assistant message as the request's own prompt does.
    func withMaxTokens(_ budget: Int) throws -> GPTOSSAutoToolConstraint {
        try GPTOSSAutoToolConstraint(names: names.map { String(decoding: $0, as: UTF8.self) },
            arguments: argumentSchemas, framing: framing, vocabulary: vocabulary, maxTokens: budget)
    }

    /// Whether a declared function's arguments are constrained.
    func constrainsArguments(of name: String) -> Bool {
        names.firstIndex(of: Array(name.utf8)).map { argumentConstraints[$0] != nil } ?? false
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0 else { return [] }
        if state == Self.releasedState { return allTokenIDs }
        guard phases.indices.contains(state) else { return [] }
        if let index = allowedCache.firstIndex(where: { $0.state == state }) {
            let entry = allowedCache.remove(at: index)
            allowedCache.append(entry)
            return entry.tokens
        }
        let allowed: [Int]
        switch phases[state] {
        case .body:
            return allTokenIDs
        case .header:
            allowed = headerMask(state)
        case .arguments(let tool, let inner):
            // The delegate caches its own masks.
            return argumentConstraints[tool]?.allowedTokenIDs(state: inner, remainingTokens: remainingTokens) ?? []
        case .name(let prefix):
            let pieces = vocabulary.acceptedTokens(from: phases[state]) { consume(&$0, $1) }
            allowed = names.contains(prefix) ? pieces + callHeaderControls : pieces
        case .channel:
            allowed = vocabulary.acceptedTokens(from: phases[state]) { consume(&$0, $1) }
        case .rest:
            let rejected = Set(vocabulary.reasoningSensitive.filter { transition(phases[state], token: $0) == nil })
            let pieces = rejected.isEmpty ? vocabulary.pieceTokenIDs
                : vocabulary.pieceTokenIDs.filter { !rejected.contains($0) }
            allowed = pieces + callHeaderControls
        }
        if allowedCache.count == Self.maximumMaskEntries { allowedCache.removeFirst() }
        allowedCache.append((state, allowed))
        return allowed
    }

    /// The allowed set depends on the budget only through `remainingTokens > 0`,
    /// and interned state ids are never reused. Every state whose mask is the
    /// whole vocabulary shares one key, so free spans reuse one uploaded mask.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0 else { return nil }
        if state == Self.releasedState { return Self.freeMaskKey }
        guard phases.indices.contains(state) else { return nil }
        switch phases[state] {
        case .body:
            return Self.freeMaskKey
        case .header:
            return headerRejected(state).isEmpty ? Self.freeMaskKey : state
        default:
            return state
        }
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens.
    var allowsChainedDecode: Bool { true }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard tokenID >= 0, tokenID < allTokenIDs.count else { return nil }
        if state == Self.releasedState {
            return vocabulary.stopTokenIDs.contains(tokenID) ? -1 : Self.releasedState
        }
        guard phases.indices.contains(state) else { return nil }
        let next: Phase
        if case .arguments(let tool, let inner) = phases[state] {
            guard let delegate = argumentConstraints[tool],
                  let advanced = delegate.nextState(state: inner, tokenID: tokenID) else { return nil }
            if advanced == -1 { return -1 }
            next = .arguments(tool: tool, state: advanced)
        } else if vocabulary.stopTokenIDs.contains(tokenID) {
            switch phases[state] {
            case .header, .body: return -1
            default: return nil
            }
        } else {
            guard let advanced = transition(phases[state], token: tokenID) else { return nil }
            next = advanced
        }
        if let known = phaseIndex[next] { return known }
        guard phases.count < Self.maximumStates else { return Self.releasedState }
        phases.append(next)
        phaseIndex[next] = phases.count - 1
        return phases.count - 1
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return phases.count }

    /// The phase after one non-stop token, or nil when it is refused there.
    private func transition(_ phase: Phase, token: Int) -> Phase? {
        let piece = vocabulary.pieces[token]
        guard piece.isEmpty else {
            var next = phase
            for byte in piece {
                guard consume(&next, byte) else { return nil }
            }
            return next
        }
        // Control tokens and every other id without a piece.
        switch phase {
        case .body:
            return token == framing.start ? .header(window: []) : .body
        case .header:
            if token == framing.message || token == framing.end { return .body }
            return .header(window: [])
        case .name(let prefix):
            guard let tool = names.firstIndex(of: prefix) else { return nil }
            if token == framing.channel { return .channel(tool: tool, matched: 0) }
            if token == framing.constrain { return .rest(tool: tool, window: []) }
            return token == framing.message ? arguments(tool) : nil
        case .channel:
            return nil
        case .rest(let tool, _):
            if token == framing.channel || token == framing.constrain { return .rest(tool: tool, window: []) }
            return token == framing.message ? arguments(tool) : nil
        case .arguments:
            return nil
        }
    }

    private func arguments(_ tool: Int) -> Phase {
        argumentConstraints[tool].map { .arguments(tool: tool, state: $0.initialState) } ?? .body
    }

    /// One byte of a piece. Free phases accept every byte.
    private func consume(_ phase: inout Phase, _ byte: UInt8) -> Bool {
        switch phase {
        case .body:
            return true
        case .header(var window):
            window.append(byte)
            while !window.isEmpty && !Self.recipient.starts(with: window) { window.removeFirst() }
            phase = window == Self.recipient ? .name([]) : .header(window: window)
            return true
        case .name(let prefix):
            let extended = prefix + [byte]
            if names.contains(where: { $0.starts(with: extended) }) {
                phase = .name(extended)
                return true
            }
            guard byte == 0x20, let tool = names.firstIndex(of: prefix) else { return false }
            phase = .rest(tool: tool, window: [])
            return true
        case .channel(let tool, let matched):
            guard Self.commentary[matched] == byte else { return false }
            phase = matched + 1 == Self.commentary.count ? .rest(tool: tool, window: [])
                : .channel(tool: tool, matched: matched + 1)
            return true
        case .rest(let tool, var window):
            window.append(byte)
            while !window.isEmpty && !markers.contains(where: { $0.starts(with: window) }) { window.removeFirst() }
            if markers.contains(where: { $0.count <= window.count && window.suffix($0.count).elementsEqual($0) }) {
                return false
            }
            phase = .rest(tool: tool, window: window)
            return true
        case .arguments:
            return false
        }
    }

    /// The pieces a header state refuses: those that complete the recipient
    /// and go on with bytes no declared name starts with.
    private func headerRejected(_ state: Int) -> Set<Int> {
        if let rejected = headerRejections[state] { return rejected }
        let rejected = Set(recipientSensitive.filter { transition(phases[state], token: $0) == nil })
        headerRejections[state] = rejected
        return rejected
    }

    private func headerMask(_ state: Int) -> [Int] {
        let rejected = headerRejected(state)
        if rejected.isEmpty { return allTokenIDs }
        if let index = headerMasks.firstIndex(where: { $0.rejected == rejected }) {
            let mask = headerMasks.remove(at: index)
            headerMasks.append(mask)
            return mask.tokens
        }
        let tokens = allTokenIDs.filter { !rejected.contains($0) }
        if headerMasks.count == Self.maximumMaskEntries { headerMasks.removeFirst() }
        headerMasks.append((rejected, tokens))
        return tokens
    }
}
