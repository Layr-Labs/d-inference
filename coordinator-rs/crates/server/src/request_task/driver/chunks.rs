//! Chunk handling and the first-content commitment path (plan §9.2.7,
//! §10.6, §13.6): classify, commit through the reducer, forward to the
//! consumer — never a byte before commitment, never a silent drop.

use bytes::Bytes;
use tokio::sync::mpsc;
use uuid::Uuid;

use darkbloom_core::ids::{AttemptId, LeaseId};
use darkbloom_core::request::{Event, PreparedFacts};
use darkbloom_core::time::DurationMs;

use crate::contracts::{ChunkFrame, FleetCommand, FleetObservation, ProtocolGen};
use crate::request_task::classify::{classify, rewrite_chunk_model, strip_sse_prefix, ChunkClass};
use crate::request_task::funding::clamp_tokens;
use crate::request_task::types::ConsumerEvent;

use super::Driver;

impl Driver {
    pub(super) async fn on_chunk(&mut self, attempt: AttemptId, frame: ChunkFrame) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            return;
        };
        if self
            .machine
            .attempts()
            .iter()
            .find(|a| a.id == attempt)
            .is_none_or(|a| a.state.is_closed())
        {
            return;
        }
        let Some(plaintext) = runtime.crypto.open_chunk(&frame.payload) else {
            // Never log ciphertext or plaintext; lengths and ids only.
            tracing::warn!(job = %self.req.job, %attempt, len = frame.payload.len(), "chunk decrypt failed; dropped");
            return;
        };
        // Zero-copy strip: the bare payload is a subslice of the plaintext.
        let bare = plaintext.slice_ref(strip_sse_prefix(&plaintext));
        match classify(&bare) {
            ChunkClass::Done | ChunkClass::UsageOnly => {
                // Swallowed: the coordinator appends its own final usage
                // chunk and exactly one [DONE] (Go parity).
                self.arm_idle_timer();
            }
            ChunkClass::Preamble => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.held_preamble.push(bare);
                }
                self.feed_now(Event::PreambleAccepted { attempt }).await;
            }
            ChunkClass::Content => self.on_content_chunk(attempt, frame, bare).await,
        }
    }

    async fn on_content_chunk(&mut self, attempt: AttemptId, frame: ChunkFrame, bare: Bytes) {
        let is_v1 = self
            .runtimes
            .get(&attempt)
            .is_some_and(|r| r.protocol == ProtocolGen::V1);
        // v1 commit ladder: first content synthesizes the prepared → funded
        // → started sequence THROUGH the reducer (see module docs).
        if is_v1
            && self.machine.funded_attempt().is_none()
            && self.outcome.is_none()
            && self.machine.committed_attempt().is_none()
        {
            let lease = LeaseId::new(Uuid::new_v4());
            let facts = PreparedFacts {
                first_content_eta: DurationMs::ZERO,
                billable_input_tokens: clamp_tokens(self.req.estimated_prompt_tokens),
                max_output_tokens: clamp_tokens(self.req.requested_max_tokens),
            };
            self.feed_now(Event::PreparedArrived {
                attempt,
                lease,
                facts,
                hedge_offer: None,
            })
            .await;
        }
        if self.machine.funded_attempt() != Some(attempt) || !self.machine.is_start_authorized() {
            // Emission without start authorization is a protocol violation
            // (plan §22.3): fence, never forward, never bill.
            if !is_v1 {
                if let Some(runtime) = self.runtimes.get(&attempt) {
                    let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                        FleetObservation::SecurityFence {
                            provider: runtime.provider,
                        },
                    ));
                }
            }
            return;
        }
        let first_commit = self.machine.committed_attempt().is_none();
        let cumulative = if is_v1 {
            let count = self
                .runtimes
                .get(&attempt)
                .map(|r| r.content_chunks + 1)
                .unwrap_or(1);
            clamp_tokens(count)
        } else {
            clamp_tokens(frame.cumulative_tokens)
        };
        self.feed_now(Event::ContentAccepted {
            attempt,
            cumulative_tokens: cumulative,
        })
        .await;
        if self.machine.committed_attempt() != Some(attempt) {
            return; // a raced cancel refused the commit
        }
        if first_commit {
            self.observe_first_content(attempt);
        }
        let mut to_forward: Vec<Bytes> = Vec::new();
        if let Some(runtime) = self.runtimes.get_mut(&attempt) {
            runtime.content_chunks += 1;
            runtime.accepted_sequence = frame.sequence;
            to_forward.append(&mut runtime.held_preamble);
        }
        to_forward.push(bare);
        for chunk in to_forward {
            if !self.forward_chunk(chunk).await {
                break;
            }
        }
        self.arm_idle_timer();
    }

    fn observe_first_content(&mut self, attempt: AttemptId) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            return;
        };
        let actual = self.clock.now().saturating_since(runtime.dispatched_at);
        let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
            FleetObservation::FirstContent {
                provider: runtime.provider,
                model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
                predicted: std::time::Duration::from_millis(runtime.predicted_first_content.get()),
                actual: std::time::Duration::from_millis(actual.get()),
            },
        ));
    }

    /// Forwards one committed chunk to the consumer. Returns false when the
    /// consumer is gone/stalled (the reducer takes over via the fed event).
    async fn forward_chunk(&mut self, chunk: Bytes) -> bool {
        let rewritten =
            rewrite_chunk_model(chunk, &self.req.concrete_model, &self.req.public_model);
        match self.req.consumer.try_send(ConsumerEvent::Chunk(rewritten)) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => {
                // Bounded consumer channel full past the pipe grace window:
                // 13.6 — cancel the provider, fail the request, never drop
                // silently.
                if !self.pipe_stalled {
                    self.pipe_stalled = true;
                    self.feed_now(Event::ConsumerPipeStalled).await;
                }
                false
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                if !self.consumer_gone {
                    self.on_consumer_gone().await;
                }
                false
            }
        }
    }

    pub(super) async fn on_consumer_gone(&mut self) {
        self.consumer_gone = true;
        self.feed_now(Event::ConsumerCancelled).await;
    }
}
