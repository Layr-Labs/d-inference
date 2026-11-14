import Foundation
import MLXLMCommon
#if canImport(Darwin)
import Darwin
#endif

/// Provider defaults for feature switches the SDK reads from the process
/// environment (`libs/mlx-swift-lm` keeps every one of them opt-in).
///
/// An operator value always wins: a switch the environment (the shell, or the
/// LaunchAgent plist, which forwards each key) sets to a non-empty value is the
/// SDK's to read, so `<KEY>=0` is the kill switch and restores 0.10.12's
/// behaviour on every model, and `1` turns a switch on for every model. A switch
/// left unset (or empty) follows this release's evidence, on only where it was
/// measured in its ON state:
///
/// - Per build: the slot factory turns `constraintSpansBuilds` and
///   `grammarMTPBuilds` on in that engine's `CBv2MTPConfig`
///   (`applyMTPDefaults`); `NativeReasoningBudget.isEnabled(for:)` admits
///   budgets for `reasoningBudgetFamilies` only.
/// - Process-wide (`onByDefault`, for what the SDK reads with no per-model
///   hook): set in every `darkbloom` process at the `main.swift` entry, before
///   any command runs. A key a `darkbloom` process injected, including a
///   parent's (`injectedMarkerKey`), is never the operator's: it is not written
///   into a service plist (`LaunchAgent.passthroughEnvironment`), so an
///   installed service follows the running release's defaults.
public enum SDKFeatureDefaults {
    /// #2090 / SDK #408: Gemma quoted numeric tool arguments typed by the
    /// schema. One process-wide parser switch (`GemmaFunctionParser`).
    static let gemmaQuotedNumbers: [String] = []

    /// #2101 / SDK #413: MTP drafting through free Qwen reasoning and text
    /// spans. A build is a `model_type` or a case-insensitive model-id part.
    static let constraintSpansBuilds: Set<String> = []

    /// SDK #409: grammar-aware MTP verification of constrained rows (builds as above).
    static let grammarMTPBuilds: Set<String> = []

    /// #2099 / SDK #411: `reasoning.max_tokens` budgets, per family.
    static let reasoningBudgetFamilies: Set<NativeReasoningBudget.Family> = [.nemotronSuper]

    /// The process-wide switches. With a budget family listed, the budget
    /// switch is set too, so every engine accepts budget rows; only
    /// `NativeReasoningBudget.isEnabled(for:)` admits a request's budget.
    public static let onByDefault: [String] =
        gemmaQuotedNumbers + (reasoningBudgetFamilies.isEmpty ? [] : [NativeReasoningBudget.environmentKey])

    static let constraintSpansKey = "DARKBLOOM_CONSTRAINT_SPANS"
    static let grammarMTPKey = "DARKBLOOM_CBV2_MTP_GRAMMAR"

    /// Inherited by child processes and never forwarded to a plist: the keys a
    /// `darkbloom` process injected, so a `darkbloom` child (the desktop app's
    /// workers, a cluster service's parts) does not take them for the operator's.
    public static let injectedMarkerKey = "DARKBLOOM_SDK_DEFAULTS_INJECTED"

    /// Whether `key` follows this release's default: unset, empty (what the
    /// LaunchAgent drops, so foreground and service agree) or injected.
    static func followsDefault(_ key: String, in environment: [String: String],
                               injected: Set<String> = injectedKeys) -> Bool {
        injected.contains(key) || (environment[key]?.isEmpty ?? true)
    }

    /// `builds` holds `model_type`s or case-insensitive model-id parts, as
    /// `DARKBLOOM_STRICT_TOOL_GRAMMAR` lists do (`qwen3.8-27b`).
    static func matches(_ builds: Set<String>, modelId: String, modelType: String?) -> Bool {
        let id = modelId.lowercased(), type = modelType?.lowercased()
        return builds.contains { $0 == type || id.contains($0) }
    }

    /// The per-build MTP defaults for one engine. `config` holds the SDK's
    /// reading of the environment (the operator's value; off when unset); a
    /// switch left unset is turned on for the listed builds only. Returns the
    /// switches it turned on, for the load log.
    @discardableResult
    static func applyMTPDefaults(
        to config: inout CBv2MTPConfig, modelId: String, modelType: String?,
        environment: [String: String],
        spansBuilds: Set<String> = constraintSpansBuilds, grammarBuilds: Set<String> = grammarMTPBuilds
    ) -> [String] {
        var on: [String] = []
        if followsDefault(constraintSpansKey, in: environment, injected: []),
           matches(spansBuilds, modelId: modelId, modelType: modelType) {
            config.freeSpanSpeculation = true
            on.append(constraintSpansKey)
        }
        if followsDefault(grammarMTPKey, in: environment, injected: []),
           matches(grammarBuilds, modelId: modelId, modelType: modelType) {
            config.constrainedSpeculation = true
            on.append(grammarMTPKey)
        }
        return on
    }

    /// The keys to set for `environment`: every listed key it leaves unset or
    /// empty (an empty value is what the LaunchAgent drops, so it means unset).
    public static func projection(
        onByDefault: [String] = onByDefault, environment: [String: String]
    ) -> [String: String] {
        onByDefault.reduce(into: [:]) { out, key in
            if environment[key]?.isEmpty ?? true { out[key] = "1" }
        }
    }

    /// What `apply` changes in a process environment.
    struct Plan: Equatable {
        var set: [String: String] = [:]
        var unset: [String] = []
        /// The switches this release turned on, not the operator; sorted.
        var injected: [String] = []
    }

    /// A key a parent `darkbloom` injected (named in its marker, value still
    /// `1`) counts as unset, so this release's list decides it again: re-set
    /// and recorded as injected if listed, unset if not. Every listed key the
    /// environment leaves unset or empty is turned on; the marker names them.
    static func plan(onByDefault: [String] = onByDefault, environment: [String: String]) -> Plan {
        let inherited = Set((environment[injectedMarkerKey] ?? "").split(separator: ",").map(String.init))
            .filter { environment[$0] == "1" }
        var operatorEnvironment = environment
        for key in inherited { operatorEnvironment[key] = nil }
        var changes = Plan(set: projection(onByDefault: onByDefault, environment: operatorEnvironment))
        changes.injected = changes.set.keys.sorted()
        changes.unset = inherited.subtracting(changes.injected).sorted()
        if !changes.injected.isEmpty {
            changes.set[injectedMarkerKey] = changes.injected.joined(separator: ",")
        } else if environment[injectedMarkerKey] != nil {
            changes.unset.append(injectedMarkerKey)
        }
        return changes
    }

    /// Apply the plan to this process and remember what it injected.
    /// Returns the keys it turned on.
    @discardableResult
    public static func apply(
        onByDefault: [String] = onByDefault,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let changes = plan(onByDefault: onByDefault, environment: environment)
        for (key, value) in changes.set { setenv(key, value, 1) }
        for key in changes.unset { unsetenv(key) }
        injected.add(changes.injected)
        return changes.injected
    }

    /// The `start` / `benchmark` line naming what is on by default (and for
    /// which builds or families); nil if nothing.
    public static func summary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        injected: Set<String> = injectedKeys
    ) -> String? {
        var on = injected.sorted().map { key in
            key == NativeReasoningBudget.environmentKey
                ? "\(key) (\(reasoningBudgetFamilies.map { "\($0)" }.sorted().joined(separator: ", ")))" : key
        }
        for (key, builds) in [(constraintSpansKey, constraintSpansBuilds), (grammarMTPKey, grammarMTPBuilds)]
        where !builds.isEmpty && followsDefault(key, in: environment, injected: []) {
            on.append("\(key) (\(builds.sorted().joined(separator: ", ")))")
        }
        return on.isEmpty ? nil : "SDK feature defaults on: \(on.joined(separator: "; "))"
    }

    /// Keys this process set itself (not the operator's): never persisted.
    public static var injectedKeys: Set<String> { injected.all }

    private static let injected = InjectedKeys()

    private final class InjectedKeys: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String> = []
        func add(_ new: some Sequence<String>) { lock.lock(); keys.formUnion(new); lock.unlock() }
        var all: Set<String> { lock.lock(); defer { lock.unlock() }; return keys }
    }
}
