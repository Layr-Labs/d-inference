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
    /// 27B, inlined. Every other model keeps the legacy repair.
    static let defaultRules = [
        Rule(pattern: "gemma-4-26b", mode: .inline),
        Rule(pattern: "qwen3.8-27b", mode: .inline),
    ]

    static let `default` = ToolSchemaRefPolicy(rules: defaultRules)

    let rules: [Rule]

    init(rules: [Rule]) {
        self.rules = rules.compactMap { rule in
            let pattern = rule.pattern.trimmingCharacters(in: .whitespaces).lowercased()
            return pattern.isEmpty ? nil : Rule(pattern: pattern, mode: rule.mode)
        }
    }

    /// Parses the coordinator's EIGENINFERENCE_TOOLSCHEMA_REF_RESOLVE_MODELS
    /// syntax: comma-separated patterns, each optionally "=inline" (the
    /// default) or "=typed". Unset or blank keeps the default; "off" or
    /// "none" lists none. `valid == false` means the value named no pattern,
    /// held a boolean, an empty pattern or an unknown mode, or mixed "off" with
    /// patterns; the default is kept.
    static func parse(_ raw: String?) -> (policy: ToolSchemaRefPolicy, valid: Bool) {
        let value = (raw ?? "").trimmingCharacters(in: .whitespaces)
        switch value.lowercased() {
        case "": return (.default, true)
        case "off", "none": return (ToolSchemaRefPolicy(rules: []), true)
        default: break
        }
        var rules: [Rule] = []
        for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
            let item = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if item.isEmpty { continue }
            var pattern = item
            var mode = ToolSchemaRefMode.inline
            if let equals = item.firstIndex(of: "=") {
                pattern = String(item[..<equals]).trimmingCharacters(in: .whitespaces)
                switch item[item.index(after: equals)...].trimmingCharacters(in: .whitespaces) {
                case "inline": mode = .inline
                case "typed": mode = .typed
                default: return (.default, false)
                }
            }
            if pattern.isEmpty || booleanSpellings.contains(pattern) {
                return (.default, false)
            }
            rules.append(Rule(pattern: pattern, mode: mode))
        }
        return rules.isEmpty ? (.default, false) : (ToolSchemaRefPolicy(rules: rules), true)
    }

    /// Go's strconv.ParseBool spellings plus the words the coordinator's
    /// parsers also refuse as a pattern.
    private static let booleanSpellings: Set<String> = [
        "1", "t", "true", "0", "f", "false", "on", "yes", "no", "y", "n", "off", "none",
    ]

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
        var changed = false
        for index in items.indices {
            guard var item = items[index] as? [String: Any], let model = item["model"] as? String,
                var tools = item["tools"] as? [Any]
            else { continue }
            let mode = await modeFor(model)
            guard mode != .off, resolve(&tools, mode: mode).refs > 0 else { continue }
            item["tools"] = tools
            items[index] = item
            changed = true
        }
        guard changed else { return data }
        return (try? JSONSerialization.data(withJSONObject: items)) ?? data
    }

    /// Rewrites the `$ref` nodes of every schema home of `tools` for `mode`
    /// and counts them. Not implemented yet: every mode leaves the tools as
    /// the repair receives them.
    @discardableResult
    static func resolve(_ tools: inout [Any], mode: ToolSchemaRefMode) -> ToolSchemaRefStats {
        ToolSchemaRefStats()
    }
}
