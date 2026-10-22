// Copyright © 2026 Eigen Labs.
//
// Exact prompt-token reuse for chat-template prompts.
//
// Prompt preparation renders the chat template and BPE-encodes the whole
// conversation on every request, on one core, before engine submission:
// 3.6-11.6 µs per token, so 0.1-0.4 s at 32K tokens. Multi-turn chats and agent
// loops resend the same history, so nearly all of that work repeats.
//
// swift-transformers splits its input at every added-token match and encodes
// each section on its own. The rendered prompt is therefore cut where an added
// token begins (`PromptPieceSplitter` states when that is exact), every piece
// is looked up by SHA-256 over (cache scope, piece bytes), and only pieces not
// seen before are encoded, in parallel when several large ones are missing.
// Token IDs equal the unchanged path's: the render replays
// `PreTrainedTokenizer.applyChatTemplate` over the same template (or its
// `ChatTemplateLoopRewrites` form) and configuration, a load-time self-check
// compares both paths, and a sampled background check keeps comparing them
// against the unchanged template while serving. Pieces are partitioned by the
// prefix KV cache's scope, so a faster hit reveals nothing across tenants.
//
// `DARKBLOOM_TTFT_PROMPT_CACHE=0` restores the unchanged path.

import CryptoKit
import Foundation
import Hub
import Jinja
import Tokenizers

enum PromptTokenCachePolicy {
    static let environmentKey = "DARKBLOOM_TTFT_PROMPT_CACHE"
    static let capacityEnvironmentKey = "DARKBLOOM_TTFT_PROMPT_CACHE_MB"
    static let verifyEnvironmentKey = "DARKBLOOM_TTFT_PROMPT_CACHE_VERIFY"

    /// The global prefix-cache kill switch also turns token reuse off.
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard PrefixCachePolicy.isGloballyEnabled(environment: environment) else { return false }
        guard let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return true }
        return !["0", "false", "off", "no"].contains(raw)
    }

    /// Token storage bound per loaded tokenizer. 32 MiB keeps a few million
    /// prompt tokens, a few hundred long conversations; `0` keeps parallel
    /// encoding only.
    static func capacityBytes(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment[capacityEnvironmentKey],
            let megabytes = Int(raw.trimmingCharacters(in: .whitespaces)), megabytes >= 0
        else { return 32 << 20 }
        return min(megabytes, 4096) << 20
    }

    /// The first prompts of each tokenizer, then one in N, are re-tokenized on
    /// the unchanged path in the background; a mismatch turns the cache off for
    /// that tokenizer. `0` disables the check.
    static func verificationInterval(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment[verifyEnvironmentKey],
            let interval = Int(raw.trimmingCharacters(in: .whitespaces)), interval >= 0
        else { return 256 }
        return interval
    }

    static let verifiedFirstPrompts = 4

    /// Encode workers for the missing pieces of one long prompt: one core in
    /// four, at most four, so the engine thread and other requests keep cores.
    static func encodeWorkers(activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        max(1, min(4, activeProcessors / 4))
    }

    /// Below this many missing bytes (about 8K tokens) one core is faster than
    /// fanning out.
    static let parallelEncodeMinimumBytes = 32 << 10
}

/// Cuts a rendered prompt so that encoding each piece with
/// `encode(text:addSpecialTokens: false)` and joining the token IDs equals
/// encoding the whole text.
///
/// `PreTrainedTokenizer.tokenize(text:)` splits its input at matches of an
/// alternation of every added token's literal and maps each section on its
/// own: a section equal to an added token with an id passes through, others
/// are normalized, pre-tokenized and encoded, and only section 0 sees
/// `.firstSection`; unknown-token fusion is per section. A cut where an added
/// token `C` begins therefore changes nothing when:
/// - the match there is exactly `C`: no added token overlaps `C` from the
///   left (a proper suffix prefix-compatible with `C`), and no other added
///   token is prefix-compatible with `C` itself;
/// - `C` has an id, so its section passes through in either call and every
///   later section keeps its non-first position;
/// - no added token strips whitespace (`lstrip`/`rstrip` move match edges);
/// - the separator regex compiles (otherwise nothing is split);
/// - post-processing without special tokens is the identity.
/// The splitter declines (nil) for any tokenizer outside these conditions.
struct PromptPieceSplitter: Sendable {
    /// UTF-8 of each cut token, bucketed by first byte, longest first.
    private let buckets: [[[UInt8]]]
    private let firstBytes: [Bool]
    let cutTokens: [String]
    var cutTokenCount: Int { cutTokens.count }

    init?(tokenizerData: Config) {
        // Same reads as `PreTrainedTokenizer.init`: the separator alternation
        // holds every entry with content; pass-through needs an id as well.
        var alternatives: [[UInt8]] = []
        var candidates: [[UInt8]] = []
        for addedToken in tokenizerData["addedTokens"].array(or: []) {
            guard let content = addedToken.content.string() else { continue }
            if content.isEmpty || addedToken["lstrip"].boolean(or: false)
                || addedToken["rstrip"].boolean(or: false)
            {
                return nil
            }
            alternatives.append(Array(content.utf8))
            if addedToken["id"].integer() != nil { candidates.append(Array(content.utf8)) }
        }
        let pattern = alternatives
            .map { "(\(NSRegularExpression.escapedPattern(for: String(decoding: $0, as: UTF8.self))))" }
            .joined(separator: "|")
        guard (try? NSRegularExpression(pattern: pattern, options: [])) != nil,
            Self.postProcessorIsIdentity(tokenizerData["postProcessor"])
        else { return nil }

        var buckets = Array(repeating: [[UInt8]](), count: 256)
        var cutTokens: [String] = []
        for candidate in Set(candidates) where Self.isExactCut(candidate, alternatives: alternatives) {
            buckets[Int(candidate[0])].append(candidate)
            cutTokens.append(String(decoding: candidate, as: UTF8.self))
        }
        for index in buckets.indices { buckets[index].sort { $0.count > $1.count } }
        self.buckets = buckets
        self.firstBytes = buckets.map { !$0.isEmpty }
        self.cutTokens = cutTokens.sorted()
    }

    /// Ascending byte offsets in `1..<utf8.count` where a piece starts.
    func cutOffsets(in utf8: UnsafeBufferPointer<UInt8>) -> [Int] {
        var cuts: [Int] = []
        guard cutTokenCount > 0, let base = utf8.baseAddress else { return cuts }
        let count = utf8.count
        var index = 0
        firstBytes.withUnsafeBufferPointer { first in
            while index < count {
                guard first[Int(base[index])] else {
                    index += 1
                    continue
                }
                var matched = 0
                for token in buckets[Int(base[index])] where token.count <= count - index {
                    let equal = token.withUnsafeBufferPointer {
                        memcmp($0.baseAddress!, base + index, token.count) == 0
                    }
                    if equal {
                        matched = token.count
                        break
                    }
                }
                if matched == 0 {
                    index += 1
                    continue
                }
                if index > 0 { cuts.append(index) }
                index += matched
            }
        }
        return cuts
    }

    private static func isExactCut(_ cut: [UInt8], alternatives: [[UInt8]]) -> Bool {
        for token in alternatives {
            if token != cut, prefixCompatible(token[...], cut) { return false }
            guard token.count > 1 else { continue }
            for offset in 1..<token.count where prefixCompatible(token[offset...], cut) {
                return false
            }
        }
        return true
    }

    /// One byte string is a prefix of the other.
    private static func prefixCompatible(_ lhs: ArraySlice<UInt8>, _ rhs: [UInt8]) -> Bool {
        let length = min(lhs.count, rhs.count)
        return lhs.prefix(length).elementsEqual(rhs.prefix(length))
    }

    /// Mirrors swift-transformers' post-processors with `addSpecialTokens`
    /// false and no pair.
    static func postProcessorIsIdentity(_ config: Config) -> Bool {
        guard let type = config.type.string() else { return true }
        switch type {
        case "ByteLevel", "BertProcessing":
            return true
        case "TemplateProcessing":
            var sequences = 0
            for item in config.single.array(or: []) where item.SpecialToken.id.string() == nil {
                switch item.Sequence.id.string() {
                case "A": sequences += 1
                case "B": return false
                default: continue
                }
            }
            return sequences == 1
        case "Sequence":
            return config.processors.array(or: []).allSatisfy(postProcessorIsIdentity)
        default:
            return false
        }
    }
}

/// Byte-bounded store of piece token IDs keyed by the scoped piece digest.
/// Two generations approximate least-recently-used eviction without sorting:
/// new and reused pieces live in the young generation; when it fills half the
/// capacity it becomes the old one, and the previous old generation is dropped.
final class PromptPieceTokenStore: @unchecked Sendable {
    private static let entryOverheadBytes = 96
    let capacityBytes: Int
    private let lock = NSLock()
    private var young: [SHA256Digest: [Int32]] = [:]
    private var old: [SHA256Digest: [Int32]] = [:]
    private var youngBytes = 0
    private var oldBytes = 0

    init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
    }

    var storedBytes: Int { lock.withLock { youngBytes + oldBytes } }

    func lookup(_ keys: [SHA256Digest]) -> [[Int32]?] {
        lock.withLock {
            keys.map { key in
                if let tokens = young[key] { return tokens }
                guard let tokens = old.removeValue(forKey: key) else { return nil }
                oldBytes -= Self.cost(tokens)
                admit(key, tokens)
                return tokens
            }
        }
    }

    func insert(_ items: [(SHA256Digest, [Int32])]) {
        lock.withLock {
            for (key, tokens) in items where young[key] == nil {
                if let previous = old.removeValue(forKey: key) { oldBytes -= Self.cost(previous) }
                admit(key, tokens)
            }
        }
    }

    /// Caller holds the lock.
    private func admit(_ key: SHA256Digest, _ tokens: [Int32]) {
        let cost = Self.cost(tokens)
        // One giant piece must not flush everything else.
        guard cost <= capacityBytes / 8 else { return }
        young[key] = tokens
        youngBytes += cost
        guard youngBytes > capacityBytes / 2 else { return }
        old = young
        oldBytes = youngBytes
        young = [:]
        youngBytes = 0
    }

    private static func cost(_ tokens: [Int32]) -> Int {
        tokens.count * MemoryLayout<Int32>.stride + entryOverheadBytes
    }
}

/// A tokenizer that can reuse prompt tokens across requests of one cache scope.
protocol PromptTokenCaching {
    var promptTokenCache: PromptTokenCache? { get }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?, promptCacheScope: String
    ) throws -> [Int]
}

/// Renders a chat template the way `PreTrainedTokenizer.applyChatTemplate`
/// does and encodes the result piecewise through a `PromptPieceTokenStore`.
final class PromptTokenCache: @unchecked Sendable {
    /// The configurations a `PreTrainedTokenizer` was built from.
    struct Configurations: @unchecked Sendable {
        let tokenizerConfig: Config
        let tokenizerData: Config
    }

    /// swift-transformers 1.3 `specialTokenAttributes`.
    private static let specialTokenAttributes: Set<String> = [
        "bos_token", "eos_token", "unk_token", "sep_token", "pad_token", "cls_token",
        "mask_token", "additional_special_tokens",
    ]

    private static let templateOptions = Template.Options(lstripBlocks: true, trimBlocks: true)

    private let upstream: PreTrainedTokenizer
    private let chatTemplate: String
    /// The unchanged template, or its `ChatTemplateLoopRewrites` form when
    /// that passed the self-check. Chosen once, during initialization.
    private var template: Template
    /// Names of the loop rewrites `template` renders with.
    private(set) var templateLoopRewrites: [String] = []
    private let specialTokenContext: [String: Value]
    private let splitter: PromptPieceSplitter
    private let store: PromptPieceTokenStore
    private let workers: Int
    private let verificationInterval: Int
    private let lock = NSLock()
    private var disabled = false
    private var servedPrompts = 0

    /// nil when the tokenizer or template falls outside the exact conditions,
    /// or when the load-time self-check disagrees with the unchanged path.
    init?(
        upstream: PreTrainedTokenizer, configurations: Configurations,
        chatTemplate: String, selfCheckContext: [String: any Sendable]?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let splitter = PromptPieceSplitter(tokenizerData: configurations.tokenizerData),
            let template = try? Template(chatTemplate, with: Self.templateOptions),
            let specialTokenContext = try? Self.specialTokenContext(configurations.tokenizerConfig)
        else { return nil }
        self.upstream = upstream
        self.chatTemplate = chatTemplate
        self.template = template
        self.specialTokenContext = specialTokenContext
        self.splitter = splitter
        self.store = PromptPieceTokenStore(capacityBytes: PromptTokenCachePolicy.capacityBytes(environment: environment))
        self.workers = PromptTokenCachePolicy.encodeWorkers()
        self.verificationInterval = PromptTokenCachePolicy.verificationInterval(environment: environment)
        // Linear-time loop forms only when they agree with the unchanged path.
        if ChatTemplateLoopRewrites.isEnabled(environment: environment) {
            let rewrite = ChatTemplateLoopRewrites.apply(to: chatTemplate)
            if !rewrite.applied.isEmpty, let rewritten = try? Template(rewrite.template, with: Self.templateOptions) {
                self.template = rewritten
                templateLoopRewrites = rewrite.applied
                if selfCheckPasses(context: selfCheckContext) { return }
                self.template = template
                templateLoopRewrites = []
            }
        }
        guard selfCheckPasses(context: selfCheckContext) else { return nil }
    }

    var isActive: Bool { lock.withLock { !disabled } }
    var storedBytes: Int { store.storedBytes }
    var cutTokens: [String] { splitter.cutTokens }

    /// Token IDs equal to `upstream.applyChatTemplate` with this template and
    /// `addGenerationPrompt: true`, or nil when the caller must use that path
    /// (cache off, or the render threw; the unchanged path owns the error).
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?, scope: String
    ) -> [Int]? {
        guard isActive, let rendered = try? render(messages: messages, tools: tools, additionalContext: additionalContext)
        else { return nil }
        let tokens = encode(rendered, scope: scope)
        scheduleVerification(messages: messages, tools: tools, additionalContext: additionalContext, tokens: tokens)
        return tokens
    }

    /// Piecewise `encode(text:addSpecialTokens: false)` of a rendered prompt.
    func encode(_ rendered: String, scope: String) -> [Int] {
        var text = rendered
        return text.withUTF8 { utf8 in
            let bounds = [0] + splitter.cutOffsets(in: utf8) + [utf8.count]
            let ranges = (1..<bounds.count).map { bounds[$0 - 1]..<bounds[$0] }
            let scoped = Self.scopedHasher(scope: scope)
            let keys = ranges.map { range in
                var hasher = scoped
                hasher.update(bufferPointer: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: utf8[range])))
                return hasher.finalize()
            }
            var pieces = store.lookup(keys)

            // Encode each distinct missing piece once.
            var missing: [Int] = []
            var firstMissing: [SHA256Digest: Int] = [:]
            for index in pieces.indices where pieces[index] == nil && firstMissing[keys[index]] == nil {
                firstMissing[keys[index]] = index
                missing.append(index)
            }
            if !missing.isEmpty {
                let texts = missing.map { String(decoding: UnsafeBufferPointer(rebasing: utf8[ranges[$0]]), as: UTF8.self) }
                let encoded = encodePieces(texts).map { $0.map { Int32(truncatingIfNeeded: $0) } }
                store.insert(missing.indices.map { (keys[missing[$0]], encoded[$0]) })
                for (slot, index) in missing.enumerated() { pieces[index] = encoded[slot] }
                for index in pieces.indices where pieces[index] == nil {
                    pieces[index] = pieces[firstMissing[keys[index]]!]
                }
            }
            var tokens: [Int] = []
            tokens.reserveCapacity(pieces.reduce(0) { $0 + ($1?.count ?? 0) })
            for piece in pieces {
                for token in piece! { tokens.append(Int(token)) }
            }
            return tokens
        }
    }

    private func encodePieces(_ texts: [String]) -> [[Int]] {
        let bytes = texts.reduce(0) { $0 + $1.utf8.count }
        guard workers > 1, texts.count > 1, bytes >= PromptTokenCachePolicy.parallelEncodeMinimumBytes else {
            return texts.map { upstream.encode(text: $0, addSpecialTokens: false) }
        }
        // Longest piece first, each to the least-loaded worker.
        var lanes = Array(repeating: [Int](), count: min(workers, texts.count))
        var load = Array(repeating: 0, count: lanes.count)
        for index in texts.indices.sorted(by: { texts[$0].utf8.count > texts[$1].utf8.count }) {
            let lane = load.indices.min { load[$0] < load[$1] }!
            lanes[lane].append(index)
            load[lane] += texts[index].utf8.count
        }
        let assignment = lanes
        let results = EncodedPieces(count: texts.count)
        let upstream = self.upstream
        DispatchQueue.concurrentPerform(iterations: assignment.count) { lane in
            for index in assignment[lane] {
                results.set(index, upstream.encode(text: texts[index], addSpecialTokens: false))
            }
        }
        return results.values
    }

    // MARK: - Rendering

    /// Same context, built in the same order, as swift-transformers.
    private func render(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> String {
        var context: [String: Value] = try [
            "messages": .array(messages.map { try Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools {
            context["tools"] = try .array(tools.map { try Value(any: $0) })
        }
        if let additionalContext {
            for (key, value) in additionalContext {
                context[key] = try Value(any: value)
            }
        }
        for (key, value) in specialTokenContext {
            context[key] = value
        }
        return try template.render(context)
    }

    private static func specialTokenContext(_ tokenizerConfig: Config) throws -> [String: Value] {
        var context: [String: Value] = [:]
        for (key, value) in tokenizerConfig.dictionary(or: [:]) {
            guard specialTokenAttributes.contains(key.string), !value.isNull() else { continue }
            if let string = value.string() {
                context[key.string] = .string(string)
            } else if let dictionary = value.dictionary() {
                // `addedTokenAsString`
                let token = Config(dictionary)
                if let content = token.string() ?? token.content.string() {
                    context[key.string] = .string(content)
                }
            } else if let strings: [String] = value.get() {
                context[key.string] = .array(strings.map { .string($0) })
            } else {
                context[key.string] = try Value(any: value)
            }
        }
        return context
    }

    private static func scopedHasher(scope: String) -> SHA256 {
        var hasher = SHA256()
        hasher.update(data: Data("darkbloom.prompt-piece.v1\u{0}".utf8))
        withUnsafeBytes(of: UInt64(scope.utf8.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(scope.utf8))
        return hasher
    }

    // MARK: - Equivalence checks

    private func reference(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) -> [Int]? {
        try? upstream.applyChatTemplate(
            messages: messages, chatTemplate: .literal(chatTemplate), addGenerationPrompt: true,
            truncation: false, maxLength: nil, tools: tools, additionalContext: additionalContext)
    }

    /// Both paths over prompts that exercise every cut token in content,
    /// multi-turn history, a tool round trip and a tool loop (consecutive
    /// calls, a multi-result run, final answers between calls: every scan the
    /// loop rewrites replace); both throwing also agrees.
    private func selfCheckPasses(context: [String: any Sendable]?) -> Bool {
        let probe = "Hello\u{3000}wörld, café 東京 🙂\n\n  indented\tline \(String(repeating: "x", count: 64))"
        let literalTokens = splitter.cutTokens.joined(separator: " a\n")
        let tool: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": "lookup",
                "description": "Look a value up.",
                "parameters": [
                    "type": "object",
                    "properties": ["key": ["type": "string", "description": "Key."] as [String: any Sendable]] as [String: any Sendable],
                    "required": ["key"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        func call(_ id: String) -> [String: any Sendable] {
            ["role": "assistant", "content": "", "tool_calls": [[
                "id": id, "type": "function",
                "function": ["name": "lookup", "arguments": ["key": id] as [String: any Sendable]] as [String: any Sendable],
            ] as [String: any Sendable]]]
        }
        func result(_ id: String) -> [String: any Sendable] {
            ["role": "tool", "content": "{\"value\": \"\(id)\"}", "tool_call_id": id, "name": "lookup"]
        }
        let probes: [([[String: any Sendable]], [[String: any Sendable]]?)] = [
            ([["role": "system", "content": "You are helpful."], ["role": "user", "content": probe]], nil),
            ([["role": "user", "content": "a \(literalTokens) b"], ["role": "assistant", "content": probe],
              ["role": "user", "content": "again: " + probe]], nil),
            ([["role": "user", "content": probe], call("call_0"), result("call_0")], [tool]),
            ([["role": "system", "content": "Use tools."], ["role": "user", "content": probe],
              call("call_1"), result("call_1"), call("call_2"), result("call_2"), result("call_3"),
              ["role": "assistant", "content": "Found both."], ["role": "user", "content": "again: " + probe],
              ["role": "assistant", "content": "Checking."], call("call_4"), result("call_4"),
              call("call_5"), result("call_5"), ["role": "assistant", "content": "Done."],
              ["role": "user", "content": "Thanks."], call("call_6"), result("call_6")], [tool]),
        ]
        let scope = "darkbloom.prompt-cache.self-check"
        var rendered = 0
        for (messages, tools) in probes {
            let expected = reference(messages: messages, tools: tools, additionalContext: context)
            let text = try? render(messages: messages, tools: tools, additionalContext: context)
            let actual = text.map { encode($0, scope: scope) }
            guard expected == actual else { return false }
            // Second pass is served from the store.
            guard text.map({ encode($0, scope: scope) }) == expected else { return false }
            if text != nil { rendered += 1 }
        }
        // A template that rejects every probe has proven nothing.
        return rendered > 0
    }

    private func scheduleVerification(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?, tokens: [Int]
    ) {
        guard verificationInterval > 0 else { return }
        let served = lock.withLock {
            servedPrompts += 1
            return servedPrompts
        }
        guard served <= PromptTokenCachePolicy.verifiedFirstPrompts || served % verificationInterval == 0 else { return }
        Task.detached(priority: .background) { [weak self] in
            guard let self, let expected = self.reference(
                messages: messages, tools: tools, additionalContext: additionalContext),
                expected != tokens
            else { return }
            self.lock.withLock { self.disabled = true }
            ProviderLogger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "prompt-cache")
                .error("Prompt token cache disagreed with the unchanged tokenizer path; disabled for this model")
        }
    }
}

private final class EncodedPieces: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Int]]

    init(count: Int) {
        storage = Array(repeating: [], count: count)
    }

    func set(_ index: Int, _ tokens: [Int]) {
        lock.withLock { storage[index] = tokens }
    }

    var values: [[Int]] { lock.withLock { storage } }
}
