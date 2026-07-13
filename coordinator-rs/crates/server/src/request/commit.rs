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
    /// Nonempty text, reasoning, refusal, or tool output.
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
    /// A signed completed terminal may select an empty response at this point;
    /// held role, usage, and `[DONE]` frames are then released without being
    /// classified as first content.
    pub fn finish_success(&mut self) -> Result<Vec<Vec<u8>>, CommitmentError> {
        if self.finished {
            return Err(CommitmentError::AlreadyFinished);
        }
        let terminal_empty_commit = !self.committed;
        self.committed = true;
        self.finished = true;
        match self.mode {
            OutputMode::Streaming if terminal_empty_commit => Ok(self.take_held()),
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
/// Only nonempty generated output selects a provider. Role, usage, finish, and
/// lifecycle metadata remain held until content or terminal handling decides
/// the request outcome.
#[must_use]
pub fn classify_chunk(bytes: &[u8]) -> ChunkClass {
    let Some(payloads) = sse_or_raw_payloads(bytes) else {
        return ChunkClass::Preamble;
    };
    let mut done = false;
    for payload in payloads {
        if std::str::from_utf8(&payload).is_ok_and(|value| value.trim() == "[DONE]") {
            done = true;
            continue;
        }
        if serde_json::from_slice::<Value>(&payload).is_ok_and(|value| has_generated_output(&value))
        {
            return ChunkClass::Content;
        }
    }
    if done {
        ChunkClass::Done
    } else {
        ChunkClass::Preamble
    }
}

fn sse_or_raw_payloads(bytes: &[u8]) -> Option<Vec<Vec<u8>>> {
    let text = std::str::from_utf8(bytes).ok()?.replace("\r\n", "\n");
    if !text.lines().any(|line| line.starts_with("data:")) {
        return Some(vec![bytes.to_vec()]);
    }
    let mut payloads = Vec::new();
    for event in text.split("\n\n") {
        let mut data = Vec::new();
        let mut saw_data = false;
        for line in event.lines() {
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
            payloads.push(data);
        }
    }
    Some(payloads)
}

fn has_generated_output(value: &Value) -> bool {
    if generated_fields(value) {
        return true;
    }
    if value
        .get("type")
        .and_then(Value::as_str)
        .is_some_and(|kind| {
            matches!(
                kind,
                "response.output_text.delta"
                    | "response.reasoning_summary_text.delta"
                    | "response.function_call_arguments.delta"
            )
        })
        && value
            .get("delta")
            .and_then(Value::as_str)
            .is_some_and(|delta| !delta.is_empty())
    {
        return true;
    }
    value
        .get("choices")
        .and_then(Value::as_array)
        .is_some_and(|choices| {
            choices.iter().any(|choice| {
                choice
                    .get("delta")
                    .or_else(|| choice.get("message"))
                    .is_some_and(generated_fields)
            })
        })
}

fn generated_fields(value: &Value) -> bool {
    ["content", "reasoning_content", "reasoning", "refusal"]
        .iter()
        .any(|field| {
            value
                .get(*field)
                .and_then(Value::as_str)
                .is_some_and(|text| !text.is_empty())
        })
        || value
            .get("tool_calls")
            .and_then(Value::as_array)
            .is_some_and(|calls| calls.iter().any(tool_call_has_output))
}

fn tool_call_has_output(call: &Value) -> bool {
    ["id", "type"]
        .iter()
        .any(|field| nonempty_string(call.get(*field)))
        || call.get("function").is_some_and(|function| {
            ["name", "arguments"]
                .iter()
                .any(|field| nonempty_string(function.get(*field)))
        })
}

fn nonempty_string(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|text| !text.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROLE: &[u8] = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}

"#;
    const CREATED: &[u8] =
        br#"data: {"type":"response.created","response":{"status":"in_progress"}}"#;
    const USAGE: &[u8] = br#"data: {"object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":2,"completion_tokens":0,"total_tokens":2}}

"#;
    const FINISH: &[u8] = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{},"finish_reason":"stop"}]}

"#;
    const CONTENT: &[u8] = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"hello"},"finish_reason":null}]}

"#;
    const DONE: &[u8] = b"data: [DONE]\n\n";

    #[test]
    fn only_exact_role_and_lifecycle_preambles_are_held() {
        assert_eq!(classify_chunk(ROLE), ChunkClass::Preamble);
        assert_eq!(classify_chunk(CREATED), ChunkClass::Preamble);
        assert_eq!(classify_chunk(USAGE), ChunkClass::Preamble);
        assert_eq!(classify_chunk(FINISH), ChunkClass::Preamble);
        assert_eq!(classify_chunk(CONTENT), ChunkClass::Content);
        assert_eq!(classify_chunk(DONE), ChunkClass::Done);
        assert_eq!(
            classify_chunk(
                br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant","audio":{"id":"a"}},"finish_reason":null}]}"#
            ),
            ChunkClass::Preamble
        );
        assert_eq!(
            classify_chunk(
                br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"response.created"},"finish_reason":null}]}"#
            ),
            ChunkClass::Content
        );
        assert_eq!(
            classify_chunk(
                br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":""}}]},"finish_reason":null}]}"#
            ),
            ChunkClass::Preamble
        );
        assert_eq!(
            classify_chunk(
                br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{"}}]},"finish_reason":null}]}"#
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
            (ChunkClass::Preamble, USAGE),
            (ChunkClass::Preamble, FINISH),
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
            [
                ROLE.to_vec(),
                CREATED.to_vec(),
                USAGE.to_vec(),
                FINISH.to_vec(),
                CONTENT.to_vec()
            ]
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
            vec![[ROLE, CREATED, USAGE, FINISH, CONTENT, DONE].concat()]
        );
    }
}
