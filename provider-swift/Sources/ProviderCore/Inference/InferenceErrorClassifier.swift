import Foundation

// MARK: - Normalized inference-error classification (DAR-341)
//
// gpt-oss returns 500s from two distinct, otherwise-indistinguishable Jinja
// failure modes:
//   1. DAR-341: the Harmony template `raise_exception`s because an assistant
//      message's content/thinking carries raw `<|channel|>` tags.
//   2. DAR-329: the swift-jinja null-bridge crash ("Cannot convert value of
//      type … to Jinja Value").
// Durable telemetry only sees a generic 500 + a lossy error string, so these
// are indistinguishable after the fact. We classify on the PROVIDER — at the
// catch site where the real `Error` object (and its rich `String(describing:)`
// text) is still in scope — into a small normalized vocabulary and ship ONLY
// that enum string to the coordinator. Request content is never transmitted or
// logged (E2E privacy).
//
// The emitted vocabulary MUST stay in lockstep with the coordinator's Go
// `error_reason` field: "jinja_channel_tags", "jinja_null_bridge",
// "jinja_template", "model_load". nil ⇒ unclassifiable (coordinator falls back
// to deriving a reason from status/class). Do NOT invent other provider-side
// values.

/// Classify an inference `Error` into the shared normalized `error_reason`
/// vocabulary, or nil when it cannot be confidently classified.
///
/// Pure + side-effect-free: inspects only the error's textual descriptions and
/// concrete type name, never any request/message content.
func classifyInferenceErrorReason(_ error: Error) -> String? {
    // `String(describing:)` carries the RICH template text (e.g. the Harmony
    // "...passed a message containing <|channel|> tags in the content field..."
    // message) that `localizedDescription` collapses to the lossy
    // "(Jinja.TemplateException error 1.)". Inspect both, plus the fully-
    // qualified type name, so a TemplateException is still recognized when its
    // localized form is lossy.
    let described = String(describing: error)
    let localized = error.localizedDescription
    let typeName = String(reflecting: type(of: error))
    let haystack = described + "\n" + localized + "\n" + typeName

    // DAR-341 — Harmony assistant message carried raw <|channel|> tags. MUST be
    // checked BEFORE the generic jinja_template branch (this is itself a
    // TemplateException, so it would otherwise be swallowed there).
    if haystack.contains("containing <|channel|> tags")
        || (haystack.contains("<|channel|>")
            && (haystack.contains("tags in the content")
                || haystack.contains("tags in the thinking"))) {
        return "jinja_channel_tags"
    }

    // DAR-329 — swift-jinja null-bridge crash.
    if haystack.contains("Cannot convert value of type") && haystack.contains("Jinja Value") {
        return "jinja_null_bridge"
    }

    // Any other Jinja / template render failure.
    if haystack.contains("TemplateException") || haystack.contains("Jinja") {
        return "jinja_template"
    }

    return nil
}

/// Privacy-safe diagnostic helper: locate the FIRST chat message whose textual
/// fields carry a raw Harmony `<|channel|>` tag, returning ONLY its index and
/// role. The message content is deliberately never returned (or logged) — only
/// the location, so a channel-tags template failure can be pinpointed without
/// exposing any prompt text.
///
/// `messages` is the chat-template dict shape (`["role": ..., "content": ...,
/// "reasoning_content": ...]`) — the same representation handed to
/// `applyChatTemplate`. Scans the `content`, `thinking`, and `reasoning_content`
/// string fields, mirroring the fields the Harmony template rejects.
func offendingHarmonyMessageLocation(
    in messages: [[String: any Sendable]]
) -> (index: Int, role: String)? {
    let marker = "<|channel|>"
    let textKeys = ["content", "thinking", "reasoning_content"]
    for (index, message) in messages.enumerated() {
        for key in textKeys {
            if let text = message[key] as? String, text.contains(marker) {
                let role = (message["role"] as? String) ?? "unknown"
                return (index: index, role: role)
            }
        }
    }
    return nil
}
