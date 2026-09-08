//! Merged pump inputs and the provider-event → reducer-event mapping
//! (plan §7.2: observations in, reducer decides).

use darkbloom_core::ids::{AttemptId, LeaseId};
use darkbloom_core::request::{AttemptState, Event, PreparedFacts};
use darkbloom_core::time::DurationMs;
use darkbloom_protocol::json_v1::UsageInfo;
use darkbloom_protocol::json_v2::AbortReason;

use crate::contracts::{AttemptEvent, ChunkFrame, FleetCommand, FleetObservation};
use crate::request_task::attempt::{classify_v1_error, core_error_class};
use crate::request_task::funding::clamp_tokens;
use crate::request_task::terminal::{v1_complete_receipt, v1_error_receipt, v2_receipt};

use super::Driver;

/// Merged inputs from all pump tasks.
pub(super) enum TaskInput {
    Attempt(AttemptId, AttemptEvent),
    Chunk(AttemptId, ChunkFrame),
    Wire {
        attempt: AttemptId,
        kind: WireKind,
        result: WireOutcome,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum WireKind {
    Prepare,
    Start,
    Abort,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum WireOutcome {
    Confirmed,
    Failed,
    Ambiguous,
}

impl Driver {
    pub(super) async fn on_attempt_event(&mut self, attempt: AttemptId, event: AttemptEvent) {
        match event {
            AttemptEvent::Prepared {
                lease,
                ttl,
                billable_prompt_tokens,
                queue_depth: _,
                prefill_can_start: _,
                frame,
            } => {
                // Provider-quoted input must stay within the coordinator's
                // request-shape upper bound (plan §12.5): bytes bound tokens
                // for every BPE tokenizer.
                if billable_prompt_tokens > self.req.body.len() as u64 {
                    self.quote_violation(attempt, lease).await;
                    return;
                }
                let now = self.clock.now();
                let predicted = self
                    .runtimes
                    .get(&attempt)
                    .map(|r| r.predicted_first_content)
                    .unwrap_or(DurationMs::new(0));
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.record_lease(lease);
                    runtime.prepare_deadline_at = None;
                    runtime.lease_expiry_at =
                        Some(now.saturating_add(DurationMs::new(ttl.as_millis() as u64)));
                }
                let eta = frame
                    .execution
                    .predicted_first_content_ms
                    .map(DurationMs::new)
                    .unwrap_or(predicted);
                let facts = PreparedFacts {
                    first_content_eta: eta,
                    billable_input_tokens: clamp_tokens(billable_prompt_tokens),
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
            AttemptEvent::Started => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.lease_expiry_at = None;
                }
                self.mark_running().await;
                self.arm_idle_timer();
                self.feed_now(Event::StartedAck { attempt }).await;
            }
            AttemptEvent::Aborted { reason: _ } => {
                self.feed_now(Event::AbortAcked { attempt }).await;
            }
            AttemptEvent::Cancelled => {
                self.feed_now(Event::CancelAcked { attempt }).await;
            }
            AttemptEvent::Terminal(frame) => {
                // v2 has no dedicated prepare-rejection frame: a terminal
                // with `outcome=failed` arriving BEFORE a prepared lease IS
                // the rejection vehicle (plan §10.5). Map it to the typed
                // rejection so class semantics hold (capacity/draining take
                // the sequential alternate; invalid_request/security fail
                // deterministically) and the fleet observes it (plan §11.3
                // advisory invalidation, §11.6 health).
                if self.attempt_awaiting_prepare(attempt) {
                    if let darkbloom_protocol::json_v2::TerminalOutcome::Failed = frame.outcome {
                        let class = frame
                            .error_class
                            .unwrap_or(darkbloom_protocol::json_v2::ErrorClass::Fault);
                        self.observe_prepare_rejected(attempt, class);
                        self.feed_now(Event::PrepareRejected {
                            attempt,
                            class: core_error_class(class),
                        })
                        .await;
                        return;
                    }
                }
                let Some((receipt, summary)) = v2_receipt(frame) else {
                    tracing::warn!(job = %self.req.job, %attempt, "structurally invalid terminal dropped");
                    self.observe_fault(attempt);
                    return;
                };
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.receipt = Some(receipt);
                    runtime.lease_expiry_at = None;
                }
                self.feed_now(Event::TerminalArrived {
                    attempt,
                    terminal: summary,
                })
                .await;
            }
            AttemptEvent::AcceptedV1 => {
                // Liveness only; v1 commitment is first content (Go parity).
            }
            AttemptEvent::CompleteV1 {
                usage,
                se_signature,
                response_hash,
            } => {
                self.on_v1_complete(attempt, usage, se_signature, response_hash)
                    .await
            }
            AttemptEvent::ErrorV1 {
                status_code,
                message,
            } => self.on_v1_error(attempt, status_code, message).await,
            AttemptEvent::SessionLost => {
                self.feed_now(Event::SessionLost { attempt }).await;
            }
            AttemptEvent::PipeOverflow => {
                if !self.pipe_stalled {
                    self.pipe_stalled = true;
                    self.feed_now(Event::ConsumerPipeStalled).await;
                }
            }
        }
    }

    /// Out-of-bound prepared quote: abort the lease, fail the attempt as a
    /// security rejection, fence the provider (plan §12.5).
    async fn quote_violation(&mut self, attempt: AttemptId, lease: LeaseId) {
        if let Some(runtime) = self.runtimes.get_mut(&attempt) {
            runtime.record_lease(lease);
            let frame = runtime.abort_frame(AbortReason::DeadlineUnreachable);
            let _ = runtime.session.submit_control(frame);
            let provider = runtime.provider;
            let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                FleetObservation::SecurityFence { provider },
            ));
        }
        self.feed_now(Event::PrepareRejected {
            attempt,
            class: darkbloom_core::provider_error::ProviderErrorClass::Security,
        })
        .await;
    }

    async fn on_v1_complete(
        &mut self,
        attempt: AttemptId,
        usage: Option<UsageInfo>,
        se_signature: Option<String>,
        response_hash: Option<String>,
    ) {
        if self.machine.committed_attempt() == Some(attempt) {
            // Checkpoint promotion: every chunk preceding this terminal was
            // accepted into the consumer pipe in order, so the terminal's
            // claimed completion count is itself accepted output. Not
            // promoted under cancellation or backpressure — there the
            // chunk-count checkpoint caps the partial settle (plan §13.5,
            // §13.6).
            if !self.consumer_gone && !self.pipe_stalled {
                if let Some(u) = usage {
                    let cumulative = clamp_tokens(u.completion_tokens.max(0) as u64);
                    self.feed_now(Event::ContentAccepted {
                        attempt,
                        cumulative_tokens: cumulative,
                    })
                    .await;
                }
            }
            let (receipt, summary) =
                v1_complete_receipt(self.req.job, attempt, usage, se_signature, response_hash);
            if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                runtime.receipt = Some(receipt);
            }
            self.feed_now(Event::TerminalArrived {
                attempt,
                terminal: summary,
            })
            .await;
            return;
        }
        // Complete before any content: zero-output stream. Mirrors the Go
        // "provider ended without completion" pre-commit failover.
        self.feed_now(Event::PrepareRejected {
            attempt,
            class: darkbloom_core::provider_error::ProviderErrorClass::Fault,
        })
        .await;
    }

    async fn on_v1_error(&mut self, attempt: AttemptId, status_code: u16, message: String) {
        let class = classify_v1_error(status_code, &message);
        self.observe_fault(attempt);
        if self.machine.committed_attempt() == Some(attempt) {
            let (receipt, summary) = v1_error_receipt(self.req.job, attempt, status_code, class);
            if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                runtime.receipt = Some(receipt);
            }
            self.feed_now(Event::TerminalArrived {
                attempt,
                terminal: summary,
            })
            .await;
            return;
        }
        self.feed_now(Event::PrepareRejected { attempt, class })
            .await;
    }

    pub(super) fn observe_fault(&mut self, attempt: AttemptId) {
        if let Some(runtime) = self.runtimes.get(&attempt) {
            let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                FleetObservation::ProviderFault {
                    provider: runtime.provider,
                    model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
                },
            ));
        }
    }

    /// True while the attempt has produced no prepared lease and no closure
    /// evidence — the window in which a failed terminal is a prepare
    /// rejection, not a run disposition.
    fn attempt_awaiting_prepare(&self, attempt: AttemptId) -> bool {
        self.machine.attempts().iter().any(|a| {
            a.id == attempt
                && matches!(
                    a.state,
                    AttemptState::QueuedToSocket | AttemptState::SentUnknown
                )
        })
    }

    /// Reports a structured prepare rejection to the fleet (plan §11.6;
    /// capacity classes also invalidate the provider's advisory capacity
    /// until fresh heartbeat state arrives, plan §11.3).
    fn observe_prepare_rejected(
        &mut self,
        attempt: AttemptId,
        class: darkbloom_protocol::json_v2::ErrorClass,
    ) {
        if let Some(runtime) = self.runtimes.get(&attempt) {
            let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                FleetObservation::PrepareRejected {
                    provider: runtime.provider,
                    model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
                    class,
                },
            ));
        }
    }

    // ------------------------------------------------------------------
    // Wire results
    // ------------------------------------------------------------------

    pub(super) async fn on_wire(
        &mut self,
        attempt: AttemptId,
        kind: WireKind,
        result: WireOutcome,
    ) {
        let event = match (kind, result) {
            (WireKind::Prepare, WireOutcome::Confirmed) => {
                Some(Event::PrepareWriteConfirmed { attempt })
            }
            (WireKind::Prepare, WireOutcome::Failed) => Some(Event::PrepareWriteFailed { attempt }),
            (WireKind::Prepare, WireOutcome::Ambiguous) => {
                Some(Event::PrepareWriteUnknown { attempt })
            }
            (WireKind::Start, WireOutcome::Ambiguous) => Some(Event::StartWriteUnknown { attempt }),
            (WireKind::Start, WireOutcome::Failed) => Some(Event::SessionLost { attempt }),
            (WireKind::Abort | WireKind::Cancel, WireOutcome::Failed) => {
                Some(Event::SessionLost { attempt })
            }
            // Confirmed control writes and ambiguous abort/cancel resolve
            // through acks, terminals, or the evidence timers.
            _ => None,
        };
        if let Some(event) = event {
            self.feed_now(event).await;
        }
    }
}
