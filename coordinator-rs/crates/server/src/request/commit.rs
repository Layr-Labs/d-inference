//! Shared deferred-commit policy for streaming and nonstreaming responses.

use serde_json::Value;

use super::error::CommitmentError;

/// Consumer response shape.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputMode {
    /// Exact provider frames are published in order after first content.
    Streaming,
    /// Exact provider bytes are retained and published as one body at terminal.
    NonStreaming,
}

/// Semantic role of one exact provider payload.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChunkClass {
    /// Role-only or Responses lifecycle framing that cannot select a provider.
    Preamble,
    /// Consumer-visible content, finish, usage, or complete response bytes.
    Content,
    /// Exact `data: [DONE]` terminal framing.
    Done,
}

/// Finite memory limits while commitment is deferred.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CommitmentLimits {
    /// Maximum held frames.
    pub maximum_items: usize,
    /// Maximum exact held bytes.
    pub maximum_bytes: usize,
}

/// Bytes released by one commitment transition.
#[derive(Debug, Default, Eq, PartialEq)]
pub struct CommitmentOutput {
    /// Exact payloads ready for the direct consumer pipe.
    pub ready: Vec<Vec<u8>>,
    /// True only on the transition that selected this provider's content.
    pub first_content: bool,
}

/// One commitment state machine used by both response modes.
#[derive(Debug)]
pub struct OutputCommitment {
    mode: OutputMode,
    limits: CommitmentLimits,
    held: Vec<Vec<u8>>,
    held_bytes: usize,
    committed: bool,
    finished: bool,
}

impl OutputCommitment {
    /// Creates an empty finite commitment buffer.
    #[must_use]
    pub fn new(mode: OutputMode, limits: CommitmentLimits) -> Self {
        Self {
            mode,
            limits,
            held: Vec::new(),
            held_bytes: 0,
            committed: false,
            finished: false,
        }
    }

    /// Returns whether real output has selected the authorized attempt.
    #[must_use]
    pub const fn is_committed(&self) -> bool {
        self.committed
    }

    /// Returns exact bytes currently retained.
    #[must_use]
    pub const fn held_bytes(&self) -> usize {
        self.held_bytes
    }

    /// Accepts one already authenticated exact payload.
    ///
    /// Streaming holds only pre-commit preambles. Nonstreaming uses the same
    /// semantic commitment transition but retains all bytes until terminal.
    pub fn accept(
        &mut self,
        class: ChunkClass,
        bytes: Vec<u8>,
    ) -> Result<CommitmentOutput, CommitmentError> {
        if self.finished {
            return Err(CommitmentError::AlreadyFinished);
        }
        let first_content = !self.committed && class == ChunkClass::Content;
        if first_content {
            self.committed = true;
        }

        match self.mode {
            OutputMode::Streaming if self.committed => {
                let mut ready = if first_content {
                    self.take_held()
                } else {
                    Vec::new()
                };
                ready.push(bytes);
                Ok(CommitmentOutput {
                    ready,
                    first_content,
                })
            }
            OutputMode::Streaming | OutputMode::NonStreaming => {
                self.hold(bytes)?;
                Ok(CommitmentOutput {
                    ready: Vec::new(),
                    first_content,
                })
            }
        }
    }

    /// Finalizes a successful response.
    ///
    /// Streaming has already emitted exact frames. Nonstreaming concatenates
    /// the same exact byte sequence once, without parsing or re-encoding it.
    pub fn finish_success(&mut self) -> Result<Vec<Vec<u8>>, CommitmentError> {
        if self.finished {
            return Err(CommitmentError::AlreadyFinished);
        }
        if !self.committed {
            return Err(CommitmentError::NoContent);
        }
        self.finished = true;
        match self.mode {
            OutputMode::Streaming => Ok(Vec::new()),
            OutputMode::NonStreaming => {
                let held_bytes = self.held_bytes;
                let held = self.take_held();
                let mut body = Vec::with_capacity(held_bytes);
                for item in held {
                    body.extend_from_slice(&item);
                }
                Ok(vec![body])
            }
        }
    }

    /// Drops uncommitted preambles after a safe pre-authorization failure.
    pub fn reset_uncommitted(&mut self) -> Result<(), CommitmentError> {
        if self.finished {
            return Err(CommitmentError::AlreadyFinished);
        }
        if self.committed {
            return Err(CommitmentError::NoContent);
        }
        self.held.clear();
        self.held_bytes = 0;
        Ok(())
    }

    fn hold(&mut self, bytes: Vec<u8>) -> Result<(), CommitmentError> {
        if self.held.len() >= self.limits.maximum_items {
            return Err(CommitmentError::TooManyHeldItems {
                maximum: self.limits.maximum_items,
            });
        }
        let next =
            self.held_bytes
                .checked_add(bytes.len())
                .ok_or(CommitmentError::TooManyHeldBytes {
                    maximum: self.limits.maximum_bytes,
                })?;
        if next > self.limits.maximum_bytes {
            return Err(CommitmentError::TooManyHeldBytes {
                maximum: self.limits.maximum_bytes,
            });
        }
        self.held_bytes = next;
        self.held.push(bytes);
        Ok(())
    }

    fn take_held(&mut self) -> Vec<Vec<u8>> {
        self.held_bytes = 0;
        std::mem::take(&mut self.held)
    }
}

/// Classifies exact SSE or JSON bytes without changing them.
///
/// Malformed or unknown output is content: it must select the provider rather
/// than being silently discarded and retried. Only narrowly recognized role
/// and lifecycle preambles remain uncommitted.
#[must_use]
pub fn classify_chunk(bytes: &[u8]) -> ChunkClass {
    let Some(payload) = sse_or_raw_payload(bytes) else {
        return ChunkClass::Content;
    };
    if std::str::from_utf8(&payload).is_ok_and(|value| value.trim() == "[DONE]") {
        return ChunkClass::Done;
    }
    let Ok(value) = serde_json::from_slice::<Value>(&payload) else {
        return ChunkClass::Content;
    };
    if is_lifecycle_preamble(&value) || is_role_only_preamble(&value) {
        ChunkClass::Preamble
    } else {
        ChunkClass::Content
    }
}

fn sse_or_raw_payload(bytes: &[u8]) -> Option<Vec<u8>> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut data = Vec::new();
    let mut saw_data = false;
    for line in text.lines() {
        if let Some(mut value) = line.strip_prefix("data:") {
            if let Some(stripped) = value.strip_prefix(' ') {
                value = stripped;
            }
            if saw_data {
                data.push(b'\n');
            }
            data.extend_from_slice(value.as_bytes());
            saw_data = true;
        }
    }
    if saw_data {
        Some(data)
    } else {
        Some(bytes.to_vec())
    }
}

fn is_lifecycle_preamble(value: &Value) -> bool {
    matches!(
        value.get("type").and_then(Value::as_str),
        Some("response.created" | "response.in_progress")
    )
}

fn is_role_only_preamble(value: &Value) -> bool {
    if value.get("object").and_then(Value::as_str) != Some("chat.completion.chunk") {
        return false;
    }
    if value.get("usage").is_some_and(|usage| !usage.is_null()) {
        return false;
    }
    let Some(choices) = value.get("choices").and_then(Value::as_array) else {
        return false;
    };
    if choices.is_empty() {
        return false;
    }
    choices.iter().all(|choice| {
        if choice
            .get("finish_reason")
            .is_some_and(|value| !value.is_null())
        {
            return false;
        }
        let Some(delta) = choice.get("delta").and_then(Value::as_object) else {
            return false;
        };
        if !delta.contains_key("role") {
            return false;
        }
        delta.iter().all(|(field, value)| match field.as_str() {
            "role" => true,
            "content" | "reasoning_content" | "reasoning" | "refusal" => {
                value.is_null() || value.as_str() == Some("")
            }
            "tool_calls" => value.is_null() || value.as_array().is_some_and(Vec::is_empty),
            _ => false,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROLE: &[u8] = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}

"#;
    const CREATED: &[u8] =
        br#"data: {"type":"response.created","response":{"status":"in_progress"}}"#;
    const CONTENT: &[u8] = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"hello"},"finish_reason":null}]}

"#;
    const DONE: &[u8] = b"data: [DONE]\n\n";

    #[test]
    fn only_exact_role_and_lifecycle_preambles_are_held() {
        assert_eq!(classify_chunk(ROLE), ChunkClass::Preamble);
        assert_eq!(classify_chunk(CREATED), ChunkClass::Preamble);
        assert_eq!(classify_chunk(CONTENT), ChunkClass::Content);
        assert_eq!(classify_chunk(DONE), ChunkClass::Done);
        assert_eq!(
            classify_chunk(
                br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","audio":{"id":"a"}},"finish_reason":null}]}"#
            ),
            ChunkClass::Content
        );
        assert_eq!(
            classify_chunk(
                br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"response.created"},"finish_reason":null}]}"#
            ),
            ChunkClass::Content
        );
    }

    #[test]
    fn streaming_and_nonstreaming_share_commit_point_and_exact_order() {
        let limits = CommitmentLimits {
            maximum_items: 8,
            maximum_bytes: 4096,
        };
        let mut streaming = OutputCommitment::new(OutputMode::Streaming, limits);
        let mut nonstreaming = OutputCommitment::new(OutputMode::NonStreaming, limits);

        for (class, frame) in [
            (ChunkClass::Preamble, ROLE),
            (ChunkClass::Preamble, CREATED),
        ] {
            assert!(
                streaming
                    .accept(class, frame.to_vec())
                    .expect("hold")
                    .ready
                    .is_empty()
            );
            assert!(
                nonstreaming
                    .accept(class, frame.to_vec())
                    .expect("hold")
                    .ready
                    .is_empty()
            );
        }
        let streamed = streaming
            .accept(ChunkClass::Content, CONTENT.to_vec())
            .expect("commit");
        assert!(streamed.first_content);
        assert_eq!(
            streamed.ready,
            [ROLE.to_vec(), CREATED.to_vec(), CONTENT.to_vec()]
        );
        assert!(
            nonstreaming
                .accept(ChunkClass::Content, CONTENT.to_vec())
                .expect("commit")
                .first_content
        );
        assert_eq!(
            streaming
                .accept(ChunkClass::Done, DONE.to_vec())
                .expect("done")
                .ready,
            [DONE.to_vec()]
        );
        nonstreaming
            .accept(ChunkClass::Done, DONE.to_vec())
            .expect("done");
        assert!(streaming.finish_success().expect("finish").is_empty());
        assert_eq!(
            nonstreaming.finish_success().expect("finish"),
            vec![[ROLE, CREATED, CONTENT, DONE].concat()]
        );
    }
}
