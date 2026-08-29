//! Streamed-chunk classification and the public-model rewrite.
//!
//! Ports the Go dispatch loop's first-content commitment rules (plan §9.2.7,
//! `coordinator/api/consumer.go isBoilerplateChunk`/`isSSEDoneChunk` and
//! `rewriteChunkModel`): a role-only delta or a Responses-API
//! `response.created`/`response.in_progress` lifecycle event does NOT commit
//! the request; everything else — content or tool-call deltas, finish
//! chunks, usage-only chunks, complete responses, unparseable data — does.

use bytes::Bytes;
use serde_json::value::RawValue;

/// How one provider chunk drives the request state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkClass {
    /// Role/lifecycle preamble: held, never commits (plan §9.2.7).
    Preamble,
    /// The provider's own `data: [DONE]` terminator: swallowed — the
    /// coordinator appends exactly one of its own.
    Done,
    /// Terminal usage-only chunk (`choices: []`, `usage` present): held so
    /// the coordinator's final usage chunk carries authoritative counts.
    UsageOnly,
    /// Content-bearing: commits the request on first sight (plan §9.2.7).
    Content,
}

/// Strips an SSE `data:` prefix if present. v1 providers ship chunks with
/// the prefix baked in; v2 plaintext chunks are bare JSON.
pub fn strip_sse_prefix(payload: &[u8]) -> &[u8] {
    let trimmed = trim_ascii(payload);
    let rest = trimmed
        .strip_prefix(b"data: ")
        .or_else(|| trimmed.strip_prefix(b"data:"))
        .unwrap_or(trimmed);
    trim_ascii(rest)
}

fn trim_ascii(mut b: &[u8]) -> &[u8] {
    while let [first, rest @ ..] = b {
        if first.is_ascii_whitespace() {
            b = rest;
        } else {
            break;
        }
    }
    while let [rest @ .., last] = b {
        if last.is_ascii_whitespace() {
            b = rest;
        } else {
            break;
        }
    }
    b
}

pub fn classify(payload: &[u8]) -> ChunkClass {
    let line = strip_sse_prefix(payload);
    if line == b"[DONE]" {
        return ChunkClass::Done;
    }
    if is_responses_lifecycle(line) {
        return ChunkClass::Preamble;
    }
    if is_usage_only(line) {
        return ChunkClass::UsageOnly;
    }
    if is_role_only_delta(line) {
        return ChunkClass::Preamble;
    }
    ChunkClass::Content
}

/// Responses-API lifecycle preamble: only when the PARSED top-level `type`
/// is exactly `response.created` / `response.in_progress` — a chat content
/// delta merely quoting that text must still commit (Go comment, verbatim
/// semantics).
fn is_responses_lifecycle(line: &[u8]) -> bool {
    if !contains(line, br#""response.created""#) && !contains(line, br#""response.in_progress""#) {
        return false;
    }
    #[derive(serde::Deserialize)]
    struct Ev<'a> {
        #[serde(rename = "type", borrow)]
        kind: Option<&'a str>,
    }
    matches!(
        serde_json::from_slice::<Ev<'_>>(line),
        Ok(Ev {
            kind: Some("response.created") | Some("response.in_progress"),
        })
    )
}

#[derive(serde::Deserialize)]
struct ChunkShape {
    #[serde(default)]
    object: Option<String>,
    #[serde(default)]
    usage: Option<Box<RawValue>>,
    #[serde(default)]
    choices: Vec<ChoiceShape>,
}

#[derive(serde::Deserialize)]
struct ChoiceShape {
    #[serde(default)]
    delta: Option<serde_json::Map<String, serde_json::Value>>,
    #[serde(default)]
    finish_reason: Option<serde_json::Value>,
}

/// Terminal usage chunk (Go `parseUsageOnlyStreamChunk`): a
/// `chat.completion.chunk` with a non-null `usage` object and no choices
/// carrying deltas or finish reasons.
fn is_usage_only(line: &[u8]) -> bool {
    if !contains(line, br#""usage""#) {
        return false;
    }
    let Ok(parsed) = serde_json::from_slice::<ChunkShape>(line) else {
        return false;
    };
    if parsed.object.as_deref() != Some("chat.completion.chunk") {
        return false;
    }
    let Some(usage) = parsed.usage.as_deref() else {
        return false;
    };
    if usage.get() == "null" {
        return false;
    }
    parsed.choices.iter().all(|c| {
        c.delta.as_ref().is_none_or(|d| d.is_empty())
            && matches!(&c.finish_reason, None | Some(serde_json::Value::Null))
    })
}

/// Role-only preamble (Go `isBoilerplateChunk`): a `chat.completion.chunk`
/// whose every delta carries ONLY the assistant role — content/reasoning/
/// refusal absent, null, or `""`; `tool_calls` absent/null/empty;
/// `finish_reason` null; no usage object.
fn is_role_only_delta(line: &[u8]) -> bool {
    if !contains(line, br#""role""#) {
        return false;
    }
    let Ok(parsed) = serde_json::from_slice::<ChunkShape>(line) else {
        return false;
    };
    if parsed.object.as_deref() != Some("chat.completion.chunk") {
        return false;
    }
    if parsed.usage.as_deref().is_some_and(|u| u.get() != "null") {
        return false;
    }
    if parsed.choices.is_empty() {
        return false;
    }
    for choice in &parsed.choices {
        if !matches!(&choice.finish_reason, None | Some(serde_json::Value::Null)) {
            return false;
        }
        let Some(delta) = &choice.delta else {
            return false;
        };
        if !delta.contains_key("role") {
            return false;
        }
        for (field, value) in delta {
            match field.as_str() {
                "role" => {}
                "content" | "reasoning_content" | "reasoning" | "refusal" => {
                    let empty = matches!(value, serde_json::Value::Null)
                        || matches!(value, serde_json::Value::String(s) if s.is_empty());
                    if !empty {
                        return false;
                    }
                }
                "tool_calls" => {
                    let empty = matches!(value, serde_json::Value::Null)
                        || matches!(value, serde_json::Value::Array(a) if a.is_empty());
                    if !empty {
                        return false;
                    }
                }
                _ => return false,
            }
        }
    }
    true
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// Replaces the concrete build id in a chunk's `"model"` field with the
/// public alias (Go `rewriteChunkModel`): precise key+value byte replace in
/// both compact and spaced JSON forms — no per-chunk JSON parse on the hot
/// path, and no allocation when nothing matches.
pub fn rewrite_chunk_model(chunk: Bytes, concrete: &str, public: &str) -> Bytes {
    if public.is_empty() || public == concrete {
        return chunk;
    }
    let compact_from = format!("\"model\":\"{concrete}\"");
    let spaced_from = format!("\"model\": \"{concrete}\"");
    if !contains(&chunk, compact_from.as_bytes()) && !contains(&chunk, spaced_from.as_bytes()) {
        return chunk;
    }
    let compact_to = format!("\"model\":\"{public}\"");
    let spaced_to = format!("\"model\": \"{public}\"");
    let mut out = Vec::with_capacity(chunk.len() + public.len().saturating_sub(concrete.len()) + 8);
    let mut i = 0;
    while i < chunk.len() {
        if chunk[i..].starts_with(compact_from.as_bytes()) {
            out.extend_from_slice(compact_to.as_bytes());
            i += compact_from.len();
        } else if chunk[i..].starts_with(spaced_from.as_bytes()) {
            out.extend_from_slice(spaced_to.as_bytes());
            i += spaced_from.len();
        } else {
            out.push(chunk[i]);
            i += 1;
        }
    }
    Bytes::from(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn role_only_delta_is_preamble() {
        let chunk = br#"{"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}"#;
        assert_eq!(classify(chunk), ChunkClass::Preamble);
        let with_empty = br#"{"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#;
        assert_eq!(classify(with_empty), ChunkClass::Preamble);
    }

    #[test]
    fn content_delta_commits() {
        let chunk = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"hi"},"finish_reason":null}]}"#;
        assert_eq!(classify(chunk), ChunkClass::Content);
        let with_role = br#"{"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","content":"x"}}]}"#;
        assert_eq!(classify(with_role), ChunkClass::Content);
        let tool = br#"{"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","tool_calls":[{"id":"t"}]}}]}"#;
        assert_eq!(classify(tool), ChunkClass::Content);
    }

    #[test]
    fn responses_lifecycle_is_preamble_but_quoted_text_is_not() {
        assert_eq!(
            classify(br#"{"type":"response.created","response":{}}"#),
            ChunkClass::Preamble
        );
        // A chat delta merely quoting the event name must commit.
        let quoted = br#"{"object":"chat.completion.chunk","choices":[{"delta":{"content":"\"response.created\""}}]}"#;
        assert_eq!(classify(quoted), ChunkClass::Content);
    }

    #[test]
    fn done_and_usage_chunks() {
        assert_eq!(classify(b"data: [DONE]"), ChunkClass::Done);
        let usage = br#"{"object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#;
        assert_eq!(classify(usage), ChunkClass::UsageOnly);
        // finish_reason chunk carrying usage:null is content (finish commits).
        let finish = br#"{"object":"chat.completion.chunk","choices":[{"delta":{},"finish_reason":"stop"}],"usage":null}"#;
        assert_eq!(classify(finish), ChunkClass::Content);
    }

    #[test]
    fn unparseable_commits() {
        assert_eq!(classify(b"garbage"), ChunkClass::Content);
    }

    #[test]
    fn model_rewrite_both_forms() {
        let chunk = Bytes::from_static(
            br#"{"model":"gemma-4-26b-4bit","x":{"model": "gemma-4-26b-4bit"}}"#,
        );
        let out = rewrite_chunk_model(chunk, "gemma-4-26b-4bit", "gemma-4");
        assert_eq!(&out[..], br#"{"model":"gemma-4","x":{"model": "gemma-4"}}"#);
    }

    #[test]
    fn model_rewrite_noop_borrows() {
        let chunk = Bytes::from_static(br#"{"model":"same"}"#);
        let out = rewrite_chunk_model(chunk.clone(), "same", "same");
        assert_eq!(out, chunk);
    }
}
