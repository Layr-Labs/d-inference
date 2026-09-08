//! Shared one-shot transitions (funding CAS, money disposition, consumer
//! answer), the pre-start closure policy, and pure guards/lookups.

use super::{MoneyState, RequestMachine, MAX_ATTEMPTS};
use crate::ids::AttemptId;
use crate::request::effects::Effect;
use crate::request::errors::TransitionError;
use crate::request::types::{
    AttemptKind, AttemptRecord, AttemptState, HedgeOffer, Phase, PreparedFacts, RequestOutcome,
    ReviewReason,
};
use crate::time::TimestampMs;

impl RequestMachine {
    /// The funding compare-and-swap (9.2.3, 9.2.6): callers must check
    /// `self.funding.is_none()` first; this sets it exactly once and emits
    /// the fund/freeze transaction plus loser aborts.
    pub(super) fn begin_funding(&mut self, idx: usize, effects: &mut Vec<Effect>) {
        debug_assert!(self.funding.is_none(), "funding CAS must fire at most once");
        let attempt = self.attempts[idx].id;
        let (Some(lease), Some(facts)) = (self.attempts[idx].lease, self.attempts[idx].facts)
        else {
            return;
        };
        self.funding = Some(attempt);
        self.phase = Phase::FundingPrepared { attempt };
        effects.push(Effect::FundAndAuthorize {
            attempt,
            lease,
            facts,
        });
        // Losing prepared leases are aborted now (11.8); still-pending
        // prepares are aborted when their lease arrives.
        for i in 0..self.attempts.len() {
            if i == idx {
                continue;
            }
            let rec = &mut self.attempts[i];
            if matches!(rec.state, AttemptState::Prepared) && !rec.abort_requested {
                rec.abort_requested = true;
                if let Some(l) = rec.lease {
                    effects.push(Effect::AbortLease {
                        attempt: rec.id,
                        lease: l,
                    });
                }
            }
        }
    }

    pub(super) fn dispatch_hedge(&mut self, offer: HedgeOffer, effects: &mut Vec<Effect>) {
        self.hedge_used = true;
        self.attempts.push(AttemptRecord::new(
            offer.attempt,
            offer.provider,
            AttemptKind::Hedge,
        ));
        self.attempted_providers.insert(offer.provider);
        effects.push(Effect::SendPrepare {
            attempt: offer.attempt,
            provider: offer.provider,
        });
    }

    /// After a pre-funding attempt closed: wait if a sibling can still win,
    /// fund a remaining (even unusable) prepared lease if one is left,
    /// otherwise take the single sequential alternate or fail the request.
    pub(super) fn after_pre_start_closure(
        &mut self,
        alternate_legal: bool,
        fail_outcome: RequestOutcome,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) {
        if matches!(self.phase, Phase::Finalizing | Phase::Finished) {
            return;
        }
        if self.cancel_requested {
            self.maybe_finish_cancel(effects);
            return;
        }
        if self.funding.is_some() {
            return;
        }
        let mut fundable: Option<usize> = None;
        for (i, rec) in self.attempts.iter().enumerate() {
            if rec.state.is_closed() {
                continue;
            }
            match rec.state {
                AttemptState::Prepared if !rec.abort_requested => {
                    // A held lease that lost its sibling: fund the best of
                    // what remains rather than stranding it.
                    let eta = rec.facts.map_or(u64::MAX, |f| f.first_content_eta.get());
                    let best = fundable.map_or(u64::MAX, |b| {
                        self.attempts[b]
                            .facts
                            .map_or(u64::MAX, |f| f.first_content_eta.get())
                    });
                    if eta < best || fundable.is_none() {
                        fundable = Some(i);
                    }
                }
                // A prepare still in flight (or an abort awaiting its ack)
                // can still resolve this request; wait for its evidence.
                _ => return,
            }
        }
        if let Some(idx) = fundable {
            self.begin_funding(idx, effects);
            return;
        }
        if alternate_legal && self.alternate_allowed(now) {
            self.alternate_used = true;
            self.phase = Phase::Admitting;
            effects.push(Effect::RequestAdmission {
                exclude: self.attempted_providers.clone(),
            });
            return;
        }
        self.fail_request(fail_outcome, effects);
    }

    /// Abort every open prepared lease and discard/permit-release every
    /// pending attempt (deterministic-failure teardown).
    pub(super) fn abort_open_attempts(&mut self, effects: &mut Vec<Effect>) {
        for i in 0..self.attempts.len() {
            let rec = &mut self.attempts[i];
            match rec.state {
                AttemptState::Prepared if !rec.abort_requested => {
                    rec.abort_requested = true;
                    if let Some(lease) = rec.lease {
                        effects.push(Effect::AbortLease {
                            attempt: rec.id,
                            lease,
                        });
                    }
                }
                AttemptState::QueuedToSocket if !rec.write_confirmed => {
                    let id = rec.id;
                    rec.state = AttemptState::Aborted;
                    effects.push(Effect::DiscardQueuedFrame { attempt: id });
                    Self::release_permit_once(rec, effects);
                }
                _ => {}
            }
        }
    }

    /// Terminal failure before commitment: release money (if held), answer
    /// the consumer, finalize.
    pub(super) fn fail_request(&mut self, outcome: RequestOutcome, effects: &mut Vec<Effect>) {
        if matches!(self.phase, Phase::Finalizing | Phase::Finished) {
            return;
        }
        self.complete_once(outcome, effects);
        if self.money == MoneyState::Held {
            self.dispose_release(effects);
        } else {
            self.phase = Phase::Finished;
        }
    }

    pub(super) fn dispose_release(&mut self, effects: &mut Vec<Effect>) {
        if self.money == MoneyState::Held {
            self.money = MoneyState::Disposing;
            effects.push(Effect::ReleaseJob);
            self.phase = Phase::Finalizing;
        }
    }

    pub(super) fn dispose_review(&mut self, reason: ReviewReason, effects: &mut Vec<Effect>) {
        if self.money == MoneyState::Held {
            self.money = MoneyState::Disposing;
            effects.push(Effect::EscalateReview { reason });
            self.phase = Phase::Finalizing;
        }
    }

    pub(super) fn complete_once(&mut self, outcome: RequestOutcome, effects: &mut Vec<Effect>) {
        if !self.consumer_answered {
            self.consumer_answered = true;
            effects.push(Effect::CompleteRequest { outcome });
        }
    }

    pub(super) fn release_permit_once(rec: &mut AttemptRecord, effects: &mut Vec<Effect>) {
        if !rec.permit_released {
            rec.permit_released = true;
            effects.push(Effect::ReleasePermit { attempt: rec.id });
        }
    }

    pub(super) fn return_offer(offer: &mut Option<HedgeOffer>, effects: &mut Vec<Effect>) {
        if let Some(o) = offer.take() {
            effects.push(Effect::ReturnHedgeOffer {
                attempt: o.attempt,
                provider: o.provider,
            });
        }
    }

    pub(super) fn facts_meet_first_content_budget(
        &self,
        facts: &PreparedFacts,
        now: TimestampMs,
    ) -> bool {
        // 9.2.5: the deadline is absolute and shared; a prepared ETA that
        // cannot land inside it is grounds for re-route (10.3, 11.8).
        now.checked_add(facts.first_content_eta)
            .is_some_and(|eta| eta <= self.deadlines.first_content)
    }

    /// One sequential alternate, pre-funding only, inside the deadline
    /// (9.2.4, 11.8).
    pub(super) fn alternate_allowed(&self, now: TimestampMs) -> bool {
        self.funding.is_none()
            && !self.start_authorized
            && !self.alternate_used
            && !self.cancel_requested
            && self.attempts.len() < MAX_ATTEMPTS
            && now < self.deadlines.first_content
    }

    /// One concurrent prepare hedge, pre-funding only, inside the deadline
    /// (9.2.4, 11.8).
    pub(super) fn hedge_allowed(&self, now: TimestampMs) -> bool {
        self.funding.is_none()
            && !self.start_authorized
            && !self.hedge_used
            && !self.cancel_requested
            && self.attempts.len() < MAX_ATTEMPTS
            && now < self.deadlines.first_content
    }

    pub(super) fn attempt_index(&self, attempt: AttemptId) -> Result<usize, TransitionError> {
        self.attempts
            .iter()
            .position(|a| a.id == attempt)
            .ok_or(TransitionError::UnknownAttempt { attempt })
    }

    pub(super) fn attempt(&self, attempt: AttemptId) -> Result<&AttemptRecord, TransitionError> {
        self.attempts
            .iter()
            .find(|a| a.id == attempt)
            .ok_or(TransitionError::UnknownAttempt { attempt })
    }

    pub(super) fn attempt_mut(
        &mut self,
        attempt: AttemptId,
    ) -> Result<&mut AttemptRecord, TransitionError> {
        self.attempts
            .iter_mut()
            .find(|a| a.id == attempt)
            .ok_or(TransitionError::UnknownAttempt { attempt })
    }

    pub(super) fn phase_mismatch(&self, event: &'static str) -> TransitionError {
        TransitionError::PhaseMismatch {
            phase: self.phase.name(),
            event,
        }
    }
}
