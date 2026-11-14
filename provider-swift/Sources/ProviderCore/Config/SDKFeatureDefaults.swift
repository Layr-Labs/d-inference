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
    static let gemmaQuotedNumbers: [String] = ["DARKBLOOM_GEMMA_SCHEMA_COERCION"]

    /// #2101 / SDK #413: MTP drafting through free Qwen reasoning and text
    /// spans. A build is an exact model id, lowercased (`matches`).
    static let constraintSpansBuilds: Set<String> = ["eigenlabs/qwen3.8-27b-4bit-mtp"]

    /// SDK #409: grammar-aware MTP verification of constrained rows, on a
    /// listed build only where constraint spans are on (measured together).
    static let grammarMTPBuilds: Set<String> = ["eigenlabs/qwen3.8-27b-4bit-mtp"]

    /// #2099 / SDK #411: `reasoning.max_tokens` budgets, per family.
    static let reasoningBudgetFamilies: Set<NativeReasoningBudget.Family> = []

    /// The process-wide switches. With a budget family listed, the budget
    /// switch is set too, so every engine accepts budget rows; only
    /// `NativeReasoningBudget.isEnabled(for:)` admits a request's budget.
    public static let onByDefault: [String] =
        gemmaQuotedNumbers + (reasoningBudgetFamilies.isEmpty ? [] : [NativeReasoningBudget.environmentKey])
        + gemmaReopenedThoughts

    /// #2089 / SDK #407: reopened Gemma 4 thoughts go to reasoning and stray
    /// closes are absorbed. One process-wide parser switch
    /// (`StreamingGemma4ReasoningParser`), with no per-model hook.
    static let gemmaReopenedThoughts: [String] = ["DARKBLOOM_GEMMA_REOPENED_THOUGHTS"]

    static let constraintSpansKey = "DARKBLOOM_CONSTRAINT_SPANS"
    static let grammarMTPKey = "DARKBLOOM_CBV2_MTP_GRAMMAR"

    /// Inherited by child processes and never forwarded to a plist: the keys a
    /// `darkbloom` process injected, so a `darkbloom` child (the desktop app's
    /// workers, a cluster service's parts) does not take them for the operator's.
    public static let injectedMarkerKey = "DARKBLOOM_SDK_DEFAULTS_INJECTED"

    /// Every key this mechanism may set process-wide, whatever a release
    /// lists; a marker naming any other key is not trusted.
    static let injectableKeys: Set<String> = [
        "DARKBLOOM_GEMMA_SCHEMA_COERCION", NativeReasoningBudget.environmentKey, "DARKBLOOM_GEMMA_REOPENED_THOUGHTS",
    ]

    /// The keys a parent `darkbloom` injected: named in `environment`'s marker,
    /// injectable, with the value still `1`.
    static func inherited(_ environment: [String: String]) -> Set<String> {
        Set((environment[injectedMarkerKey] ?? "").split(separator: ",").map(String.init))
            .filter { injectableKeys.contains($0) && environment[$0] == "1" }
    }

    /// Whether `key`'s value is the release's (this process's, or a parent's
    /// per the marker, so a process that never ran `apply` knows too), not the
    /// operator's.
    static func isInjected(_ key: String, in environment: [String: String],
                           injected: Set<String> = injectedKeys) -> Bool {
        injected.contains(key) || inherited(environment).contains(key)
    }

    /// Whether `key` follows this release's default: unset, empty (what the
    /// LaunchAgent drops, so foreground and service agree) or injected.
    static func followsDefault(_ key: String, in environment: [String: String],
                               injected: Set<String> = injectedKeys) -> Bool {
        (environment[key]?.isEmpty ?? true) || isInjected(key, in: environment, injected: injected)
    }

    /// Whether `modelId` is exactly one of `builds` (lowercased model ids): a
    /// default never reaches another quantization, a fine-tune or a local path.
    static func matches(_ builds: Set<String>, modelId: String) -> Bool {
        builds.contains(modelId.lowercased())
    }

    /// The per-build MTP defaults for one engine. `config` holds the SDK's
    /// reading of the environment (the operator's value; off when unset); a
    /// switch left unset, in the slot's environment and in the process's (what
    /// the SDK read), is turned on for the listed builds only, grammar MTP only
    /// where constraint spans are on (measured together). Returns the switches
    /// it turned on, for the load log.
    @discardableResult
    static func applyMTPDefaults(
        to config: inout CBv2MTPConfig, modelId: String, environment: [String: String],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        spansBuilds: Set<String> = constraintSpansBuilds, grammarBuilds: Set<String> = grammarMTPBuilds
    ) -> [String] {
        func unset(_ key: String) -> Bool {
            followsDefault(key, in: environment, injected: [])
                && followsDefault(key, in: processEnvironment, injected: [])
        }
        var on: [String] = []
        if unset(constraintSpansKey), matches(spansBuilds, modelId: modelId) {
            config.freeSpanSpeculation = true
            on.append(constraintSpansKey)
        }
        if unset(grammarMTPKey), config.freeSpanSpeculation, matches(grammarBuilds, modelId: modelId) {
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
        let fromParent = inherited(environment)
        var operatorEnvironment = environment
        for key in fromParent { operatorEnvironment[key] = nil }
        var changes = Plan(set: projection(onByDefault: onByDefault, environment: operatorEnvironment))
        changes.injected = changes.set.keys.sorted()
        changes.unset = fromParent.subtracting(changes.injected).sorted()
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
        summary(environment: environment, injected: injected,
                spansBuilds: constraintSpansBuilds, grammarBuilds: grammarMTPBuilds)
    }

    static func summary(environment: [String: String], injected: Set<String>,
                        spansBuilds: Set<String>, grammarBuilds: Set<String>) -> String? {
        var on = injected.sorted().map { key in
            key == NativeReasoningBudget.environmentKey
                ? "\(key) (\(reasoningBudgetFamilies.map { "\($0)" }.sorted().joined(separator: ", ")))" : key
        }
        for (key, builds, scope) in [(constraintSpansKey, spansBuilds, ""),
                                     (grammarMTPKey, grammarBuilds, ", where constraint spans are on")]
        where !builds.isEmpty && followsDefault(key, in: environment, injected: []) {
            on.append("\(key) (\(builds.sorted().joined(separator: ", "))\(scope))")
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
