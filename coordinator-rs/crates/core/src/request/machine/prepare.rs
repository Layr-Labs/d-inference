//! Prepare-stage handlers: write results, prepared leases, rejections, and
//! the hedge trigger (plan 10.3, 11.8, 12.2, 13.2).

use super::RequestMachine;
use crate::ids::{AttemptId, LeaseId};
use crate::provider_error::ProviderErrorClass;
use crate::request::effects::Effect;
use crate::request::errors::TransitionError;
use crate::request::types::{AttemptState, HedgeOffer, Phase, PreparedFacts, RequestOutcome};
use crate::time::TimestampMs;

impl RequestMachine {
    pub(super) fn on_write_confirmed(&mut self, attempt: AttemptId) -> Result<(), TransitionError> {
        let rec = self.attempt_mut(attempt)?;
        if matches!(rec.state, AttemptState::QueuedToSocket) {
            rec.write_confirmed = true;
        }
        Ok(())
    }

    pub(super) fn on_write_failed(
        &mut self,
        attempt: AttemptId,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let rec = self.attempt_mut(attempt)?;
        // A definitive write failure (frame provably never left the
        // coordinator) is only meaningful while the prepare is queued. Once
        // the outcome went ambiguous (`SentUnknown`) the provider may hold
        // the frame, so a later local failure claim cannot un-send it: hold
        // the attempt — no abort, no permit release, no alternate — until
        // provider evidence, lease/permit expiry, or session loss (13.2).
        // Any other state means a prepared lease already exists and the
        // stale failure is contradictory evidence — ignored.
        if !matches!(rec.state, AttemptState::QueuedToSocket) {
            return Ok(());
        }
        rec.state = AttemptState::Aborted;
        Self::release_permit_once(rec, effects);
        self.after_pre_start_closure(true, RequestOutcome::ProviderLost, now, effects);
        Ok(())
    }

    pub(super) fn on_write_unknown(&mut self, attempt: AttemptId) -> Result<(), TransitionError> {
        let rec = self.attempt_mut(attempt)?;
        // 13.2: record ambiguity; no release, no retry, no effects.
        if matches!(rec.state, AttemptState::QueuedToSocket) {
            rec.state = AttemptState::SentUnknown;
        }
        Ok(())
    }

    pub(super) fn on_prepared(
        &mut self,
        attempt: AttemptId,
        lease: LeaseId,
        facts: PreparedFacts,
        hedge_offer: Option<HedgeOffer>,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let idx = self.attempt_index(attempt)?;
        let mut offer = hedge_offer;

        {
            let rec = &mut self.attempts[idx];
            if rec.state.is_closed() {
                // The attempt was already closed locally (timeout, session
                // loss): the late lease must still be disposed (9.2.9).
                effects.push(Effect::AbortLease { attempt, lease });
                Self::return_offer(&mut offer, effects);
                return Ok(());
            }
            if matches!(rec.state, AttemptState::Prepared) {
                // Duplicate prepared: idempotent for the same lease, dispose
                // an unexpected second lease.
                if rec.lease != Some(lease) {
                    effects.push(Effect::AbortLease { attempt, lease });
                }
                Self::return_offer(&mut offer, effects);
                return Ok(());
            }
            if matches!(rec.state, AttemptState::Started) {
                Self::return_offer(&mut offer, effects);
                return Ok(());
            }
            if matches!(self.phase, Phase::Finalizing | Phase::Finished) {
                // The request already resolved (failure, cancel, review):
                // a late lease must be disposed, never funded (9.2.9).
                rec.state = AttemptState::Aborted;
                Self::release_permit_once(rec, effects);
                effects.push(Effect::AbortLease { attempt, lease });
                Self::return_offer(&mut offer, effects);
                return Ok(());
            }
            rec.state = AttemptState::Prepared;
            rec.write_confirmed = true;
            rec.lease = Some(lease);
            rec.facts = Some(facts);
            Self::release_permit_once(rec, effects);
        }

        if self.cancel_requested {
            // 13.3: prepared but not started under cancellation — abort.
            let rec = &mut self.attempts[idx];
            rec.abort_requested = true;
            effects.push(Effect::AbortLease { attempt, lease });
            Self::return_offer(&mut offer, effects);
            return Ok(());
        }

        if self.funding.is_some() {
            // Another attempt already won the funding CAS: this lease loses
            // (11.8, 13.3).
            let rec = &mut self.attempts[idx];
            rec.abort_requested = true;
            effects.push(Effect::AbortLease { attempt, lease });
            Self::return_offer(&mut offer, effects);
            return Ok(());
        }

        let usable = self.facts_meet_first_content_budget(&facts, now);
        if usable {
            // First usable prepared lease wins funding (11.8).
            self.begin_funding(idx, effects);
            Self::return_offer(&mut offer, effects);
            return Ok(());
        }

        // Prepared execution facts fail the remaining first-content budget
        // (10.3, 11.8): hedge if the pre-authorized offer allows it.
        if offer.is_some() && self.hedge_allowed(now) {
            if let Some(o) = offer.take() {
                self.dispatch_hedge(o, effects);
            }
            return Ok(());
        }
        Self::return_offer(&mut offer, effects);

        let others_pending = self.attempts.iter().any(|a| {
            a.id != attempt
                && matches!(
                    a.state,
                    AttemptState::QueuedToSocket | AttemptState::SentUnknown
                )
        });
        if others_pending {
            // A hedge or sibling prepare is still in flight; keep this
            // unusable lease as the fallback and wait.
            return Ok(());
        }

        let other_prepared: Vec<usize> = self
            .attempts
            .iter()
            .enumerate()
            .filter(|(i, a)| {
                *i != idx && matches!(a.state, AttemptState::Prepared) && !a.abort_requested
            })
            .map(|(i, _)| i)
            .collect();
        if !other_prepared.is_empty() {
            // Every outstanding prepare resolved and none met the budget:
            // fund the least-bad ETA rather than failing outright.
            let best = other_prepared
                .into_iter()
                .chain(std::iter::once(idx))
                .min_by_key(|i| {
                    self.attempts[*i]
                        .facts
                        .map_or(u64::MAX, |f| f.first_content_eta.get())
                })
                .unwrap_or(idx);
            self.begin_funding(best, effects);
            return Ok(());
        }

        if self.alternate_allowed(now) {
            // Sole unusable lease: abort and re-route in milliseconds
            // instead of absorbing the first-content penalty (10.3). The
            // alternate dispatches only after abort acknowledgement (13.3).
            let rec = &mut self.attempts[idx];
            rec.abort_requested = true;
            effects.push(Effect::AbortLease { attempt, lease });
            return Ok(());
        }

        // Nothing better is possible: fund the unusable lease best-effort.
        self.begin_funding(idx, effects);
        Ok(())
    }

    pub(super) fn on_prepare_rejected(
        &mut self,
        attempt: AttemptId,
        class: ProviderErrorClass,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let rec = self.attempt_mut(attempt)?;
        // A prepare rejection after the same attempt already delivered a
        // prepared lease is contradictory evidence: the lease is the
        // authority (11.3), so the stale rejection is ignored.
        if !matches!(
            rec.state,
            AttemptState::QueuedToSocket | AttemptState::SentUnknown
        ) {
            return Ok(());
        }
        rec.state = AttemptState::Aborted;
        Self::release_permit_once(rec, effects);

        if !class.allows_pre_start_alternate() {
            // Deterministic (invalid_request) or security rejection: retry
            // would fail identically or the provider is fenced (10.5).
            if !self.cancel_requested && self.funding.is_none() {
                self.abort_open_attempts(effects);
                self.fail_request(RequestOutcome::ProviderRejected { class }, effects);
            } else {
                self.maybe_finish_cancel(effects);
            }
            return Ok(());
        }
        self.after_pre_start_closure(
            true,
            RequestOutcome::ProviderRejected { class },
            now,
            effects,
        );
        Ok(())
    }

    pub(super) fn on_hedge_timer(
        &mut self,
        offer: Option<HedgeOffer>,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        let mut offer = offer;
        let primary_pending = self.attempts.iter().any(|a| {
            matches!(
                a.state,
                AttemptState::QueuedToSocket | AttemptState::SentUnknown
            )
        });
        if matches!(self.phase, Phase::Preparing) && primary_pending && self.hedge_allowed(now) {
            if let Some(o) = offer.take() {
                self.dispatch_hedge(o, effects);
                return Ok(());
            }
            // Budget exhausted: degrade to sequential-alternate behavior
            // (11.8) — nothing to do until real evidence arrives.
            return Ok(());
        }
        Self::return_offer(&mut offer, effects);
        Ok(())
    }
}
