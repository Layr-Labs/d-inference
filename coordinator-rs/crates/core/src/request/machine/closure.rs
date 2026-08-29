//! Acknowledgement and closure-evidence handlers: abort/cancel acks, hard
//! expiry, session loss, and the bounded terminal wait (plan 9.2.9, 10.2,
//! 13.3-13.5, 18).

use super::{ClosureEvidence, MoneyState, RequestMachine};
use crate::ids::AttemptId;
use crate::request::effects::Effect;
use crate::request::errors::TransitionError;
use crate::request::types::{AttemptState, Phase, RequestOutcome, ReviewReason};
use crate::time::TimestampMs;

impl RequestMachine {
    pub(super) fn on_abort_acked(
        &mut self,
        attempt: AttemptId,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let idx = self.attempt_index(attempt)?;
        let rec = &self.attempts[idx];
        if rec.state.is_closed() {
            return Ok(());
        }
        if !rec.abort_requested {
            return Err(TransitionError::NoAbortOutstanding { attempt });
        }
        {
            let rec = &mut self.attempts[idx];
            rec.state = AttemptState::Aborted;
            Self::release_permit_once(rec, effects);
        }

        if self.funding == Some(attempt) {
            // The abort tombstone beat the start (10.3): the attempt can
            // never emit, so the reservation is safely released.
            if self.money == MoneyState::Held {
                self.complete_once(RequestOutcome::Cancelled, effects);
                self.dispose_release(effects);
            }
            return Ok(());
        }
        self.after_pre_start_closure(true, RequestOutcome::ProviderLost, now, effects);
        Ok(())
    }

    pub(super) fn on_cancel_acked(
        &mut self,
        attempt: AttemptId,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let idx = self.attempt_index(attempt)?;
        if !self.attempts[idx].cancel_requested {
            if self.attempts[idx].state.is_closed() {
                return Ok(());
            }
            return Err(TransitionError::NoCancelOutstanding { attempt });
        }
        if self.committed.is_some() {
            // 13.5: after content the cancel ack alone carries no usage;
            // keep the bounded terminal wait for authenticated partial
            // usage.
            return Ok(());
        }
        // 10.2: cancel ack proves durable quiescence — no output can ever
        // emit, so a pre-content cancel releases the reservation in full.
        {
            let rec = &mut self.attempts[idx];
            rec.state = AttemptState::Aborted;
            Self::release_permit_once(rec, effects);
        }
        if self.money == MoneyState::Held {
            self.complete_once(RequestOutcome::Cancelled, effects);
            self.dispose_release(effects);
        }
        Ok(())
    }

    pub(super) fn on_attempt_closed_by_evidence(
        &mut self,
        attempt: AttemptId,
        evidence: ClosureEvidence,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let idx = self.attempt_index(attempt)?;
        if self.attempts[idx].state.is_closed() {
            return Ok(());
        }
        let was_started = matches!(self.attempts[idx].state, AttemptState::Started);
        {
            let rec = &mut self.attempts[idx];
            rec.state = AttemptState::Aborted;
            Self::release_permit_once(rec, effects);
        }

        if self.funding == Some(attempt) {
            self.close_funded_attempt_by_evidence(evidence, was_started, effects);
            return Ok(());
        }
        // Pre-funding: expiry and session loss are legitimate alternate
        // triggers (11.8, 12.9).
        self.after_pre_start_closure(true, RequestOutcome::ProviderLost, now, effects);
        Ok(())
    }

    fn close_funded_attempt_by_evidence(
        &mut self,
        evidence: ClosureEvidence,
        was_started: bool,
        effects: &mut Vec<Effect>,
    ) {
        if self.money != MoneyState::Held {
            return;
        }
        if self.committed.is_some() {
            // Output was exposed; the signed terminal will replay through
            // durable recovery. Never infer delivery, never release (10.6).
            self.complete_once(RequestOutcome::ProviderLost, effects);
            self.dispose_review(ReviewReason::ProviderLostAfterContent, effects);
            return;
        }
        match evidence {
            ClosureEvidence::HardExpiry => {
                // Lease expiry before content: the provider tombstones
                // expired leases, no emission is possible — explicit
                // no-start/expiry releases the job (plan 18).
                self.complete_once(RequestOutcome::ProviderLost, effects);
                self.dispose_release(effects);
            }
            ClosureEvidence::SessionLost => {
                if was_started
                    || matches!(
                        self.phase,
                        Phase::Starting { .. }
                            | Phase::AwaitingContent { .. }
                            | Phase::AwaitingTerminal { .. }
                    )
                {
                    // Start possibly reached the provider: do not release;
                    // reservation is held for terminal replay (13.4, 18).
                    self.complete_once(RequestOutcome::ProviderLost, effects);
                    self.dispose_review(ReviewReason::ProviderLostAfterStart, effects);
                } else {
                    // Funding chosen but start never sent: session teardown
                    // aborts the not-started lease (10.3) — safe release.
                    self.complete_once(RequestOutcome::ProviderLost, effects);
                    self.dispose_release(effects);
                }
            }
        }
    }

    pub(super) fn on_terminal_wait_elapsed(
        &mut self,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let Phase::AwaitingTerminal { .. } = self.phase else {
            return Ok(());
        };
        if self.money != MoneyState::Held {
            return Ok(());
        }
        let reason = if self.committed.is_some() {
            ReviewReason::TerminalTimeoutAfterContent
        } else {
            ReviewReason::TerminalTimeoutAfterStart
        };
        self.complete_once(RequestOutcome::Cancelled, effects);
        self.dispose_review(reason, effects);
        Ok(())
    }
}
