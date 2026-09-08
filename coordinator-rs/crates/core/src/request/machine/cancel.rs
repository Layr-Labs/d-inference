//! The consumer cancellation ladder (plan 13.1-13.6): one rung per phase,
//! with money released only on proof that no output can ever emit.

use super::{MoneyState, RequestMachine};
use crate::request::effects::Effect;
use crate::request::types::{AttemptState, Phase, RequestOutcome};

impl RequestMachine {
    pub(super) fn initiate_cancel(&mut self, outcome: RequestOutcome, effects: &mut Vec<Effect>) {
        match self.phase {
            Phase::Finalizing | Phase::Finished => {}
            Phase::Reserving => {
                // Reservation may still commit; ReserveCommitted will
                // release it immediately (13.1 analogue).
                self.cancel_requested = true;
                self.complete_once(outcome, effects);
            }
            Phase::Admitting => {
                self.cancel_requested = true;
                self.complete_once(outcome, effects);
                if self.money == MoneyState::Held {
                    self.dispose_release(effects);
                } else {
                    self.phase = Phase::Finished;
                }
            }
            Phase::Preparing | Phase::FundingPrepared { .. } => {
                self.cancel_requested = true;
                self.complete_once(outcome, effects);
                for i in 0..self.attempts.len() {
                    let rec = &mut self.attempts[i];
                    match rec.state {
                        AttemptState::QueuedToSocket if !rec.write_confirmed => {
                            // 13.1: before the provider write — discard the
                            // frame, release the permit, no cancel frame.
                            let id = rec.id;
                            rec.state = AttemptState::Aborted;
                            effects.push(Effect::DiscardQueuedFrame { attempt: id });
                            Self::release_permit_once(rec, effects);
                        }
                        AttemptState::QueuedToSocket | AttemptState::SentUnknown => {
                            // 13.2: on-wire or ambiguous — no release, no
                            // retry; await evidence.
                        }
                        AttemptState::Prepared if !rec.abort_requested => {
                            // 13.3: prepared but not started — idempotent
                            // abort; release follows acknowledgement,
                            // expiry, or session loss.
                            let id = rec.id;
                            let lease = rec.lease;
                            rec.abort_requested = true;
                            if let Some(lease) = lease {
                                effects.push(Effect::AbortLease { attempt: id, lease });
                            }
                        }
                        _ => {}
                    }
                }
                self.maybe_finish_cancel(effects);
            }
            Phase::Starting { attempt } => {
                // 13.4 with start delivery ambiguous: abort covers both
                // orders — tombstone if start lost, cancellation-with-
                // terminal if start won (10.3).
                self.cancel_requested = true;
                self.complete_once(outcome, effects);
                if let Ok(rec) = self.attempt_mut(attempt) {
                    if !rec.abort_requested && !rec.state.is_closed() {
                        rec.abort_requested = true;
                        if let Some(lease) = rec.lease {
                            effects.push(Effect::AbortLease { attempt, lease });
                        }
                    }
                }
                self.phase = Phase::AwaitingTerminal { attempt };
            }
            Phase::AwaitingContent { attempt } | Phase::Streaming { attempt } => {
                // 13.4 (started before content) / 13.5 (after content):
                // idempotent cancel, retain lease and job, bounded terminal
                // wait; no alternate, no reroute.
                self.cancel_requested = true;
                self.complete_once(outcome, effects);
                if let Ok(rec) = self.attempt_mut(attempt) {
                    if !rec.cancel_requested && !rec.state.is_closed() {
                        rec.cancel_requested = true;
                        if let Some(lease) = rec.lease {
                            effects.push(Effect::SendCancel { attempt, lease });
                        }
                    }
                }
                self.phase = Phase::AwaitingTerminal { attempt };
            }
            Phase::AwaitingTerminal { .. } => {
                // Already cancelling; the ladder is single-rung per state.
                self.cancel_requested = true;
                self.complete_once(outcome, effects);
            }
        }
    }

    /// Release the job once every attempt is closed under cancellation and
    /// funding never fired.
    pub(super) fn maybe_finish_cancel(&mut self, effects: &mut Vec<Effect>) {
        if !self.cancel_requested || self.funding.is_some() {
            return;
        }
        if self.attempts.iter().any(|a| !a.state.is_closed()) {
            return;
        }
        if self.money == MoneyState::Held {
            self.dispose_release(effects);
        } else if !matches!(self.phase, Phase::Finalizing | Phase::Finished) {
            self.phase = Phase::Finished;
        }
    }
}
