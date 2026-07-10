//! Funded execution handlers: fund outcome, start, content commitment, and
//! terminal disposition (plan 10.3, 10.6, 12.5, 12.8).

use super::{MoneyState, RequestMachine};
use crate::ids::AttemptId;
use crate::money::Tokens;
use crate::provider_error::ProviderErrorClass;
use crate::request::effects::Effect;
use crate::request::errors::TransitionError;
use crate::request::types::{
    AttemptState, Phase, RequestOutcome, TerminalOutcome, TerminalSummary,
};
use crate::time::TimestampMs;

impl RequestMachine {
    pub(super) fn on_fund_authorized(
        &mut self,
        attempt: AttemptId,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        if self.funding != Some(attempt) {
            return Err(self.phase_mismatch("fund_authorized"));
        }
        match self.phase {
            Phase::FundingPrepared { attempt: a } if a == attempt => {
                self.start_authorized = true;
                let rec = self.attempt(attempt)?;
                let lease = rec
                    .lease
                    .ok_or(TransitionError::UnknownAttempt { attempt })?;
                if self.cancel_requested {
                    // Cancel raced the funding transaction: the abort
                    // tombstone is already racing the (never sent) start.
                    self.phase = Phase::AwaitingTerminal { attempt };
                    return Ok(());
                }
                self.phase = Phase::Starting { attempt };
                effects.push(Effect::SendStart { attempt, lease });
                Ok(())
            }
            // The funding result can legitimately arrive after a timeout,
            // session loss, or cancel already resolved the request.
            Phase::AwaitingTerminal { .. } | Phase::Finalizing | Phase::Finished => {
                self.start_authorized = true;
                Ok(())
            }
            _ => Err(self.phase_mismatch("fund_authorized")),
        }
    }

    pub(super) fn on_fund_failed(
        &mut self,
        attempt: AttemptId,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        if self.funding != Some(attempt) {
            return Err(self.phase_mismatch("fund_failed"));
        }
        match self.phase {
            Phase::FundingPrepared { attempt: a } if a == attempt => {
                // 12.5: abort the prepared lease, release the reservation
                // idempotently. The funding CAS stays consumed — no second
                // funding ever (9.2.3).
                if let Ok(rec) = self.attempt_mut(attempt) {
                    if let Some(lease) = rec.lease {
                        rec.abort_requested = true;
                        effects.push(Effect::AbortLease { attempt, lease });
                    }
                }
                self.fail_request(RequestOutcome::FundingFailed, effects);
                Ok(())
            }
            Phase::AwaitingTerminal { .. } | Phase::Finalizing | Phase::Finished => Ok(()),
            _ => Err(self.phase_mismatch("fund_failed")),
        }
    }

    pub(super) fn on_start_write_unknown(
        &mut self,
        attempt: AttemptId,
    ) -> Result<(), TransitionError> {
        // 9.2.11: an ambiguous start never authorizes an alternate. The
        // caller resends the same idempotent start.
        let _ = self.attempt(attempt)?;
        Ok(())
    }

    pub(super) fn on_start_retry(
        &mut self,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        if let Phase::Starting { attempt } = self.phase {
            if !self.cancel_requested {
                if let Ok(rec) = self.attempt(attempt) {
                    if let Some(lease) = rec.lease {
                        effects.push(Effect::SendStart { attempt, lease });
                    }
                }
            }
        }
        Ok(())
    }

    pub(super) fn on_started_ack(&mut self, attempt: AttemptId) -> Result<(), TransitionError> {
        let rec = self.attempt_mut(attempt)?;
        if rec.state.is_closed() {
            return Ok(());
        }
        rec.state = AttemptState::Started;
        if let Phase::Starting { attempt: a } = self.phase {
            if a == attempt && !self.cancel_requested {
                self.phase = Phase::AwaitingContent { attempt };
            }
        }
        Ok(())
    }

    pub(super) fn on_preamble(&mut self, attempt: AttemptId) -> Result<(), TransitionError> {
        // 9.2.7: role/lifecycle preamble never commits.
        let _ = self.attempt(attempt)?;
        Ok(())
    }

    pub(super) fn on_content(
        &mut self,
        attempt: AttemptId,
        cumulative: Tokens,
    ) -> Result<(), TransitionError> {
        let _ = self.attempt(attempt)?;
        if self.funding != Some(attempt) || !self.start_authorized {
            // Emission without start authorization is a protocol violation
            // (22.3); the caller fences the provider.
            return Err(self.phase_mismatch("content_accepted"));
        }
        self.accepted_checkpoint = self.accepted_checkpoint.max(cumulative);
        if self.committed.is_none() {
            self.committed = Some(attempt);
            if let Ok(rec) = self.attempt_mut(attempt) {
                if !rec.state.is_closed() {
                    rec.state = AttemptState::Started;
                }
            }
            if matches!(
                self.phase,
                Phase::Starting { .. } | Phase::AwaitingContent { .. }
            ) {
                // First content commits the request process-locally; no
                // database write on this path (9.2.7, 12.9).
                self.phase = Phase::Streaming { attempt };
            }
        }
        Ok(())
    }

    pub(super) fn on_terminal(
        &mut self,
        attempt: AttemptId,
        terminal: TerminalSummary,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let idx = self.attempt_index(attempt)?;
        if let Some(existing) = self.attempts[idx].terminal {
            if existing.digest == terminal.digest {
                // Duplicate terminal, same digest: idempotent (12.8).
                return Ok(());
            }
            // Same attempt, different digest: protocol conflict — no money
            // may move (9.3, 10.6).
            effects.push(Effect::RecordTerminalConflict {
                attempt,
                recorded: existing.digest,
                conflicting: terminal.digest,
            });
            return Ok(());
        }

        {
            let rec = &mut self.attempts[idx];
            rec.terminal = Some(terminal);
            rec.state = AttemptState::TerminalRecorded;
            Self::release_permit_once(rec, effects);
        }

        if self.funding == Some(attempt) {
            self.dispose_for_funded_terminal(attempt, terminal, effects);
            return Ok(());
        }

        // Terminal for a non-funded attempt (aborted hedge/loser or session
        // teardown disposition): a lease disposal, never a settlement.
        if self.cancel_requested {
            self.maybe_finish_cancel(effects);
        } else if self.funding.is_none() {
            self.after_pre_start_closure(true, RequestOutcome::ProviderLost, now, effects);
        }
        Ok(())
    }

    fn dispose_for_funded_terminal(
        &mut self,
        attempt: AttemptId,
        terminal: TerminalSummary,
        effects: &mut Vec<Effect>,
    ) {
        if self.money != MoneyState::Held {
            return;
        }
        if self.committed.is_some() {
            // Settlement caps completion usage at the accepted checkpoint
            // (13.6): coordinator pipe acceptance is the billing boundary.
            self.money = MoneyState::Disposing;
            effects.push(Effect::SettleJob {
                attempt,
                terminal,
                accepted_checkpoint: self.accepted_checkpoint,
            });
            let outcome = match terminal.outcome {
                TerminalOutcome::Completed => RequestOutcome::Completed,
                TerminalOutcome::Cancelled => RequestOutcome::Cancelled,
                TerminalOutcome::Error(class) => RequestOutcome::ProviderError { class },
            };
            self.complete_once(outcome, effects);
            self.phase = Phase::Finalizing;
            return;
        }
        // Terminal before any accepted content: the consumer received
        // nothing, so the reservation is released in full (13.4 zero-output
        // terminal path). A late-generation claim cannot bill: the accepted
        // checkpoint is zero.
        let outcome = match terminal.outcome {
            TerminalOutcome::Cancelled => RequestOutcome::Cancelled,
            TerminalOutcome::Error(class) => RequestOutcome::ProviderError { class },
            TerminalOutcome::Completed => RequestOutcome::ProviderError {
                class: ProviderErrorClass::Fault,
            },
        };
        self.complete_once(outcome, effects);
        self.dispose_release(effects);
    }

    pub(super) fn on_disposition_recorded(&mut self, settled: bool) -> Result<(), TransitionError> {
        if !matches!(self.phase, Phase::Finalizing) || self.money != MoneyState::Disposing {
            if matches!(self.phase, Phase::Finished) {
                return Ok(());
            }
            return Err(self.phase_mismatch("disposition_recorded"));
        }
        self.money = MoneyState::Disposed;
        if settled {
            if let Some(funded) = self.funding {
                if let Ok(rec) = self.attempt_mut(funded) {
                    if matches!(rec.state, AttemptState::TerminalRecorded) {
                        rec.state = AttemptState::Acknowledged;
                    }
                }
            }
        }
        self.phase = Phase::Finished;
        Ok(())
    }
}
