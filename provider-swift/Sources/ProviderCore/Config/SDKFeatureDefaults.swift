import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Provider defaults for feature switches the SDK reads from the process
/// environment (`libs/mlx-swift-lm` keeps every one of them opt-in).
///
/// A switch listed in `onByDefault` is turned on in every `darkbloom` process
/// (the `main.swift` entry, before any command runs, so single-Mac serving,
/// pair members, workers and benchmarks agree) unless the operator's
/// environment (the shell, or the LaunchAgent plist, which forwards each key)
/// already sets it to a non-empty value, so `<KEY>=0` stays the kill switch and
/// restores 0.10.12's behaviour. Keys the provider injected itself are never
/// written into a service plist (`LaunchAgent.passthroughEnvironment`), so an
/// installed service follows the running release's defaults. Unlisted switches
/// keep the SDK default (off).
public enum SDKFeatureDefaults {
    /// Switches proven on hardware for this release; see `docs/reference/configuration.md`.
    /// One list per feature, so each default flip is its own one-line change.
    public static let onByDefault: [String] =
        constraintSpans + grammarMTP + gemmaQuotedNumbers + reasoningBudgets

    /// #2101 / SDK #413: MTP drafting through free Qwen reasoning and text spans.
    static let constraintSpans: [String] = []

    /// SDK #409: grammar-aware MTP verification of constrained rows.
    static let grammarMTP: [String] = []

    /// #2090 / SDK #408: Gemma quoted numeric tool arguments typed by the schema.
    static let gemmaQuotedNumbers: [String] = []

    /// #2099 / SDK #411: Super / MiMo `reasoning.max_tokens` budgets.
    static let reasoningBudgets: [String] = []

    /// The keys to set for `environment`: every listed key it leaves unset or
    /// empty (an empty value is what the LaunchAgent drops, so it means unset).
    public static func projection(
        onByDefault: [String] = onByDefault, environment: [String: String]
    ) -> [String: String] {
        onByDefault.reduce(into: [:]) { out, key in
            if environment[key]?.isEmpty ?? true { out[key] = "1" }
        }
    }

    /// Apply the projection to this process and remember what it injected.
    /// Returns the keys it turned on, for the startup log.
    @discardableResult
    public static func apply(
        onByDefault: [String] = onByDefault,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let keys = projection(onByDefault: onByDefault, environment: environment)
        for (key, value) in keys { setenv(key, value, 1) }
        injected.add(keys.keys)
        return keys.keys.sorted()
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
