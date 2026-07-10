//! Protocol v2 frame handlers: attempt-scoped JSON lifecycle frames with
//! epoch/nonce fencing (plan §10.2) and binary encrypted-chunk frames
//! (plan §15.3).

use std::time::{Duration, Instant};

use bytes::Bytes;

use darkbloom_core::ids::{LeaseId, StateRevision};
use darkbloom_protocol::binary::{self, FrameKind};
use darkbloom_protocol::crypto::terminal_digest::verify_terminal_signature;
use darkbloom_protocol::json_v2::{AbortReason, CancelFrame, FrameV2, RequestScope, TerminalFrame};

use crate::contracts::{AttemptEvent, ChunkFrame, FleetCommand, FleetObservation, PipeError};

use super::attempts::{self, ScopeBinding};
use super::reader::{Deliver, Reader};
use super::writer::{OutFrame, SessionWrite};

/// Frame tags owned by the v2 dispatch path. `heartbeat` and
/// `attestation_response` intentionally stay on the v1 path — v2 keeps JSON
/// for control/registration/lifecycle (plan §15.3).
pub(super) fn is_v2_type(frame_type: &str) -> bool {
    matches!(
        frame_type,
        "prepare"
            | "prepared"
            | "start"
            | "started"
            | "abort"
            | "aborted"
            | "cancel"
            | "cancelled"
            | "terminal"
            | "terminal_ack"
            | "model_ready"
            | "model_gone"
    )
}

/// Scope validation outcome for an inbound attempt-scoped frame.
enum ScopeCheck {
    /// Valid; carries the demux wire id (canonical attempt UUID).
    Ok(String),
    Fenced(&'static str),
}

impl Reader {
    pub(super) async fn handle_v2_text(&mut self, frame_type: &str, data: &[u8]) {
        let frame = match FrameV2::decode(data) {
            Ok(frame) => frame,
            Err(_) => {
                self.stale_drops += 1;
                tracing::debug!(provider = %self.ctx.provider, frame_type,
                    "v2 frame decode failed");
                return;
            }
        };
        if frame.validate().is_err() {
            self.count_security_drop("v2 frame structural violation");
            return;
        }
        match frame {
            FrameV2::Prepared(prepared) => {
                let Some(wire_id) = self.check_scope(&prepared.scope) else {
                    return;
                };
                let Some(lease) = core_lease(&prepared.scope) else {
                    self.count_security_drop("prepared without lease");
                    return;
                };
                let event = AttemptEvent::Prepared {
                    lease,
                    ttl: Duration::from_millis(prepared.ttl_ms),
                    billable_prompt_tokens: prepared.billable_input_tokens,
                    queue_depth: prepared.execution.engine_queue_depth,
                    prefill_can_start: prepared.execution.prefill_can_start,
                    frame: Box::new(prepared),
                };
                let _ = self.deliver_event(&wire_id, event);
            }
            FrameV2::Started(started) => {
                let Some(wire_id) = self.check_scope(&started.scope) else {
                    return;
                };
                // Abort tombstone (plan §10.3): the tombstone lives
                // provider-side; a provider that acknowledged `aborted`
                // and later claims `started` for the same attempt is
                // replayed or misbehaving — the frame is inert.
                if attempts::lock(&self.attempts)
                    .entry_mut(&wire_id)
                    .is_some_and(|e| e.tombstoned)
                {
                    self.stale_drops += 1;
                    tracing::warn!(provider = %self.ctx.provider, wire_id,
                        "started after aborted tombstone dropped");
                    return;
                }
                let _ = self.deliver_event(&wire_id, AttemptEvent::Started);
            }
            FrameV2::Aborted(aborted) => {
                let Some(wire_id) = self.check_scope(&aborted.scope) else {
                    return;
                };
                let reason = {
                    let mut table = attempts::lock(&self.attempts);
                    table.tombstone(&wire_id);
                    table
                        .entry_mut(&wire_id)
                        .and_then(|e| e.pending_abort_reason)
                        .unwrap_or(AbortReason::Shutdown)
                };
                let _ = self.deliver_event(&wire_id, AttemptEvent::Aborted { reason });
            }
            FrameV2::Cancelled(cancelled) => {
                let Some(wire_id) = self.check_scope(&cancelled.scope) else {
                    return;
                };
                let _ = self.deliver_event(&wire_id, AttemptEvent::Cancelled);
            }
            FrameV2::Terminal(terminal) => self.handle_terminal(terminal).await,
            FrameV2::ModelReady(ready) => {
                self.send_lifecycle(ready.model_id, true, ready.state_revision)
                    .await;
            }
            FrameV2::ModelGone(gone) => {
                self.send_lifecycle(gone.model_id, false, gone.state_revision)
                    .await;
            }
            // Coordinator -> provider directions arriving inbound are
            // reflection/substitution attempts.
            FrameV2::Prepare(_)
            | FrameV2::Start(_)
            | FrameV2::Abort(_)
            | FrameV2::Cancel(_)
            | FrameV2::TerminalAck(_) => {
                self.count_security_drop("coordinator-bound v2 frame from provider");
            }
        }
    }

    async fn handle_terminal(&mut self, terminal: TerminalFrame) {
        let Some(wire_id) = self.check_scope(&terminal.scope) else {
            return;
        };
        // Plan §12.6 step 3: the terminal's Secure Enclave signature must
        // verify against the key attested at registration BEFORE the
        // terminal can drive settlement. The session is the only layer
        // holding that key, so intake is where verification lives; a v2
        // terminal that cannot be verified (no attested key, or a bad
        // signature) is security-dropped and the provider is fenced —
        // money then reaches its safe disposition through the terminal-wait
        // / recovery review path, never through an unverified claim.
        if !self.verify_terminal(&terminal).await {
            return;
        }
        match self.deliver_event(&wire_id, AttemptEvent::Terminal(Box::new(terminal))) {
            Deliver::Ok | Deliver::Dropped => {}
            Deliver::NoAttempt => {
                // Unacknowledged-terminal replay for an attempt no task is
                // attached to: durable-receipt recovery owns it (plan §10.6,
                // §18.1) — counted, never silently absorbed.
                self.stale_drops += 1;
                tracing::info!(provider = %self.ctx.provider, wire_id,
                    "terminal replay without attached attempt");
            }
        }
    }

    /// Verifies the terminal's SE signature on the blocking pool (P-256
    /// work never runs inline in a read loop — same discipline as
    /// [`crate::trust::TrustVerifier`]). Awaiting here preserves frame
    /// order: the terminal cannot overtake chunks already forwarded, and
    /// nothing later can overtake the terminal.
    async fn verify_terminal(&mut self, terminal: &TerminalFrame) -> bool {
        let Some(se_key) = self.ctx.se_public_key.clone() else {
            self.security_fence("v2 terminal without attested SE key");
            return false;
        };
        let frame = terminal.clone();
        let verified =
            tokio::task::spawn_blocking(move || verify_terminal_signature(&se_key, &frame).is_ok())
                .await
                .unwrap_or(false);
        if !verified {
            self.security_fence("v2 terminal SE signature invalid");
        }
        verified
    }

    /// Security-drops the frame AND reports the provider for fencing
    /// (plan §22.3: signature violations are provider faults, not noise).
    fn security_fence(&mut self, reason: &'static str) {
        self.count_security_drop(reason);
        let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
            FleetObservation::SecurityFence {
                provider: self.ctx.provider,
            },
        ));
    }

    async fn send_lifecycle(&mut self, model_id: String, ready: bool, revision: u64) {
        // Reliable lane (plan §14): lifecycle events must not be dropped.
        let _ = self
            .deps
            .fleet
            .commands
            .send(FleetCommand::ModelLifecycle {
                provider: self.ctx.provider,
                epoch: self.ctx.epoch,
                model: darkbloom_core::ids::ModelId::new(model_id),
                ready,
                revision: StateRevision::new(revision),
            })
            .await;
    }

    /// Validates the identity/fencing set every attempt-scoped frame must
    /// echo (plan §10.2): session epoch, coordinator epoch, and — when the
    /// writer bound this attempt's outbound prepare — the dispatch nonce
    /// and request digest. Stale or substituted frames are dropped with a
    /// security counter.
    fn check_scope(&mut self, scope: &RequestScope) -> Option<String> {
        match self.check_scope_inner(scope) {
            ScopeCheck::Ok(wire_id) => Some(wire_id),
            ScopeCheck::Fenced(reason) => {
                self.count_security_drop(reason);
                None
            }
        }
    }

    fn check_scope_inner(&mut self, scope: &RequestScope) -> ScopeCheck {
        if scope.session_epoch.0 != self.ctx.epoch.get() {
            return ScopeCheck::Fenced("v2 frame session epoch mismatch");
        }
        if scope.coordinator_epoch.0 != self.deps.coordinator_epoch.get() {
            return ScopeCheck::Fenced("v2 frame coordinator epoch mismatch");
        }
        let wire_id = scope.attempt_id.to_string();
        if let Some(binding) = attempts::lock(&self.attempts)
            .entry_mut(&wire_id)
            .and_then(|e| e.binding)
        {
            if binding.nonce != scope.dispatch_nonce {
                return ScopeCheck::Fenced("v2 frame dispatch nonce mismatch");
            }
            if binding.digest != scope.request_digest {
                return ScopeCheck::Fenced("v2 frame request digest mismatch");
            }
        }
        ScopeCheck::Ok(wire_id)
    }

    /// Binary encrypted-payload frames (plan §15.3): fixed header + raw
    /// ciphertext, decoded zero-copy. Only provider -> coordinator response
    /// chunks are legal inbound.
    pub(super) async fn handle_binary(&mut self, frame: Bytes) {
        let (header, payload) = match binary::decode(&frame, self.deps.config.max_frame_bytes) {
            Ok(decoded) => decoded,
            Err(err) => {
                self.count_security_drop("binary frame decode failure");
                tracing::debug!(provider = %self.ctx.provider, error = %err,
                    "binary frame rejected");
                return;
            }
        };
        if header.kind != FrameKind::ResponseChunk {
            self.count_security_drop("inbound binary frame of coordinator-bound kind");
            return;
        }
        if header.session_epoch.0 != self.ctx.epoch.get() {
            self.count_security_drop("binary chunk session epoch mismatch");
            return;
        }
        if header.coordinator_epoch.0 != self.deps.coordinator_epoch.get() {
            self.count_security_drop("binary chunk coordinator epoch mismatch");
            return;
        }
        let wire_id = header.attempt_id.to_string();

        enum Outcome {
            Forwarded,
            Unknown,
            Overflow,
            Fenced(&'static str),
        }
        let outcome = {
            let mut table = attempts::lock(&self.attempts);
            let entry = table.entry_mut(&wire_id);
            match entry {
                None => Outcome::Unknown,
                Some(entry) => {
                    if let Some(ScopeBinding { nonce, digest }) = entry.binding {
                        if nonce != header.dispatch_nonce {
                            Outcome::Fenced("binary chunk dispatch nonce mismatch")
                        } else if digest != header.request_digest {
                            Outcome::Fenced("binary chunk request digest mismatch")
                        } else {
                            forward_chunk(entry, &header, payload)
                        }
                    } else {
                        forward_chunk(entry, &header, payload)
                    }
                }
            }
        };

        fn forward_chunk(
            entry: &mut attempts::AttemptEntry,
            header: &binary::BinaryFrameHeader,
            payload: Bytes,
        ) -> Outcome {
            let Some(sinks) = entry.sinks.as_ref() else {
                return Outcome::Unknown;
            };
            match sinks.chunks.try_send(ChunkFrame {
                payload,
                sequence: header.sequence,
                cumulative_tokens: header.cumulative_completion_tokens,
            }) {
                Ok(()) => Outcome::Forwarded,
                Err(PipeError::Full) => Outcome::Overflow,
                Err(PipeError::Closed) => Outcome::Unknown,
            }
        }

        match outcome {
            Outcome::Forwarded => {}
            Outcome::Overflow => {
                let _ = self.deliver_event(&wire_id, AttemptEvent::PipeOverflow);
            }
            Outcome::Fenced(reason) => self.count_security_drop(reason),
            Outcome::Unknown => self.zombie_cancel_v2(&wire_id, &header),
        }
    }

    /// Throttled v2 cancel for chunks of an attempt this session no longer
    /// tracks. The binary header carries the full scope, so the cancel can
    /// echo the exact identity (plan §10.2). Requires the lease id; a
    /// chunk without one is counted and dropped.
    fn zombie_cancel_v2(&mut self, wire_id: &str, header: &binary::BinaryFrameHeader) {
        if !self.zombie.should_cancel(wire_id, Instant::now()) {
            return;
        }
        if header.lease_id.is_none() {
            self.stale_drops += 1;
            return;
        }
        tracing::debug!(provider = %self.ctx.provider, wire_id, "zombie v2 stream cancel");
        let cancel = FrameV2::Cancel(CancelFrame {
            scope: RequestScope {
                job_id: header.job_id,
                attempt_id: header.attempt_id,
                lease_id: header.lease_id,
                session_epoch: header.session_epoch,
                coordinator_epoch: header.coordinator_epoch,
                dispatch_nonce: header.dispatch_nonce,
                request_digest: header.request_digest,
            },
        });
        if let Ok(encoded) = cancel.encode() {
            let _ = self.internal_tx.try_send(SessionWrite {
                frame: OutFrame::Text(Bytes::from(encoded)),
                on_wire: None,
            });
        }
    }
}

/// Converts the wire lease id to the core domain id.
fn core_lease(scope: &RequestScope) -> Option<LeaseId> {
    scope
        .lease_id
        .map(|lease| LeaseId::new(uuid::Uuid::from_bytes(*lease.as_bytes())))
}
