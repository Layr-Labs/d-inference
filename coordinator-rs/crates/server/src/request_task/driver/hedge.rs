//! The prepare-latency hedge trigger (plan §11.8): bounded-budget token
//! acquisition plus the alternate admission that mints the hedge offer.

use uuid::Uuid;

use darkbloom_core::ids::{AttemptId, ProviderId};
use darkbloom_core::request::{Event, HedgeOffer, Phase};

use crate::contracts::{AdmitOutcome, AdmitRequest};

use super::Driver;

impl Driver {
    /// The prepare-latency hedge trigger (plan §11.8): acquire a token from
    /// the global bounded budget, admit one alternate with the exclusion
    /// set, and hand the pre-authorized offer to the reducer — which either
    /// consumes it (SendPrepare) or returns it (ReturnHedgeOffer).
    pub(super) async fn fire_hedge(&mut self) {
        if !matches!(self.machine.phase(), Phase::Preparing)
            || self.machine.funded_attempt().is_some()
        {
            self.feed_now(Event::HedgeTimerFired { offer: None }).await;
            return;
        }
        let token = match self.deps.hedge_budget.lock() {
            Ok(mut budget) => budget.try_acquire(),
            Err(_) => None,
        };
        let Some(token) = token else {
            // Budget exhausted: degrade to sequential-alternate behavior.
            self.feed_now(Event::HedgeTimerFired { offer: None }).await;
            return;
        };
        let exclude: Vec<ProviderId> = self.machine.attempts().iter().map(|a| a.provider).collect();
        let req = AdmitRequest {
            job: self.req.job,
            model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
            traits: self.request_traits(),
            estimated_prompt_tokens: self.req.estimated_prompt_tokens,
            requested_max_tokens: self.req.requested_max_tokens,
            exclude,
            paid: self.req.paid,
        };
        let offer = match self.deps.fleet.admit(req).await {
            Ok(AdmitOutcome::Grant(grant)) => {
                let attempt = AttemptId::new(Uuid::new_v4());
                let provider = grant.provider;
                self.attempt_permits
                    .insert(attempt, provider, grant.permit_id);
                self.pending_grants.insert(attempt, grant);
                self.hedge_tokens.insert(attempt, token);
                Some(HedgeOffer { attempt, provider })
            }
            _ => {
                if let Ok(mut budget) = self.deps.hedge_budget.lock() {
                    budget.refund(token);
                }
                None
            }
        };
        self.feed_now(Event::HedgeTimerFired { offer }).await;
    }
}
