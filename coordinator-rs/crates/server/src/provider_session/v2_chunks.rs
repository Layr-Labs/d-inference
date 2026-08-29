//! Protocol v2 binary encrypted-chunk intake (plan §15.3): zero-copy
//! decode, header scope fencing, pipe forwarding, and the zombie-stream
//! cancel for untracked attempts.

use std::time::Instant;

use bytes::Bytes;

use darkbloom_protocol::binary::{self, FrameKind};
use darkbloom_protocol::json_v2::{CancelFrame, FrameV2, RequestScope};

use crate::contracts::{AttemptEvent, ChunkFrame, PipeError};

use super::attempts::{self, ScopeBinding};
use super::reader::Reader;
use super::writer::{OutFrame, SessionWrite};

impl Reader {
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
