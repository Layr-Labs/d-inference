//! v1 (JSON) frame handlers: heartbeat, attempt-scoped inference frames,
//! attestation responses, and the zombie-stream canceller — ported from
//! `coordinator/api/provider.go`.

use std::time::Instant;

use bytes::Bytes;

use darkbloom_core::ids::StateRevision;
use darkbloom_protocol::json_v1::{
    msg_type, AttestationResponseMessage, CancelMessage, HeartbeatMessage,
    InferenceAcceptedMessage, InferenceCompleteMessage, InferenceErrorMessage,
    InferenceResponseChunkMessage,
};

use crate::contracts::{AttemptEvent, ChunkFrame, FleetCommand, FleetObservation, PipeError};

use super::attempts;
use super::heartbeat::map_heartbeat;
use super::reader::Reader;
use super::writer::{OutFrame, SessionWrite};

/// Why a v1 chunk was rejected before forwarding (plan §9.1.7: unknown,
/// plaintext, mixed, or wrong-key chunks are never forwarded).
enum ChunkViolation {
    Plaintext,
    Mixed,
    NoRegisteredKey,
    SenderKeyMismatch,
}

impl ChunkViolation {
    fn reason(&self) -> &'static str {
        match self {
            Self::Plaintext => "plaintext text chunk",
            Self::Mixed => "mixed plaintext and encrypted text chunk",
            Self::NoRegisteredKey => "provider missing registered public key",
            Self::SenderKeyMismatch => "chunk sender key mismatch",
        }
    }
}

impl Reader {
    pub(super) async fn handle_v1_text(&mut self, frame_type: &str, data: &[u8]) {
        match frame_type {
            msg_type::HEARTBEAT => self.handle_heartbeat(data),
            msg_type::INFERENCE_ACCEPTED => {
                if let Some(msg) = self.decode::<InferenceAcceptedMessage>(frame_type, data) {
                    let _ = self.deliver_event(&msg.request_id, AttemptEvent::AcceptedV1);
                }
            }
            msg_type::INFERENCE_RESPONSE_CHUNK => self.handle_chunk(data).await,
            msg_type::INFERENCE_COMPLETE => {
                if let Some(msg) = self.decode::<InferenceCompleteMessage>(frame_type, data) {
                    let event = AttemptEvent::CompleteV1 {
                        usage: Some(msg.usage),
                        se_signature: non_empty(msg.se_signature),
                        response_hash: non_empty(msg.response_hash),
                    };
                    let _ = self.deliver_event(&msg.request_id, event);
                }
            }
            msg_type::INFERENCE_ERROR => {
                if let Some(msg) = self.decode::<InferenceErrorMessage>(frame_type, data) {
                    let event = AttemptEvent::ErrorV1 {
                        status_code: u16::try_from(msg.status_code).unwrap_or(502),
                        message: msg.error,
                    };
                    let _ = self.deliver_event(&msg.request_id, event);
                }
            }
            msg_type::ATTESTATION_RESPONSE => {
                if let Some(msg) = self.decode::<AttestationResponseMessage>(frame_type, data) {
                    self.handle_attestation_response(msg).await;
                }
            }
            // Pilot scope: model-control status frames are placement
            // controller inputs (plan §7.7) — observed, not reduced here.
            msg_type::LOAD_MODEL_STATUS
            | msg_type::PREFETCH_MODEL_STATUS
            | msg_type::MODELS_UPDATE
            | msg_type::CODE_ATTESTATION_RESPONSE => {
                tracing::debug!(provider = %self.ctx.provider, frame_type,
                    "v1 frame acknowledged without reduction (pilot scope)");
            }
            msg_type::REGISTER => {
                // Re-registration on a live socket is a reconnect in Go;
                // here a provider reconnects with a fresh connection.
                self.count_security_drop("register on established session");
            }
            _ => {
                self.stale_drops += 1;
                tracing::debug!(provider = %self.ctx.provider, frame_type,
                    "unhandled v1 frame type");
            }
        }
    }

    fn handle_heartbeat(&mut self, data: &[u8]) {
        let Some(msg) = self.decode::<HeartbeatMessage>(msg_type::HEARTBEAT, data) else {
            return;
        };
        self.heartbeat_revision += 1;
        let update = map_heartbeat(
            self.ctx.provider,
            self.ctx.epoch,
            StateRevision::new(self.heartbeat_revision),
            self.ctx.statics,
            &msg,
        );
        // Coalesced advisory lane: a full mailbox drops THIS update — the
        // next heartbeat carries a strictly newer full snapshot (plan §14).
        if self.deps.fleet.heartbeats.try_send(update).is_err() {
            self.stale_drops += 1;
            tracing::debug!(provider = %self.ctx.provider, "heartbeat lane full; update dropped");
        }
    }

    async fn handle_chunk(&mut self, data: &[u8]) {
        let Some(msg) =
            self.decode::<InferenceResponseChunkMessage>(msg_type::INFERENCE_RESPONSE_CHUNK, data)
        else {
            return;
        };
        let request_id = msg.request_id.clone();

        // Route + validate in one bounded critical section; all sends are
        // non-blocking.
        enum Outcome {
            Forwarded,
            Unknown,
            Overflow,
            Violation(ChunkViolation),
        }
        let outcome = {
            let mut table = attempts::lock(&self.attempts);
            match table.entry_mut(&request_id).and_then(|e| e.sinks.as_ref()) {
                None => Outcome::Unknown,
                Some(sinks) => match validate_chunk(&msg, &self.ctx.provider_x25519_b64) {
                    Err(violation) => Outcome::Violation(violation),
                    Ok(payload) => match sinks.chunks.try_send(ChunkFrame {
                        payload,
                        sequence: 0,
                        cumulative_tokens: 0,
                    }) {
                        Ok(()) => Outcome::Forwarded,
                        Err(PipeError::Full) => Outcome::Overflow,
                        Err(PipeError::Closed) => Outcome::Unknown,
                    },
                },
            }
        };

        match outcome {
            Outcome::Forwarded => {}
            Outcome::Unknown => self.zombie_cancel_v1(&request_id),
            Outcome::Overflow => {
                // Consumer backpressure: the request task owns the decision
                // (cancel + fail) — the session only reports (plan §13.6).
                let _ = self.deliver_event(&request_id, AttemptEvent::PipeOverflow);
            }
            Outcome::Violation(violation) => {
                self.count_security_drop(violation.reason());
                // Integrity failure hard-fences the machine (plan §10.5
                // security class; Go marks the provider untrusted).
                let _ = self
                    .deps
                    .fleet
                    .commands
                    .send(FleetCommand::Observe(FleetObservation::SecurityFence {
                        provider: self.ctx.provider,
                    }))
                    .await;
                let event = AttemptEvent::ErrorV1 {
                    status_code: 502,
                    message: "provider returned invalid encrypted chunk".to_owned(),
                };
                let _ = self.deliver_event(&request_id, event);
            }
        }
    }

    /// Throttled cancel nudge for chunks of a request this session no
    /// longer tracks (Go zombie-stream canceller).
    fn zombie_cancel_v1(&mut self, request_id: &str) {
        if !self.zombie.should_cancel(request_id, Instant::now()) {
            return;
        }
        tracing::debug!(provider = %self.ctx.provider, request_id, "zombie stream cancel");
        let cancel = CancelMessage {
            request_id: request_id.to_owned(),
            ..Default::default()
        };
        if let Ok(encoded) = serde_json::to_vec(&cancel) {
            let _ = self.internal_tx.try_send(SessionWrite {
                frame: OutFrame::Text(Bytes::from(encoded)),
                on_wire: None,
            });
        }
    }

    async fn handle_attestation_response(&mut self, msg: AttestationResponseMessage) {
        // Split-borrow: challenge state is disjoint from ctx/deps.
        let mut challenge = std::mem::take(&mut self.challenge);
        challenge.handle_response(&self.ctx, &self.deps, msg).await;
        self.challenge = challenge;
    }
}

/// The chunk-integrity gate ported from Go `decryptTextResponseChunk`,
/// minus decryption: the session cannot know per-request keys (see the
/// module docs), so on success the raw `EncryptedPayload` JSON is the pipe
/// payload and the request task decrypts.
fn validate_chunk(
    msg: &InferenceResponseChunkMessage,
    registered_key_b64: &str,
) -> Result<Bytes, ChunkViolation> {
    let Some(encrypted) = msg.encrypted_data.as_ref() else {
        return Err(ChunkViolation::Plaintext);
    };
    if !msg.data.is_empty() {
        return Err(ChunkViolation::Mixed);
    }
    if registered_key_b64.is_empty() {
        return Err(ChunkViolation::NoRegisteredKey);
    }
    if encrypted.ephemeral_public_key != registered_key_b64 {
        return Err(ChunkViolation::SenderKeyMismatch);
    }
    // EncryptedPayload is ciphertext + a public key: safe to re-encode (it
    // is not signed material) and never logged.
    serde_json::to_vec(encrypted)
        .map(Bytes::from)
        .map_err(|_| ChunkViolation::Plaintext)
}

fn non_empty(value: String) -> Option<String> {
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}
