//! The reducer-effect dispatcher — the only place the driver performs I/O
//! (plan §19.3): each [`Effect`] arm delegates to the owning sibling.

use darkbloom_core::ids::{ModelId, ProviderId};
use darkbloom_core::request::{Effect, RequestOutcome};

use crate::contracts::{FleetCommand, FleetObservation};
use crate::request_task::types::ConsumerEvent;

use super::Driver;

impl Driver {
    pub(super) async fn execute(&mut self, effect: Effect) {
        match effect {
            Effect::RequestAdmission { exclude } => {
                let exclude: Vec<ProviderId> = exclude.into_iter().collect();
                self.admit(exclude).await;
            }
            Effect::SendPrepare { attempt, provider } => {
                self.dispatch_prepare(attempt, provider).await;
            }
            Effect::ReleasePermit { attempt } => self.release_permit(attempt),
            Effect::AbortLease { attempt, lease } => self.send_abort(attempt, lease),
            Effect::FundAndAuthorize {
                attempt,
                lease,
                facts,
            } => self.fund_and_authorize(attempt, lease, facts).await,
            Effect::SendStart { attempt, lease: _ } => self.send_start(attempt).await,
            Effect::SendCancel { attempt, lease: _ } => self.send_cancel(attempt),
            Effect::DiscardQueuedFrame { attempt } => {
                // The frame is already on the bounded writer lane; there is
                // nothing to unsend. The reducer has closed the attempt, so
                // any late evidence (a prepared lease) is disposed via the
                // late-lease path (plan §9.2.9).
                tracing::debug!(job = %self.req.job, %attempt, "queued frame discarded (attempt closed)");
            }
            Effect::ReturnHedgeOffer { attempt, provider } => {
                if let Some(token) = self.hedge_tokens.remove(&attempt) {
                    if let Ok(mut budget) = self.deps.hedge_budget.lock() {
                        budget.refund(token);
                    }
                }
                self.pending_grants.remove(&attempt);
                if let Some((_, permit)) = self.attempt_permits.remove(&attempt) {
                    let _ = self
                        .deps
                        .fleet
                        .commands
                        .try_send(FleetCommand::ReleasePermit { provider, permit });
                }
            }
            Effect::SettleJob {
                attempt,
                terminal: _,
                accepted_checkpoint,
            } => self.settle(attempt, accepted_checkpoint).await,
            Effect::ReleaseJob => self.release_job().await,
            Effect::EscalateReview { reason } => {
                let reason = format!("{reason:?}");
                self.move_to_review(reason).await;
            }
            Effect::RecordTerminalConflict {
                attempt,
                recorded: _,
                conflicting: _,
            } => {
                // Same attempt, different digest: no money moves; the
                // provider is reported for quarantine (plan §12.8).
                tracing::warn!(job = %self.req.job, %attempt, "terminal digest conflict");
                if let Some(runtime) = self.runtimes.get(&attempt) {
                    let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                        FleetObservation::ProviderFault {
                            provider: runtime.provider,
                            model: ModelId::new(&*self.req.concrete_model),
                        },
                    ));
                }
            }
            Effect::CompleteRequest { outcome } => self.complete_request(outcome),
        }
    }

    fn complete_request(&mut self, outcome: RequestOutcome) {
        self.outcome = Some(outcome);
        if self.machine.committed_attempt().is_none() {
            // Pre-content: the HTTP adapter maps the report; nothing was
            // written to the consumer (invisible failover, plan §7.8).
            return;
        }
        let event = match outcome {
            RequestOutcome::Completed => Some(ConsumerEvent::Completed(
                self.usage_out.clone().unwrap_or_default(),
            )),
            RequestOutcome::ProviderError { .. } => Some(ConsumerEvent::Failed {
                message: "provider error".to_owned(),
                error_type: "provider_error".to_owned(),
            }),
            RequestOutcome::ProviderLost => Some(ConsumerEvent::Failed {
                message: "provider ended without completion".to_owned(),
                error_type: "provider_error".to_owned(),
            }),
            RequestOutcome::DeadlineExceeded => Some(ConsumerEvent::Failed {
                message: "request timed out".to_owned(),
                error_type: "timeout".to_owned(),
            }),
            RequestOutcome::ConsumerBackpressure => Some(ConsumerEvent::Failed {
                message: "client too slow to consume stream".to_owned(),
                error_type: "consumer_backpressure".to_owned(),
            }),
            // The consumer is gone; there is nobody to answer.
            RequestOutcome::Cancelled => None,
            _ => None,
        };
        if let Some(event) = event {
            let _ = self.req.consumer.try_send(event);
        }
    }
}
