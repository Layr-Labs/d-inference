// Copyright © 2026 Eigen Labs.
//
// Recursive normalizer that strips values the Jinja value bridge
// (`swift-jinja`'s `Value.init(any:)`) cannot represent, BEFORE they reach
// a chat-template render.
//
// Background: `Jinja.Value.init(any:)` is null-blind. Its switch
// handles `Value`, `nil`, `String`, `Int`, `Double`, `Float`, `Bool`,
// `[Any?]`, `[String: Any?]`, and `Macro`; EVERYTHING else hits the
// `default` branch and throws
// `JinjaError.runtime("Cannot convert value of type … to Jinja Value")`.
// Three leaf kinds that legitimately occur in OpenAI chat-completions
// requests land in that default branch and surface to consumers as hard
// 500s (`Jinja.TemplateException error 1`):
//
//   1. `NSNull` — produced by `JSONSerialization` / `asSendable` when an
//      assistant tool call's `function.arguments` carries a JSON `null`
//      (e.g. `{"location": null}`), via `decodeToolCallArguments`.
//   2. `JSONNull` — a `private` empty struct in MLXLMServer's
//      `OpenAIProtocol.swift`, produced by `JSONValue.sendableValue` when a
//      tool's `function.parameters` JSON-schema carries a JSON `null`
//      (e.g. `"default": null`, `"const": null`, a `null` enum element),
//      via `OpenAITool.toolSpec()`.
//   3. A non-nil Swift `Optional` boxed inside `Any` — e.g. a `String?`
//      coerced to `Any` leaks `Optional<Wrapped>` into the bridge, which
//      has no matching case.
//
// gpt-oss / Harmony is the most exposed model because its requests
// routinely carry tools + tool-call history; live telemetry showed ~97%
// of the 500-class errors carried tools.
//
// Normalization policy: DROP. Dictionary entries whose value is a null
// sentinel are removed; null elements are removed from arrays; non-nil
// Optionals are unwrapped to their payload. Chat templates read optional
// fields defensively (`if key is defined` / `.get(key)` / `| default(…)`),
// so a *missing* key renders identically to an explicit JSON `null` while
// sidestepping the bridge crash. Every NON-null leaf is returned verbatim
// — the exact same value and dynamic type (`__NSCFBoolean`, `__NSCFNumber`,
// native `Int`, …) — so Jinja renders surviving data byte-for-byte as
// before; array element order is preserved.
//
// Placement: this module is intentionally dependency-free (Foundation
// only) and lives in ProviderCoreFoundation — the lower, Linux-buildable
// target — so that BOTH the runtime chat-template chokepoints in
// `ProviderCore/Inference` AND the scan-time render self-check
// (`TemplateRenderCheck`, same target) share ONE implementation. Keeping
// "renders in the self-check" == "renders at request time" is exactly the
// invariant whose violation let the original null-bridge crash escape the
// guard, so the sanitizer must not be duplicated across the two layers.

import Foundation

/// Recursively strip Jinja-unrepresentable null / `Optional` leaves from an
/// arbitrary value tree.
///
/// Returns the value re-typed as `Any?` (not `any Sendable` — `Sendable` is
/// a marker protocol that cannot participate in a runtime cast). The
/// chat-template adapters in ProviderCore re-wrap the result into the
/// `[String: any Sendable]` shape `applyChatTemplate` expects; the
/// scan-time self-check feeds it straight to `Jinja.Value(any:)`, which
/// already takes `Any?`.
///
/// - Parameter value: any node of a messages / tools value tree.
/// - Returns: the sanitized value, or `nil` when `value` itself reduces to
///   a null sentinel or `Optional.none` (callers drop such entries /
///   elements).
public func sanitizeForJinja(_ value: Any?) -> Any? {
    // A true Swift `nil` at the `Any?` boundary.
    guard let value else { return nil }

    // Collapse any `Optional` boxed inside `Any`. `Mirror` reports
    // `.optional` for both `.some` and `.none`: a `.none` has zero children
    // (drop it); a `.some` has exactly one child (unwrap and recurse so the
    // wrapped payload — never an `Optional<…>` — reaches the bridge). This
    // is the only robust way to detect a boxed Optional, since a dynamic
    // `as?` cast would silently flatten one level and let a nested
    // `Optional.none` slip through as a non-nil value.
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let wrapped = mirror.children.first else { return nil }
        return sanitizeForJinja(wrapped.value)
    }

    // Explicit JSON-null sentinels.
    if value is NSNull { return nil }
    if isJSONNullSentinel(value) { return nil }

    // Recurse into dictionaries, dropping null-valued entries. The cast to
    // `[String: Any]` succeeds for both `[String: Any]` (self-check
    // fixtures) and `[String: any Sendable]` (runtime builders).
    if let dictionary = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, element) in dictionary {
            if let cleaned = sanitizeForJinja(element) {
                result[key] = cleaned
            }
        }
        return result
    }

    // Recurse into arrays, dropping null elements and preserving order.
    if let array = value as? [Any] {
        var result: [Any] = []
        result.reserveCapacity(array.count)
        for element in array {
            if let cleaned = sanitizeForJinja(element) {
                result.append(cleaned)
            }
        }
        return result
    }

    // Non-null, non-container leaf (`String`, `NSNumber`, native `Bool` /
    // `Int` / `Double`, …). Return it untouched so its dynamic type — and
    // therefore Jinja's rendering of it — is identical to the un-sanitized
    // path.
    return value
}

/// Detect MLXLMServer's `private struct JSONNull` sentinel (emitted by
/// `JSONValue.sendableValue` for a JSON `null` in a tool parameter schema).
///
/// The type is `private` to another module, so we cannot name it; we match
/// on the runtime type name instead, which is stable and unambiguous in
/// this dependency graph. `NSNull` is handled separately by the caller.
private func isJSONNullSentinel(_ value: Any) -> Bool {
    let typeName = String(describing: type(of: value))
    if typeName == "JSONNull" { return true }
    // Defense in depth against a module-qualified spelling that
    // `String(reflecting:)` can produce for a private nested type.
    return String(reflecting: type(of: value)).contains("JSONNull")
}
