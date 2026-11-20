// Copyright © 2026 Eigen Labs.
//
// `$ref` resolution for tool schemas, before the render-safe repair
// (`ToolSchemaNormalization`). The repair types a `$ref` node like any typeless
// node, as a string, so a reference to an object reaches the model as a
// string: Gemma renders `items` of `type:STRING`, GPT-OSS `string[]`, the JSON
// templates `"type":"string"` beside the reference (TOOLSCHEMA-REF).
//
// The coordinator resolves routed requests (darkbloom-platform
// coordinator/api/inference/request/toolschema_refs.go) for the builds its
// allowlist names; a routed body already carries its decision, so this file
// serves the local API only (`LocalChatUploadResponder`). Both implement the
// same rules and bounds, pinned by the shared fixtures in
// `Tests/ProviderCoreTests/Fixtures/toolschema-refs/` (copied byte for byte
// from darkbloom-platform coordinator/tests/api/inference/request/testdata/
// toolschema_refs/).

import Foundation

enum ToolSchemaRefMode: String, Sendable, Equatable {
    /// `$ref` is left to the repair: today's bytes.
    case off
    /// Every `$ref` node without a `type` gets its target's type ("object"
    /// when the target is unknown, recursive or gives no evidence); nothing is
    /// inlined and `$defs` stay as they are.
    case typed
    /// Local, non-recursive references are replaced by a copy of their target
    /// when the schema root fits the bounds; the rest are typed.
    case inline
}

struct ToolSchemaRefStats: Equatable, Sendable {
    var refs = 0
    var inlined = 0
    var keptCyclic = 0
    var keptUnresolved = 0
    var keptBounds = 0
    var typed = 0
    var off = 0

    mutating func add(_ other: ToolSchemaRefStats) {
        refs += other.refs
        inlined += other.inlined
        keptCyclic += other.keptCyclic
        keptUnresolved += other.keptUnresolved
        keptBounds += other.keptBounds
        typed += other.typed
        off += other.off
    }
}

/// The per-model `$ref` mode: the first rule whose pattern is a
/// case-insensitive substring of the model id. GLM5-Next keeps raw schemas and
/// MiMo at most the typed mode (its native path refuses the repair's
/// allow-all marker, which an inlined `{}` would gain).
struct ToolSchemaRefPolicy: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        let pattern: String
        let mode: ToolSchemaRefMode
    }

    static let environmentKey = "DARKBLOOM_TOOLSCHEMA_REF_RESOLVE_MODELS"

    /// The coordinator's default list: Gemma 4 26B (every build) and Qwen 3.8
    /// 27B, inlined. While the GPT-OSS `auto` grammar is on
    /// (`GPTOSSAutoToolGrammar`), the local API also inlines every GPT-OSS
    /// build's, for every tool choice, so its prompt shows the objects the
    /// grammar can then hold the arguments to (a tool whose prompt keeps a
    /// `$ref` keeps free arguments). Routed requests keep the coordinator's
    /// rendering. Every other model keeps the legacy repair.
    static let defaultRules = defaultRules(gptOSSAutoToolGrammar: GPTOSSAutoToolGrammar.enabled)

    static func defaultRules(gptOSSAutoToolGrammar: Bool) -> [Rule] {
        [Rule(pattern: "gemma-4-26b", mode: .inline), Rule(pattern: "qwen3.8-27b", mode: .inline)]
            + (gptOSSAutoToolGrammar ? [Rule(pattern: "gpt-oss", mode: .inline)] : [])
    }

    static let `default` = ToolSchemaRefPolicy(rules: defaultRules)

    let rules: [Rule]

    init(rules: [Rule]) {
        self.rules = rules.compactMap { rule in
            let pattern = rule.pattern.trimmingCharacters(in: .whitespaces).lowercased()
            return pattern.isEmpty ? nil : Rule(pattern: pattern, mode: rule.mode)
        }
    }

    /// Parses the value as the coordinator reads
    /// EIGENINFERENCE_TOOLSCHEMA_REF_RESOLVE_MODELS (darkbloom-platform
    /// `ParseToolSchemaRefResolveModels`): unset or blank keeps the default;
    /// an off word (`off`, `false`, `0`, `none`, `no`, `disabled`), as the
    /// whole value or as any entry, resolves for no model; otherwise
    /// comma-separated `pattern[=mode]` entries, the mode `inline` (the
    /// default), `typed`, or off (an off word or nothing after `=`), which
    /// excludes the models it matches. An entry with an unknown mode, an empty
    /// pattern or an on/off word for a pattern is ignored and makes `valid`
    /// false; a value whose entries are all ignored resolves for no model.
    static func parse(_ raw: String?) -> (policy: ToolSchemaRefPolicy, valid: Bool, ignored: [String]) {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return (.default, true, []) }
        var rules: [Rule] = []
        var off = false
        var ignored: [String] = []
        func ignore(_ entry: String) {
            if !ignored.contains(entry) { ignored.append(entry) }
        }
        for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
            let item = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            if offWords.contains(item) {
                off = true
                continue
            }
            var pattern = item
            var mode = ToolSchemaRefMode.inline
            if let equals = item.firstIndex(of: "=") {
                pattern = item[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                let name = item[item.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
                switch name {
                case "inline": mode = .inline
                case "typed": mode = .typed
                case _ where name.isEmpty || offWords.contains(name): mode = .off
                default:
                    ignore(item)
                    continue
                }
            }
            if pattern.isEmpty || offWords.contains(pattern) || onWords.contains(pattern) {
                ignore(item)
                continue
            }
            rules.append(Rule(pattern: pattern, mode: mode))
        }
        return (ToolSchemaRefPolicy(rules: off ? [] : rules), ignored.isEmpty, ignored)
    }

    private static let offWords: Set<String> = ["off", "false", "0", "none", "no", "disabled"]
    /// Not patterns (they would match no build).
    private static let onWords: Set<String> = ["on", "true", "1", "yes", "enabled"]

    func mode(forModel model: String, modelType: String?) -> ToolSchemaRefMode {
        if GLM5NextPromptPolicy.applies(modelType: modelType) { return .off }
        let id = model.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty, let rule = rules.first(where: { id.contains($0.pattern) }) else { return .off }
        if rule.mode == .inline, modelType == "mimo_v2" { return .typed }
        return rule.mode
    }
}

enum ToolSchemaRefResolution {
    /// Bounds of an inline, decided from the schema alone so the result is
    /// idempotent: a schema root inlines all of its non-recursive references
    /// or none, within `maxNodes` JSON values (objects, arrays and scalars;
    /// keys are not counted) and `maxDepth` levels, and a request's inlined
    /// roots within `maxRequestNodes`. The depth stays under
    /// `ToolConstraintValidation`'s 32 levels.
    static let maxNodes = 2048
    static let maxDepth = 24
    static let maxRequestNodes = 16384
    /// Work bounds that keep hostile reference graphs off the stack and the
    /// CPU (the cooperative pool's threads have 512 KiB stacks), as the
    /// coordinator's pointer and budget bounds do:
    /// - a pointer longer than `maxPointerBytes` or `maxPointerTokens` tokens
    ///   is unresolved (kept, typed `object`);
    /// - an inline follows at most `maxChainHops` references through targets
    ///   and stops past `maxDepth` levels (the root is typed instead); typing
    ///   follows at most `maxChainHops` hops (then `object`);
    /// - one request (every schema root and batch item) spends at most
    ///   `maxRequestLookups` typing lookups (one a reference followed, one per
    ///   whole 64 members of an `anyOf`/`oneOf`/`allOf` or `enum`); past them
    ///   a reference is typed `object`;
    /// - looking for reference cycles, one root walks at most
    ///   `maxGraphTargets` targets and `maxRootVisits` values, and one request
    ///   `maxRequestVisits` plus `visitsPerRoot` for each of its roots (so a
    ///   batch of honest tools isn't cut by position); a root past either
    ///   inlines nothing (its references are kept and typed);
    /// - an inline copies at most `maxRootBytes` of target text a root,
    ///   `maxRequestBytes` a request and `maxBodyBytes` a whole body (a batch's
    ///   items together); strings and keys count their UTF-8 bytes, scalars as
    ///   the coordinator's `refScalarBytes`, so a large target can't be
    ///   multiplied;
    /// - the cycle search's per-root visits add up to at most
    ///   `maxGrantedVisits` a body.
    static let maxPointerBytes = 1024
    static let maxPointerTokens = 32
    static let maxChainHops = 32
    static let maxRequestLookups = 65536
    static let maxRequestVisits = 65536
    static let visitsPerRoot = 2048
    static let maxRootVisits = 65536
    static let maxGraphTargets = 512
    static let maxRootBytes = 65536
    static let maxRequestBytes = 262144
    static let maxBodyBytes = 4 * 1024 * 1024
    static let maxGrantedVisits = 1 << 20

    /// One request's resolution work, shared by its schema roots and batch
    /// items.
    final class Work {
        private var lookups = ToolSchemaRefResolution.maxRequestLookups
        private var visits = ToolSchemaRefResolution.maxRequestVisits

        /// Spends `units` typing lookups; false (and nothing left) once the
        /// request has spent them all.
        fileprivate func spendLookups(_ units: Int = 1) -> Bool {
            guard lookups >= units, lookups > 0 else {
                lookups = 0
                return false
            }
            lookups -= units
            return true
        }

        /// Spends one cycle-search visit; false once the request has spent
        /// them all.
        fileprivate func spendVisit() -> Bool {
            guard visits > 0 else { return false }
            visits -= 1
            return true
        }

        /// A schema root of the request adds `visitsPerRoot` visits, at most
        /// `maxGrantedVisits` in all.
        fileprivate func addRoot() {
            let grant = min(ToolSchemaRefResolution.visitsPerRoot, ToolSchemaRefResolution.maxGrantedVisits - granted)
            granted += grant
            visits += grant
        }

        /// Spends `bytes` of the body's inline copies; false (spending nothing)
        /// when they don't fit.
        fileprivate func spendBytes(_ bytes: Int) -> Bool {
            guard bytes <= copyBytes else { return false }
            copyBytes -= bytes
            return true
        }

        private var granted = 0
        private var copyBytes = ToolSchemaRefResolution.maxBodyBytes

        /// The visits granted so far (tests).
        var grantedVisits: Int { granted }
    }

    /// `data` with the `tools` of a chat (or Responses) body resolved for
    /// `mode`; the input bytes when nothing changes, the body carries no
    /// `tools`, or it is not a JSON object this can rewrite.
    static func resolveBody(_ data: Data, mode: ToolSchemaRefMode) -> Data {
        guard mode != .off, data.count <= ToolSchemaNormalization.maxNormalizationBytes,
            data.range(of: Data("\"tools\"".utf8)) != nil, data.range(of: Data("\"$ref\"".utf8)) != nil,
            var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            var tools = root["tools"] as? [Any]
        else { return data }
        let stats = resolve(&tools, mode: mode)
        guard stats.refs > 0 else { return data }
        root["tools"] = tools
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }

    /// A local API body with each request's tools resolved for its model's
    /// mode: one chat or Responses request, or every item of a chat batch.
    /// Bodies without `"tools"` and `"$ref"`, and models whose mode is off,
    /// keep their bytes.
    static func resolveLocalBody(
        _ data: Data, batch: Bool, modeFor: @Sendable (String) async -> ToolSchemaRefMode
    ) async -> Data {
        guard data.count <= ToolSchemaNormalization.maxNormalizationBytes,
            data.range(of: Data("\"$ref\"".utf8)) != nil, data.range(of: Data("\"tools\"".utf8)) != nil,
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return data }
        if !batch {
            guard let model = (parsed as? [String: Any])?["model"] as? String else { return data }
            return resolveBody(data, mode: await modeFor(model))
        }
        guard var items = parsed as? [Any] else { return data }
        let work = Work()
        var changed = false
        for index in items.indices {
            guard var item = items[index] as? [String: Any], let model = item["model"] as? String,
                var tools = item["tools"] as? [Any]
            else { continue }
            let mode = await modeFor(model)
            guard mode != .off, resolve(&tools, mode: mode, work: work).refs > 0 else { continue }
            item["tools"] = tools
            items[index] = item
            changed = true
        }
        guard changed else { return data }
        return (try? JSONSerialization.data(withJSONObject: items)) ?? data
    }

    /// Rewrites the `$ref` nodes of every schema home of `tools`
    /// (`function.parameters`, top-level `parameters`, `input_schema`) for
    /// `mode` and counts them. Never fails: what it cannot resolve it types.
    @discardableResult
    static func resolve(_ tools: inout [Any], mode: ToolSchemaRefMode, work: Work = Work()) -> ToolSchemaRefStats {
        var total = ToolSchemaRefStats()
        var slots: [(tool: Int, path: [String])] = []
        for (index, tool) in tools.enumerated() {
            for path in schemaHomes(tool) {
                if let schema = value(in: tool, at: path) as? [String: Any], hasRefs(schema) {
                    slots.append((index, path))
                }
            }
        }
        func root(_ slot: (tool: Int, path: [String])) -> [String: Any] {
            value(in: tools[slot.tool], at: slot.path) as? [String: Any] ?? [:]
        }
        func store(_ slot: (tool: Int, path: [String]), _ schema: [String: Any]) {
            tools[slot.tool] = replacing(tools[slot.tool], at: slot.path, with: schema)
        }
        /// The slot's pointers and its cyclic keys (nil past the cycle search's bounds).
        func prepare(_ slot: (tool: Int, path: [String])) -> (pointers: Pointers, cyclic: Set<String>?) {
            let pointers = Pointers(root(slot))
            work.addRoot()
            return (pointers, cyclicKeys(pointers, work))
        }
        switch mode {
        case .off:
            for slot in slots {
                forEachRef(root(slot)) { _ in
                    total.refs += 1
                    total.off += 1
                }
            }
            return total
        case .typed:
            for slot in slots {
                let (pointers, cyclic) = prepare(slot)
                store(slot, typeRefs(pointers, cyclic, work, stats: &total, keptBounds: false))
            }
            return total
        case .inline:
            break
        }
        let roots = slots.map(prepare)
        var plans: [(schema: [String: Any], stats: ToolSchemaRefStats, bytes: Int)?] = []
        var requestNodes = 0
        var requestBytes = 0
        for (pointers, cyclic) in roots {
            guard let cyclic, let plan = inlineRefs(pointers, cyclic, work), plan.stats.inlined > 0 else {
                plans.append(nil)
                continue
            }
            let nodes = countNodes(plan.schema)
            if nodes <= maxNodes, depth(plan.schema) <= maxDepth {
                plans.append(plan)
                requestNodes += nodes
                requestBytes += plan.bytes
            } else {
                plans.append(nil)
            }
        }
        let requestFits = requestNodes <= maxRequestNodes && requestBytes <= maxRequestBytes
            && work.spendBytes(requestBytes)
        for (index, slot) in slots.enumerated() {
            if let plan = plans[index], requestFits {
                store(slot, plan.schema)
                total.add(plan.stats)
            } else {
                let (pointers, cyclic) = roots[index]
                store(slot, typeRefs(pointers, cyclic, work, stats: &total, keptBounds: true))
            }
        }
        return total
    }

    // MARK: - Schema homes

    /// normalizeToolEntry's three homes (coordinator toolschema.go).
    private static func schemaHomes(_ tool: Any) -> [[String]] {
        guard let dict = tool as? [String: Any] else { return [] }
        var homes: [[String]] = []
        if let function = dict["function"] as? [String: Any] {
            if function["parameters"] != nil { homes.append(["function", "parameters"]) }
        } else if dict["parameters"] != nil {
            homes.append(["parameters"])
        }
        if dict["input_schema"] != nil { homes.append(["input_schema"]) }
        return homes
    }

    private static func value(in node: Any, at path: [String]) -> Any? {
        var current: Any? = node
        for key in path { current = (current as? [String: Any])?[key] }
        return current
    }

    private static func replacing(_ node: Any, at path: [String], with value: Any) -> Any {
        guard let key = path.first, var dict = node as? [String: Any] else { return value }
        dict[key] = path.count == 1 ? value : replacing(dict[key] as Any, at: Array(path.dropFirst()), with: value)
        return dict
    }

    // MARK: - Schema positions

    private static let schemaOne = [
        "additionalProperties", "additionalItems", "contains", "not", "if", "then", "else",
        "propertyNames", "unevaluatedItems", "unevaluatedProperties", "contentSchema",
    ]
    private static let schemaList = ["anyOf", "oneOf", "allOf", "prefixItems"]
    private static let schemaMap = ["properties", "patternProperties", "dependentSchemas", "dependencies"]
    private static let defKeys = ["$defs", "definitions"]

    private static func schemaChildren(_ node: [String: Any], _ body: (Any) -> Void) {
        if let items = node["items"] as? [String: Any] {
            body(items)
        } else if let items = node["items"] as? [Any] {
            items.forEach(body)
        }
        for key in schemaOne {
            if let child = node[key] as? [String: Any] { body(child) }
        }
        for key in schemaList {
            if let list = node[key] as? [Any] { list.forEach(body) }
        }
        for key in schemaMap {
            if let children = node[key] as? [String: Any] {
                for child in children.values where child is [String: Any] { body(child) }
            }
        }
    }

    private static func refOf(_ node: Any?) -> String? {
        (node as? [String: Any])?["$ref"] as? String
    }

    private static func forEachRef(_ node: Any?, _ body: (String) -> Void) {
        guard let dict = node as? [String: Any] else { return }
        if let ref = refOf(dict) { body(ref) }
        schemaChildren(dict) { forEachRef($0, body) }
    }

    private static func hasRefs(_ root: [String: Any]) -> Bool {
        var found = false
        forEachRef(root) { _ in found = true }
        return found
    }

    // MARK: - Pointers

    /// The canonical key ("#", "#/a/b") and decoded tokens of a same-document
    /// JSON pointer; nil for remote URIs, plain-name anchors and malformed
    /// escapes.
    static func canonicalRef(_ ref: String) -> (key: String, tokens: [String])? {
        guard ref.utf8.count <= maxPointerBytes, ref.hasPrefix("#") else { return nil }
        let fragment = ref.dropFirst()
        if fragment.isEmpty { return ("#", []) }
        guard fragment.hasPrefix("/") else { return nil }
        let parts = fragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= maxPointerTokens else { return nil }
        var tokens: [String] = []
        var key = "#"
        for part in parts {
            guard let decoded = percentDecode(String(part)) else { return nil }
            let token = decoded.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            tokens.append(token)
            key += "/" + escapeToken(token)
        }
        return (key, tokens)
    }

    private static func escapeToken(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// Strict %XX decoding; nil when an escape is malformed or the bytes are
    /// not UTF-8.
    private static func percentDecode(_ text: String) -> String? {
        guard text.contains("%") else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "%") else {
                out.append(bytes[index])
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
            else { return nil }
            out.append(high << 4 | low)
            index += 3
        }
        return String(bytes: out, encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// One schema root's pointers, each resolved once: a reference repeated
    /// at many sites, or spelled several ways, costs one parse and one lookup.
    private final class Pointers {
        struct Target {
            let key: String
            let value: Any
            /// An object or a boolean. Anything else (a string, number, array
            /// or null) is kept unresolved, as the coordinator does.
            let isSchema: Bool
            let object: [String: Any]?
        }

        let root: [String: Any]
        private let rootObject: NSDictionary
        private var byRef: [String: Target?] = [:]
        private var byKey: [String: Target?] = [:]
        /// The types found for targets without a cut-off on the way, with the
        /// references followed to find each: reused where those hops fit
        /// under `maxChainHops` from the asking reference, so the result
        /// doesn't depend on which reference was typed first.
        var types: [String: (type: String, hops: Int)] = [:]
        private var sizes: [String: Int] = [:]

        init(_ root: [String: Any]) {
            self.root = root
            rootObject = root as NSDictionary
        }

        func target(_ ref: String) -> Target? {
            // UTF-16 length first: O(1) for a JSONSerialization string, so an
            // over-long pointer is never hashed into the memo.
            guard ref.utf16.count <= maxPointerBytes else { return nil }
            if let known = byRef[ref] { return known }
            let found = canonicalRef(ref).flatMap { lookup($0.key, $0.tokens) }
            byRef[ref] = found
            return found
        }

        /// The text an inline of `target` copies, once a target.
        func bytes(of target: Target) -> Int {
            if let known = sizes[target.key] { return known }
            let size = textBytes(target.value)
            sizes[target.key] = size
            return size
        }

        private func lookup(_ key: String, _ tokens: [String]) -> Target? {
            if let known = byKey[key] { return known }
            // Foundation lookups: a value JSONSerialization made is an
            // NSDictionary or NSArray, and casting one to a Swift collection
            // copies it, so a pointer into a large `$defs` would cost its size
            // on every lookup. Keys compare as stored (no Unicode
            // normalization), as in the coordinator.
            var node: Any? = rootObject
            for token in tokens {
                if let dict = node as? NSDictionary {
                    node = dict.object(forKey: token)
                } else if let list = node as? NSArray, let index = arrayIndex(token), index < list.count {
                    node = list.object(at: index)
                } else {
                    node = nil
                }
                if node == nil { break }
            }
            let found = node.map { value -> Target in
                let isObject = value is NSDictionary
                return Target(key: key, value: value, isSchema: isObject || isBoolean(value),
                    object: isObject ? value as? [String: Any] : nil)
            }
            byKey[key] = found
            return found
        }
    }

    private static func arrayIndex(_ token: String) -> Int? {
        guard !token.isEmpty, token.utf8.allSatisfy({ (48...57).contains($0) }),
            token == "0" || !token.hasPrefix("0")
        else { return nil }
        return Int(token)
    }

    /// Pointer keys on a reference cycle (Tarjan over pointer -> pointers
    /// referenced inside its target); nil past `maxGraphTargets` or once the
    /// request has walked `maxRequestVisits` values.
    private static func cyclicKeys(_ pointers: Pointers, _ work: Work) -> Set<String>? {
        var graph: [String: [String]] = [:]
        var visits = 0
        guard var todo = refKeys(in: pointers.root, pointers, work, &visits) else { return nil }
        while let key = todo.popLast() {
            if graph[key] != nil { continue }
            guard graph.count < maxGraphTargets,
                let edges = refKeys(in: pointers.target(key)?.value, pointers, work, &visits)
            else { return nil }
            graph[key] = edges
            todo.append(contentsOf: edges)
        }
        // Tarjan's algorithm with an explicit stack: a reference graph is as
        // deep as its longest chain, which the input's nesting does not bound.
        var index: [String: Int] = [:]
        var low: [String: Int] = [:]
        var onStack: Set<String> = []
        var stack: [String] = []
        var next = 0
        var cyclic: Set<String> = []
        for start in graph.keys.sorted() where index[start] == nil {
            var frames: [(node: String, edge: Int)] = [(start, 0)]
            index[start] = next
            low[start] = next
            next += 1
            stack.append(start)
            onStack.insert(start)
            while let frame = frames.last {
                let v = frame.node
                let edges = graph[v] ?? []
                if frame.edge < edges.count {
                    frames[frames.count - 1].edge += 1
                    let w = edges[frame.edge]
                    if index[w] == nil {
                        index[w] = next
                        low[w] = next
                        next += 1
                        stack.append(w)
                        onStack.insert(w)
                        frames.append((w, 0))
                    } else if onStack.contains(w) {
                        low[v] = min(low[v]!, index[w]!)
                    }
                    continue
                }
                frames.removeLast()
                if let parent = frames.last?.node { low[parent] = min(low[parent]!, low[v]!) }
                guard low[v] == index[v] else { continue }
                var component: [String] = []
                while let w = stack.popLast() {
                    onStack.remove(w)
                    component.append(w)
                    if w == v { break }
                }
                if component.count > 1 || edges.contains(v) {
                    cyclic.formUnion(component)
                }
            }
        }
        return cyclic
    }

    /// The keys of the resolvable references in `node`'s schema positions,
    /// walked without recursion; nil once the request has walked
    /// `maxRequestVisits` values.
    private static func refKeys(
        in node: Any?, _ pointers: Pointers, _ work: Work, _ rootVisits: inout Int
    ) -> [String]? {
        var keys: [String] = []
        var pending: [Any] = node.map { [$0] } ?? []
        while let next = pending.popLast() {
            rootVisits += 1
            guard rootVisits <= maxRootVisits, work.spendVisit() else { return nil }
            guard let dict = next as? [String: Any] else { continue }
            if let ref = refOf(dict), let target = pointers.target(ref) { keys.append(target.key) }
            schemaChildren(dict) { pending.append($0) }
        }
        return keys
    }

    // MARK: - Types of kept references

    /// The type a kept `$ref` node is given: its target's, following reference
    /// chains; "object" for an unknown, recursive or boolean target or one
    /// that gives no evidence. Never the repair's "string" default. `exact` is
    /// false when a cut-off (a cycle, `maxChainHops`, the request's lookups)
    /// decided it; only exact types are remembered.
    private static func refType(
        _ pointers: Pointers, _ ref: String, _ work: Work, _ seen: Set<String> = []
    ) -> (type: String, exact: Bool, hops: Int) {
        guard seen.count < maxChainHops, work.spendLookups() else { return ("object", false, 0) }
        guard let target = pointers.target(ref) else { return ("object", true, 1) }
        if let known = pointers.types[target.key], seen.count + known.hops <= maxChainHops {
            return (known.type, true, known.hops)
        }
        guard !seen.contains(target.key) else { return ("object", false, 0) }
        guard let object = target.object else { return ("object", true, 1) }
        let found = typeOf(pointers, object, work, seen.union([target.key]))
        let hops = found.hops + 1
        if found.exact { pointers.types[target.key] = (found.type, hops) }
        return (found.type, found.exact, hops)
    }

    private static func typeOf(
        _ pointers: Pointers, _ node: [String: Any], _ work: Work, _ seen: Set<String>
    ) -> (type: String, exact: Bool, hops: Int) {
        if let type = node["type"] as? String { return (type, true, 0) }
        if let members = node["type"] as? [Any] {
            for case let member as String in members where member.lowercased() != "null" { return (member, true, 0) }
        }
        if let ref = refOf(node) { return refType(pointers, ref, work, seen) }
        if ["properties", "patternProperties", "additionalProperties"].contains(where: { node[$0] != nil }) {
            return ("object", true, 0)
        }
        if ["items", "prefixItems"].contains(where: { node[$0] != nil }) { return ("array", true, 0) }
        // A member that types `null` is skipped, but the hops it took count:
        // the remembered type must not be reused where they wouldn't fit.
        var consulted = 0
        for key in ["anyOf", "oneOf", "allOf"] {
            let members = node[key] as? [Any] ?? []
            guard work.spendLookups(members.count / 64) else { return ("object", false, 0) }
            for case let member as [String: Any] in members {
                if let type = member["type"] as? String {
                    if type.lowercased() != "null" { return (type, true, consulted) }
                    continue
                }
                if let type = member["type"], !(type is NSNull) { continue }
                if let ref = refOf(member) {
                    let found = refType(pointers, ref, work, seen)
                    consulted = max(consulted, found.hops)
                    if found.type.lowercased() != "null" { return (found.type, found.exact, consulted) }
                }
            }
        }
        var values: [Any] = []
        if let constant = node["const"] {
            values = [constant]
        } else if let members = node["enum"] as? [Any] {
            values = members
        }
        guard work.spendLookups(values.count / 64) else { return ("object", false, consulted) }
        let kinds = Set(values.map(jsonKind)).subtracting(["null"])
        if kinds.count == 1, let kind = kinds.first { return (kind, true, consulted) }
        return ("object", true, consulted)
    }

    private static func jsonKind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if isBoolean(value) { return "boolean" }
        if value is NSNumber { return "number" }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "string"
    }

    private static func isBoolean(_ value: Any) -> Bool {
        if type(of: value) == Bool.self { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Rewrites

    /// Rebuilds `node`, applying `body` to every schema object reached through
    /// schema positions, children first; other keys are kept as they are.
    /// `level` is the schema nesting of `node` (the root is 0); `body` gets
    /// each object's.
    private static func walk(_ node: Any, level: Int = 0, _ body: ([String: Any], Int) -> Any) -> Any {
        guard let dict = node as? [String: Any] else { return node }
        let inner = level + 1
        var out: [String: Any] = [:]
        for (key, value) in dict {
            if key == "items", let items = value as? [String: Any] {
                out[key] = walk(items, level: inner, body)
            } else if key == "items", let items = value as? [Any] {
                out[key] = items.map { walk($0, level: inner, body) }
            } else if schemaOne.contains(key), let child = value as? [String: Any] {
                out[key] = walk(child, level: inner, body)
            } else if schemaList.contains(key), let list = value as? [Any] {
                out[key] = list.map { walk($0, level: inner, body) }
            } else if schemaMap.contains(key), let children = value as? [String: Any] {
                out[key] = children.mapValues { $0 is [String: Any] ? walk($0, level: inner, body) : $0 }
            } else {
                out[key] = value
            }
        }
        return body(out, level)
    }

    /// A kept `$ref` node, given its target's type when it has none.
    private static func withTargetType(
        _ node: [String: Any], _ ref: String, _ pointers: Pointers, _ work: Work
    ) -> [String: Any] {
        guard node["type"] == nil else { return node }
        var typed = node
        typed["type"] = refType(pointers, ref, work).type
        return typed
    }

    /// Gives every `$ref` node of the root without a type its target's type.
    private static func typeRefs(
        _ pointers: Pointers, _ cyclic: Set<String>?, _ work: Work, stats: inout ToolSchemaRefStats,
        keptBounds: Bool
    ) -> [String: Any] {
        var local = stats
        let out = walk(pointers.root) { node, _ in
            guard let ref = refOf(node) else { return node }
            local.refs += 1
            if let target = pointers.target(ref), target.isSchema {
                if cyclic?.contains(target.key) ?? false {
                    local.keptCyclic += 1
                } else if keptBounds || cyclic == nil {
                    local.keptBounds += 1
                } else {
                    local.typed += 1
                }
            } else {
                local.keptUnresolved += 1
            }
            return withTargetType(node, ref, pointers, work)
        }
        stats = local
        return out as? [String: Any] ?? pointers.root
    }

    /// Replaces every resolvable, non-recursive reference of the root with a
    /// copy of its target (its own references resolved alike, its `$defs`
    /// left out) merged with the reference's siblings; recursive and
    /// unresolvable references are typed. nil once the copied targets exceed
    /// `maxNodes` or an inline passes `maxChainHops` or `maxDepth`. After an
    /// inline, definitions no remaining reference reaches are dropped.
    private static func inlineRefs(
        _ pointers: Pointers, _ cyclic: Set<String>, _ work: Work
    ) -> (schema: [String: Any], stats: ToolSchemaRefStats, bytes: Int)? {
        var stats = ToolSchemaRefStats()
        var budget = 0
        var copied = 0
        var over = false
        // `hops`: references followed to reach `node`; `level`: its schema
        // nesting in the result. Past either bound the inline gives up (the
        // root is typed instead), so neither a chain of aliases nor a chain of
        // nested targets recurses without bound.
        func replace(_ node: Any, hops: Int, level: Int) -> Any {
            walk(node, level: level) { dict, level in
                guard let ref = refOf(dict), !over else { return dict }
                stats.refs += 1
                let target = pointers.target(ref)
                guard let target, target.isSchema, !cyclic.contains(target.key) else {
                    if target?.isSchema == true {
                        stats.keptCyclic += 1
                    } else {
                        stats.keptUnresolved += 1
                    }
                    return withTargetType(dict, ref, pointers, work)
                }
                stats.inlined += 1
                budget += countNodes(target.value)
                copied += pointers.bytes(of: target)
                if budget > maxNodes || copied > maxRootBytes || hops >= maxChainHops || level > maxDepth {
                    over = true
                    return dict
                }
                var body = replace(target.value, hops: hops + 1, level: level)
                if var bodyDict = body as? [String: Any] {
                    for key in defKeys { bodyDict.removeValue(forKey: key) }
                    body = bodyDict
                }
                var siblings = dict
                siblings.removeValue(forKey: "$ref")
                return merge(body, siblings)
            }
        }
        // A root reference's target lies among the root's other keys, so
        // `merge` keeps the result an object (a boolean target goes into
        // `allOf`); a result that is not an object is typed instead.
        guard var out = replace(pointers.root, hops: 0, level: 0) as? [String: Any], !over else { return nil }
        if stats.inlined == 0 { return (out, stats, copied) }
        pruneDefs(&out, pointers)
        return (out, stats, copied)
    }

    private static func pruneDefs(_ out: inout [String: Any], _ pointers: Pointers) {
        var live: Set<String> = []
        var todo: [String] = []
        forEachRef(out.filter { !defKeys.contains($0.key) }) { ref in
            if let target = pointers.target(ref) { todo.append(target.key) }
        }
        while let key = todo.popLast() {
            guard live.insert(key).inserted else { continue }
            forEachRef(pointers.target(key)?.value) { ref in
                if let target = pointers.target(ref) { todo.append(target.key) }
            }
        }
        // The definitions a live key points into, by their escaped name: one
        // pass over the live keys, then one over the definitions.
        var liveNames: [String: Set<Substring>] = [:]
        for key in live {
            for defKey in defKeys {
                let prefix = "#/" + defKey + "/"
                guard key.hasPrefix(prefix) else { continue }
                let rest = key.dropFirst(prefix.count)
                liveNames[defKey, default: []].insert(rest.prefix { $0 != "/" })
            }
        }
        for defKey in defKeys {
            guard let defs = out[defKey] as? [String: Any] else { continue }
            let names = liveNames[defKey] ?? []
            let kept = defs.filter { name, _ in names.contains(Substring(escapeToken(name))) }
            if kept.isEmpty {
                out.removeValue(forKey: defKey)
            } else {
                out[defKey] = kept
            }
        }
    }

    private static let annotationKeys: Set<String> = [
        "$anchor", "$comment", "$id", "$schema", "default", "deprecated",
        "description", "examples", "readOnly", "title", "writeOnly",
    ]

    /// A keyword whose meaning depends on other keywords of the same object.
    private static let dependsOn: [String: [String]] = [
        "additionalProperties": ["properties", "patternProperties"],
        "additionalItems": ["items", "prefixItems"],
        "items": ["prefixItems"],
        "then": ["if"],
        "else": ["if"],
        "minContains": ["contains"],
        "maxContains": ["contains"],
    ]
    private static let unevaluatedKeys = ["unevaluatedProperties", "unevaluatedItems"]

    /// Annotation siblings, or assertions that neither contradict the target
    /// nor sit next to a keyword that depends on its neighbours, merge into the
    /// target (the reference's annotations win); otherwise the `wrap`
    /// conjunction.
    private static func merge(_ target: Any, _ siblings: [String: Any]) -> Any {
        if siblings.isEmpty { return target }
        guard var dict = target as? [String: Any] else { return wrap(target, siblings) }
        let assertions = siblings.keys.filter { !annotationKeys.contains($0) }
        if !assertions.isEmpty {
            let conflict = assertions.contains { key in
                guard let existing = dict[key] else { return false }
                return !jsonEqual(existing, siblings[key]!)
            }
            if conflict || adjacent(dict, siblings) { return wrap(dict, siblings) }
        }
        for (key, value) in siblings { dict[key] = value }
        return dict
    }

    /// `{allOf:[target, ...the siblings' own allOf], ...the other siblings}`:
    /// the exact conjunction.
    private static func wrap(_ target: Any, _ siblings: [String: Any]) -> [String: Any] {
        var wrapped = siblings
        wrapped["allOf"] = [target] + (siblings["allOf"] as? [Any] ?? [])
        return wrapped
    }

    private static func adjacent(_ target: [String: Any], _ siblings: [String: Any]) -> Bool {
        for (keyword, providers) in dependsOn {
            if target[keyword] != nil, providers.contains(where: { siblings[$0] != nil }) { return true }
            if siblings[keyword] != nil, providers.contains(where: { target[$0] != nil }) { return true }
        }
        let nonAnnotation: ([String: Any]) -> Bool = { dict in dict.keys.contains { !annotationKeys.contains($0) } }
        if unevaluatedKeys.contains(where: { target[$0] != nil }), nonAnnotation(siblings) { return true }
        return unevaluatedKeys.contains(where: { siblings[$0] != nil }) && nonAnnotation(target)
    }

    /// JSON value equality; numbers by value, booleans never equal numbers.
    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? [String: Any] {
            guard let y = b as? [String: Any], x.count == y.count else { return false }
            return x.allSatisfy { key, value in y[key].map { jsonEqual(value, $0) } ?? false }
        }
        if let x = a as? [Any] {
            guard let y = b as? [Any], x.count == y.count else { return false }
            return zip(x, y).allSatisfy { jsonEqual($0, $1) }
        }
        if isBoolean(a) || isBoolean(b) {
            guard isBoolean(a), isBoolean(b) else { return false }
            return (a as? Bool) == (b as? Bool)
        }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x.isEqual(to: y) }
        if let x = a as? String, let y = b as? String { return x == y }
        return a is NSNull && b is NSNull
    }

    /// The text an inline of `value` copies, as the coordinator's byte caps
    /// count it (`refScalarBytes`): UTF-8 bytes of strings and keys, 4 or 5
    /// for a boolean, 4 for null, a number's decimal length. Measured once a
    /// target (`Pointers.bytes(of:)`).
    static func textBytes(_ value: Any) -> Int {
        let utf8 = String.Encoding.utf8.rawValue
        if let dict = value as? NSDictionary {
            var total = 0
            for (key, child) in dict { total += ((key as? NSString)?.lengthOfBytes(using: utf8) ?? 0) + textBytes(child) }
            return total
        }
        if let list = value as? NSArray { return list.reduce(0) { $0 + textBytes($1) } }
        if let text = value as? NSString { return text.lengthOfBytes(using: utf8) }
        if isBoolean(value) { return (value as? Bool) == true ? 4 : 5 }
        if value is NSNull { return 4 }
        if let number = value as? NSNumber { return number.stringValue.utf8.count }
        return 4
    }

    static func countNodes(_ value: Any) -> Int {
        if let dict = value as? [String: Any] { return 1 + dict.values.reduce(0) { $0 + countNodes($1) } }
        if let list = value as? [Any] { return 1 + list.reduce(0) { $0 + countNodes($1) } }
        return 1
    }

    static func depth(_ value: Any) -> Int {
        if let dict = value as? [String: Any] { return 1 + (dict.values.map(depth).max() ?? 0) }
        if let list = value as? [Any] { return 1 + (list.map(depth).max() ?? 0) }
        return 0
    }
}
