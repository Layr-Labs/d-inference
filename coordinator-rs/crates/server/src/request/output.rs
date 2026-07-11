//! Strict identity, sequence, accounting, digest, and terminal validation.

use darkbloom_coordinator_protocol::v2::{
    AttemptIdentity, BinaryFrameFlags, BinaryFrameHeader, BinaryFrameKind, Digest, ProviderId,
    ProviderProcessGenerationId, ProviderTerminal, TerminalOutcome,
};
use sha2::{Digest as ShaDigest, Sha256};

use super::{
    commit::{ChunkClass, classify_chunk},
    error::OutputError,
};

const ROLLING_DIGEST_INITIAL: [u8; 32] = [0; 32];
const MAX_TERMINAL_SIGNATURE_BYTES: usize = 16 * 1024;
const MAX_TERMINAL_MODEL_BYTES: usize = 256;

/// Finite request-specific output bounds.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OutputLimits {
    /// Maximum decrypted bytes in one chunk.
    pub maximum_chunk_bytes: usize,
    /// Maximum exact response bytes across every chunk.
    pub maximum_output_bytes: usize,
    /// Maximum number of chunks, including preambles and `[DONE]`.
    pub maximum_chunks: usize,
    /// Maximum completion tokens authorized by prepare.
    pub maximum_output_tokens: u64,
}

/// Immutable facts against which output and terminal messages are checked.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutputExpectations {
    /// Exact selected attempt identity.
    pub identity: AttemptIdentity,
    /// Exact prepared model.
    pub model: String,
    /// Provider-tokenized prompt count frozen at prepare.
    pub prompt_tokens: u64,
    /// Finite byte/item/token limits.
    pub limits: OutputLimits,
}

/// Authenticated exact output ready for commitment.
#[derive(Debug, Eq, PartialEq)]
pub struct VerifiedChunk {
    /// Semantic commitment class.
    pub class: ChunkClass,
    /// Exact decrypted bytes covered by both response digests.
    pub bytes: Vec<u8>,
    /// Authenticated cumulative completion-token count.
    pub cumulative_tokens: u64,
    /// Strict zero-based sequence.
    pub sequence: u64,
}

/// Frozen integrity summary after a valid terminal.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VerifiedTerminal {
    /// Exact concatenated response hash.
    pub response_hash: Digest,
    /// Final rolling digest.
    pub rolling_digest: Digest,
    /// Number of authenticated payload frames.
    pub chunks: usize,
    /// Exact concatenated response bytes.
    pub output_bytes: usize,
    /// Final cumulative completion-token count.
    pub completion_tokens: u64,
}

/// Per-attempt output verifier. It is synchronous and owns no task.
#[derive(Clone, Debug)]
pub struct OutputVerifier {
    expected: OutputExpectations,
    next_sequence: u64,
    cumulative_tokens: u64,
    chunks: usize,
    output_bytes: usize,
    rolling_digest: [u8; 32],
    response_hasher: Sha256,
    content_seen: bool,
    done_seen: bool,
    terminal_seen: bool,
}

impl OutputVerifier {
    /// Creates a verifier before the first provider frame arrives.
    #[must_use]
    pub fn new(expected: OutputExpectations) -> Self {
        Self {
            expected,
            next_sequence: 0,
            cumulative_tokens: 0,
            chunks: 0,
            output_bytes: 0,
            rolling_digest: ROLLING_DIGEST_INITIAL,
            response_hasher: Sha256::new(),
            content_seen: false,
            done_seen: false,
            terminal_seen: false,
        }
    }

    /// Validates and commits one exact decrypted response frame.
    ///
    /// The caller must decrypt/authenticate the ciphertext first. This method
    /// checks the authenticated header against those exact plaintext bytes.
    pub fn accept(
        &mut self,
        header: &BinaryFrameHeader,
        plaintext: Vec<u8>,
    ) -> Result<VerifiedChunk, OutputError> {
        if self.done_seen {
            return Err(OutputError::FrameAfterDone);
        }
        if header.kind != BinaryFrameKind::ResponseChunk {
            return Err(OutputError::WrongFrameKind);
        }
        if !header_matches_identity(header, &self.expected.identity) {
            return Err(OutputError::IdentityMismatch);
        }
        if header.sequence != self.next_sequence {
            return Err(OutputError::SequenceMismatch {
                expected: self.next_sequence,
                actual: header.sequence,
            });
        }
        if header.cumulative_tokens < self.cumulative_tokens {
            return Err(OutputError::CumulativeTokensRegressed {
                previous: self.cumulative_tokens,
                actual: header.cumulative_tokens,
            });
        }
        if header.cumulative_tokens > self.expected.limits.maximum_output_tokens {
            return Err(OutputError::CumulativeTokensExceeded {
                actual: header.cumulative_tokens,
                maximum: self.expected.limits.maximum_output_tokens,
            });
        }
        if header.flags.contains(BinaryFrameFlags::RETRANSMIT) {
            return Err(OutputError::RetransmitUnsupported);
        }
        if plaintext.len() > self.expected.limits.maximum_chunk_bytes {
            return Err(OutputError::ChunkTooLarge {
                actual: plaintext.len(),
                maximum: self.expected.limits.maximum_chunk_bytes,
            });
        }
        if self.chunks >= self.expected.limits.maximum_chunks {
            return Err(OutputError::TooManyChunks {
                maximum: self.expected.limits.maximum_chunks,
            });
        }
        let output_bytes =
            self.output_bytes
                .checked_add(plaintext.len())
                .ok_or(OutputError::OutputTooLarge {
                    actual: usize::MAX,
                    maximum: self.expected.limits.maximum_output_bytes,
                })?;
        if output_bytes > self.expected.limits.maximum_output_bytes {
            return Err(OutputError::OutputTooLarge {
                actual: output_bytes,
                maximum: self.expected.limits.maximum_output_bytes,
            });
        }

        let class = classify_chunk(&plaintext);
        let is_final = header.flags.contains(BinaryFrameFlags::FINAL);
        if (class == ChunkClass::Done) != is_final {
            return Err(OutputError::InvalidFinalFraming);
        }
        if class == ChunkClass::Done && !self.content_seen {
            return Err(OutputError::DoneBeforeContent);
        }

        let computed_rolling = next_rolling_digest(
            self.rolling_digest,
            header.sequence,
            header.cumulative_tokens,
            &plaintext,
        );
        if computed_rolling != header.rolling_digest {
            return Err(OutputError::RollingDigestMismatch);
        }

        self.response_hasher.update(&plaintext);
        self.rolling_digest = computed_rolling;
        self.cumulative_tokens = header.cumulative_tokens;
        self.output_bytes = output_bytes;
        self.chunks += 1;
        self.next_sequence =
            self.next_sequence
                .checked_add(1)
                .ok_or(OutputError::TooManyChunks {
                    maximum: self.expected.limits.maximum_chunks,
                })?;
        self.content_seen |= class == ChunkClass::Content;
        self.done_seen |= class == ChunkClass::Done;

        Ok(VerifiedChunk {
            class,
            bytes: plaintext,
            cumulative_tokens: header.cumulative_tokens,
            sequence: header.sequence,
        })
    }

    /// Validates the one durable provider terminal against exact delivered
    /// bytes and prepared bounds.
    pub fn validate_terminal<F>(
        &mut self,
        terminal: &ProviderTerminal,
        verify_signature: F,
    ) -> Result<VerifiedTerminal, OutputError>
    where
        F: FnOnce(ProviderId, ProviderProcessGenerationId, &Digest, &[u8]) -> bool,
    {
        if self.terminal_seen {
            return Err(OutputError::DuplicateTerminal);
        }
        if terminal.identity != self.expected.identity {
            return Err(OutputError::TerminalIdentityMismatch);
        }
        if terminal.model != self.expected.model || terminal.model.len() > MAX_TERMINAL_MODEL_BYTES
        {
            return Err(OutputError::TerminalModelMismatch);
        }
        if terminal.signature.as_bytes().len() > MAX_TERMINAL_SIGNATURE_BYTES {
            return Err(OutputError::TerminalAuthentication(
                "terminal signature exceeds hard bound".into(),
            ));
        }
        terminal
            .validate_with(&self.expected.identity, verify_signature)
            .map_err(|error| OutputError::TerminalAuthentication(error.to_string().into()))?;
        if terminal.prompt_tokens != self.expected.prompt_tokens {
            return Err(OutputError::TerminalPromptTokens {
                expected: self.expected.prompt_tokens,
                actual: terminal.prompt_tokens,
            });
        }
        if terminal.completion_tokens != self.cumulative_tokens {
            return Err(OutputError::TerminalCompletionTokens {
                expected: self.cumulative_tokens,
                actual: terminal.completion_tokens,
            });
        }
        if terminal.completion_tokens > self.expected.limits.maximum_output_tokens
            || terminal.reasoning_tokens > terminal.completion_tokens
            || terminal.final_generated_tokens < terminal.completion_tokens
            || terminal.final_generated_tokens > self.expected.limits.maximum_output_tokens
        {
            return Err(OutputError::TerminalUsageBounds);
        }
        match terminal.outcome {
            TerminalOutcome::Completed => {
                if terminal.error_class.is_some() {
                    return Err(OutputError::TerminalOutcomeMismatch);
                }
                if !self.done_seen {
                    return Err(OutputError::MissingDone);
                }
                if terminal.final_generated_tokens != terminal.completion_tokens {
                    return Err(OutputError::TerminalUsageBounds);
                }
            }
            TerminalOutcome::Cancelled => {
                if terminal.error_class
                    != Some(darkbloom_coordinator_protocol::v2::StructuredErrorClass::Cancelled)
                {
                    return Err(OutputError::TerminalOutcomeMismatch);
                }
            }
            TerminalOutcome::Error => {
                if terminal.error_class.is_none()
                    || terminal.error_class
                        == Some(darkbloom_coordinator_protocol::v2::StructuredErrorClass::Cancelled)
                {
                    return Err(OutputError::TerminalOutcomeMismatch);
                }
            }
        }

        let response_hash = self.response_hash();
        if terminal.response_hash != response_hash {
            return Err(OutputError::TerminalResponseHash);
        }
        let rolling_digest = Digest::new(self.rolling_digest);
        if terminal.rolling_digest != rolling_digest {
            return Err(OutputError::TerminalRollingDigest);
        }

        self.terminal_seen = true;
        Ok(VerifiedTerminal {
            response_hash,
            rolling_digest,
            chunks: self.chunks,
            output_bytes: self.output_bytes,
            completion_tokens: self.cumulative_tokens,
        })
    }

    /// Returns whether consumer-visible content was authenticated.
    #[must_use]
    pub const fn content_seen(&self) -> bool {
        self.content_seen
    }

    /// Returns whether exact `[DONE]` terminal framing was authenticated.
    #[must_use]
    pub const fn done_seen(&self) -> bool {
        self.done_seen
    }

    /// Returns the exact concatenated response hash so far.
    #[must_use]
    pub fn response_hash(&self) -> Digest {
        Digest::new(self.response_hasher.clone().finalize().into())
    }

    /// Returns the current rolling digest.
    #[must_use]
    pub const fn rolling_digest(&self) -> Digest {
        Digest::new(self.rolling_digest)
    }
}

/// Computes the protocol-v2 rolling checkpoint over exact plaintext.
#[must_use]
pub fn next_rolling_digest(
    previous: [u8; 32],
    sequence: u64,
    cumulative_tokens: u64,
    plaintext: &[u8],
) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(previous);
    hasher.update(sequence.to_be_bytes());
    hasher.update(cumulative_tokens.to_be_bytes());
    hasher.update(
        u64::try_from(plaintext.len())
            .unwrap_or(u64::MAX)
            .to_be_bytes(),
    );
    hasher.update(plaintext);
    hasher.finalize().into()
}

fn header_matches_identity(header: &BinaryFrameHeader, expected: &AttemptIdentity) -> bool {
    header.provider_id == expected.provider_id
        && header.provider_process_generation == expected.provider_process_generation
        && header.session_epoch == expected.session_epoch
        && header.request_id == expected.request_id
        && header.attempt_id == expected.attempt_id
        && header.reservation_id == expected.reservation_id
        && header.lease_id == expected.lease_id
}

#[cfg(test)]
mod tests {
    use darkbloom_coordinator_protocol::v2::{
        AttemptId, LeaseId, RequestId, ReservationId, SessionEpoch, TerminalSignature,
    };

    use super::*;

    fn identity() -> AttemptIdentity {
        AttemptIdentity {
            provider_id: ProviderId::new([1; 16]),
            provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
            session_epoch: SessionEpoch(3),
            request_id: RequestId::new([4; 16]),
            attempt_id: AttemptId::new([5; 16]),
            reservation_id: ReservationId::new([6; 16]),
            lease_id: LeaseId::new([7; 16]),
        }
    }

    fn verifier() -> OutputVerifier {
        OutputVerifier::new(OutputExpectations {
            identity: identity(),
            model: "model".into(),
            prompt_tokens: 3,
            limits: OutputLimits {
                maximum_chunk_bytes: 1024,
                maximum_output_bytes: 4096,
                maximum_chunks: 8,
                maximum_output_tokens: 5,
            },
        })
    }

    fn header(
        sequence: u64,
        cumulative_tokens: u64,
        previous: [u8; 32],
        bytes: &[u8],
        final_frame: bool,
    ) -> BinaryFrameHeader {
        let expected = identity();
        BinaryFrameHeader {
            kind: BinaryFrameKind::ResponseChunk,
            flags: if final_frame {
                BinaryFrameFlags::FINAL
            } else {
                BinaryFrameFlags::EMPTY
            },
            minor: 1,
            provider_id: expected.provider_id,
            provider_process_generation: expected.provider_process_generation,
            session_epoch: expected.session_epoch,
            request_id: expected.request_id,
            attempt_id: expected.attempt_id,
            reservation_id: expected.reservation_id,
            lease_id: expected.lease_id,
            nonce: [0; 24],
            rolling_digest: next_rolling_digest(previous, sequence, cumulative_tokens, bytes),
            sequence,
            ciphertext_len: u32::try_from(bytes.len()).expect("bounded"),
            cumulative_tokens,
        }
    }

    #[test]
    fn preamble_content_and_done_are_all_in_exact_digests() {
        let role = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}

"#;
        let content = br#"data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"hi"},"finish_reason":null}]}

"#;
        let done = b"data: [DONE]\n\n";
        let mut verifier = verifier();
        let mut previous = [0; 32];
        for (sequence, cumulative, bytes, final_frame, class) in [
            (0, 0, role.as_slice(), false, ChunkClass::Preamble),
            (1, 1, content.as_slice(), false, ChunkClass::Content),
            (2, 1, done.as_slice(), true, ChunkClass::Done),
        ] {
            let frame = header(sequence, cumulative, previous, bytes, final_frame);
            previous = frame.rolling_digest;
            assert_eq!(
                verifier
                    .accept(&frame, bytes.to_vec())
                    .expect("valid output")
                    .class,
                class
            );
        }
        let exact = [role.as_slice(), content.as_slice(), done.as_slice()].concat();
        assert_eq!(verifier.response_hash(), Digest::of(&exact));

        let mut terminal = ProviderTerminal {
            identity: identity(),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            prompt_tokens: 3,
            completion_tokens: 1,
            reasoning_tokens: 0,
            response_hash: Digest::of(&exact),
            final_generated_tokens: 1,
            rolling_digest: Digest::new(previous),
            model: "model".into(),
            terminal_digest: Digest::default(),
            signature: TerminalSignature::new(vec![1]),
        };
        terminal.terminal_digest = terminal.computed_digest().expect("terminal digest");

        let mut wrong_usage = terminal.clone();
        wrong_usage.completion_tokens = 2;
        wrong_usage.final_generated_tokens = 2;
        wrong_usage.terminal_digest = wrong_usage.computed_digest().expect("terminal digest");
        assert!(matches!(
            verifier
                .clone()
                .validate_terminal(&wrong_usage, |_, _, _, _| true),
            Err(OutputError::TerminalCompletionTokens { .. })
        ));

        let mut wrong_response = terminal.clone();
        wrong_response.response_hash = Digest::new([9; 32]);
        wrong_response.terminal_digest = wrong_response.computed_digest().expect("terminal digest");
        assert_eq!(
            verifier
                .clone()
                .validate_terminal(&wrong_response, |_, _, _, _| true),
            Err(OutputError::TerminalResponseHash)
        );

        let summary = verifier
            .validate_terminal(&terminal, |_, _, _, _| true)
            .expect("valid terminal");
        assert_eq!(summary.output_bytes, exact.len());
        assert_eq!(summary.chunks, 3);
    }

    #[test]
    fn strict_sequence_cumulative_digest_and_terminal_bounds_reject() {
        let bytes = b"data: {\"content\":\"x\"}\n\n";
        let mut verifier = verifier();
        let skipped = header(1, 1, [0; 32], bytes, false);
        assert!(matches!(
            verifier.accept(&skipped, bytes.to_vec()),
            Err(OutputError::SequenceMismatch { .. })
        ));

        let mut wrong_identity = header(0, 1, [0; 32], bytes, false);
        wrong_identity.provider_id = ProviderId::new([9; 16]);
        assert_eq!(
            verifier.accept(&wrong_identity, bytes.to_vec()),
            Err(OutputError::IdentityMismatch)
        );

        let valid = header(0, 1, [0; 32], bytes, false);
        verifier.accept(&valid, bytes.to_vec()).expect("first");
        let regressed = header(1, 0, valid.rolling_digest, bytes, false);
        assert!(matches!(
            verifier.accept(&regressed, bytes.to_vec()),
            Err(OutputError::CumulativeTokensRegressed { .. })
        ));

        let mut wrong_digest = header(1, 1, valid.rolling_digest, bytes, false);
        wrong_digest.rolling_digest = [9; 32];
        assert_eq!(
            verifier.accept(&wrong_digest, bytes.to_vec()),
            Err(OutputError::RollingDigestMismatch)
        );
    }

    #[test]
    fn done_before_content_is_not_a_successful_empty_response() {
        let done = b"data: [DONE]\n\n";
        let frame = header(0, 0, [0; 32], done, true);
        assert_eq!(
            verifier().accept(&frame, done.to_vec()),
            Err(OutputError::DoneBeforeContent)
        );
    }
}
