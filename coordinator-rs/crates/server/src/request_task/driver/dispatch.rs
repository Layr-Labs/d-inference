//! The dispatch/funding effect family: reserve, admission, prepare
//! dispatch, the resize/freeze funding leg, start, and mark-running
//! (plan §12.5, §7.8).

use tokio::sync::mpsc;
use uuid::Uuid;

use darkbloom_core::ids::{AttemptId, LeaseId, ProviderId, SessionEpoch};
use darkbloom_core::money::Tokens;
use darkbloom_core::request::{Event, PreparedFacts};
use darkbloom_core::time::DurationMs;

use crate::contracts::{AdmitOutcome, AdmitRequest, AttemptEvent, AttemptSinks, ProtocolGen};
use crate::request_task::attempt::{new_scope, AttemptRuntime};
use crate::request_task::crypto::AttemptCrypto;
use crate::request_task::funding::{
    reserve_params, resize_freeze_params, FreezeInputs, ReserveInputs,
};

use super::events::WireKind;
use super::Driver;

/// Interval for resending the same idempotent start while its ack is
/// outstanding (plan §10.3).
const START_RETRY_INTERVAL: DurationMs = DurationMs::new(2_000);

impl Driver {
    // ------------------------------------------------------------------
    // Reserve (plan §12.5, step before any provider frame)
    // ------------------------------------------------------------------

    pub(super) async fn reserve(&mut self) {
        let price = {
            let catalog = self.deps.catalog.load();
            catalog.prices.get(&self.req.concrete_model).copied()
        };
        let Some(price) = price else {
            tracing::warn!(job = %self.req.job, "no price card for concrete model");
            self.feed_now(Event::ReserveFailed).await;
            return;
        };
        let params = reserve_params(&ReserveInputs {
            job: self.req.job,
            account: self.req.account,
            api_key: &self.req.api_key,
            public_model: &self.req.public_model,
            concrete_model: &self.req.concrete_model,
            price: &price,
            estimated_prompt_tokens: self.req.estimated_prompt_tokens,
            requested_max_tokens: self.req.requested_max_tokens,
            spend_cap: self.req.spend_cap,
            first_content_deadline_ms: self.first_content_deadline.get(),
            request_deadline_ms: self.total_deadline.get(),
            coordinator_epoch: self.deps.coordinator_epoch,
        });
        let Some(params) = params else {
            self.feed_now(Event::ReserveFailed).await;
            return;
        };
        match self.deps.ledger.reserve(params).await {
            Ok(_) => self.feed_now(Event::ReserveCommitted).await,
            Err(err) => {
                self.ledger_error = Some(err);
                self.feed_now(Event::ReserveFailed).await;
            }
        }
    }

    pub(super) async fn admit(&mut self, exclude: Vec<ProviderId>) {
        let req = AdmitRequest {
            job: self.req.job,
            model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
            traits: self.request_traits(),
            estimated_prompt_tokens: self.req.estimated_prompt_tokens,
            requested_max_tokens: self.req.requested_max_tokens,
            exclude,
            paid: self.req.paid,
        };
        match self.deps.fleet.admit(req).await {
            Ok(AdmitOutcome::Grant(grant)) => {
                if let Ok(mut budget) = self.deps.hedge_budget.lock() {
                    budget.on_admission();
                }
                let attempt = AttemptId::new(Uuid::new_v4());
                let provider = grant.provider;
                self.attempt_permits
                    .insert(attempt, provider, grant.permit_id);
                self.pending_grants.insert(attempt, grant);
                self.push(Event::AdmitGranted { attempt, provider });
            }
            Ok(AdmitOutcome::RetryAfter { reason, delay }) => {
                tracing::debug!(job = %self.req.job, %reason, "admission retry-after");
                self.push(Event::AdmitFailed {
                    retry_after: Some(DurationMs::new(delay.as_millis() as u64)),
                });
            }
            Ok(AdmitOutcome::Reject(reason)) => {
                tracing::debug!(job = %self.req.job, ?reason, "admission rejected");
                self.push(Event::AdmitFailed { retry_after: None });
            }
            Err(_) => {
                // Fleet mailbox full: shed fast (plan §14).
                self.push(Event::AdmitFailed {
                    retry_after: Some(self.deps.admission_config.saturated_delay),
                });
            }
        }
    }

    pub(super) fn request_traits(&self) -> darkbloom_core::fleet::admission::RequestTraits {
        darkbloom_core::fleet::admission::RequestTraits {
            model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
            needs_vision: self.req.needs_vision,
            needs_tools: self.req.needs_tools,
            needs_media: false,
            paid: self.req.paid,
            // Rank on a bounded expectation, never the requested maximum
            // (plan §11.4).
            expected_output_tokens: Tokens::new(
                u32::try_from(self.req.requested_max_tokens.min(256)).unwrap_or(256),
            ),
        }
    }

    pub(super) async fn dispatch_prepare(&mut self, attempt: AttemptId, provider: ProviderId) {
        let Some(grant) = self.pending_grants.remove(&attempt) else {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        };
        // Grant-carried key: frozen by the fleet from the registration that
        // owns the granted session, so key and session epoch always agree.
        let provider_key = grant.provider_public_key_b64.clone();
        if provider_key.is_empty() {
            tracing::warn!(job = %self.req.job, %provider, "no provider encryption key");
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        }
        let session = grant.session.clone();
        let sealed = match session.protocol {
            ProtocolGen::V1 => AttemptCrypto::seal_v1(&provider_key, &self.req.body),
            ProtocolGen::V2 => AttemptCrypto::seal_v2(
                &provider_key,
                &self.deps.encryption.x25519_secret,
                &self.req.body,
            ),
        };
        let Ok((crypto, sealed)) = sealed else {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        };
        let scope = new_scope(
            self.req.job,
            attempt,
            session.epoch,
            self.deps.coordinator_epoch,
            sealed.digest,
        );
        let mut runtime = AttemptRuntime::new(attempt, provider, session.clone(), crypto, scope);
        runtime.predicted_first_content =
            DurationMs::new(grant.predicted_first_content.as_millis() as u64);
        runtime.price = grant.price;
        runtime.beneficiary = grant.beneficiary;
        runtime.permit_id = grant.permit_id;
        runtime.dispatched_at = self.clock.now();

        // Attach the sinks BEFORE the frame can reach the wire so no
        // provider reply is lost.
        let (event_tx, event_rx) = mpsc::channel::<AttemptEvent>(64);
        let (chunk_tx, chunk_rx) = crate::contracts::chunk_pipe(
            self.deps.policy.pipe_max_items,
            self.deps.policy.pipe_max_bytes,
        );
        let sinks = AttemptSinks {
            events: event_tx,
            chunks: chunk_tx,
        };
        if session
            .attach_attempt(runtime.wire_id.clone(), attempt, sinks)
            .await
            .is_err()
        {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        }
        self.spawn_attempt_pump(attempt, event_rx, chunk_rx);

        let now = self.clock.now();
        let frame = match session.protocol {
            ProtocolGen::V1 => Some(runtime.v1_inference_request(&sealed)),
            ProtocolGen::V2 => {
                let budget_ms = now.saturating_until(self.first_content_deadline).get();
                runtime
                    .v2_prepare_frame(
                        &self.req.concrete_model,
                        self.req.requested_max_tokens,
                        budget_ms,
                        &sealed,
                    )
                    .ok()
            }
        };
        let Some(frame) = frame else {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        };
        match session.submit_data(frame) {
            Ok(on_wire) => self.spawn_wire_pump(attempt, WireKind::Prepare, on_wire),
            Err(err) => {
                tracing::debug!(job = %self.req.job, %attempt, %err, "prepare submit failed");
                self.push(Event::PrepareWriteFailed { attempt });
                return;
            }
        }
        if session.protocol == ProtocolGen::V2 {
            // v2 prepare evidence is bounded by the prepare deadline; a v1
            // attempt's evidence is its first chunk, bounded by the shared
            // absolute first-content deadline instead.
            runtime.prepare_deadline_at = Some(now.saturating_add(DurationMs::new(
                self.deps.policy.prepare_deadline.as_millis() as u64,
            )));
            // Arm the prepare-latency hedge for the primary only
            // (plan §11.8). v1 dispatch generates immediately, so hedging a
            // v1 attempt would race two generations — never armed.
            if self.deps.policy.hedge_enabled
                && !self.hedge_fired
                && self.hedge_at.is_none()
                && self.runtimes.is_empty()
            {
                self.hedge_at = Some(now.saturating_add(DurationMs::new(
                    self.deps.policy.hedge_prepare_timeout.as_millis() as u64,
                )));
            }
        }
        self.runtimes.insert(attempt, runtime);
    }

    /// Echoes the fleet-minted permit id back (plan §9.2.10). The reducer
    /// emits the release effect exactly once per attempt, so removal here
    /// cannot orphan a live permit.
    pub(super) fn release_permit(&mut self, attempt: AttemptId) {
        self.pending_grants.remove(&attempt);
        let Some((provider, permit)) = self.attempt_permits.remove(&attempt) else {
            return;
        };
        let _ = self
            .deps
            .fleet
            .commands
            .try_send(crate::contracts::FleetCommand::ReleasePermit { provider, permit });
    }

    /// Funding leg (plan §12.5): the resize/freeze transaction with terms
    /// frozen from the grant's price card. v2 funds the prepared exact
    /// billable input; v1 funds the reserve-estimate facts — the hold is
    /// numerically unchanged (same rounding, same inputs as the reserve),
    /// but the leg still runs because it is what freezes terms and records
    /// the durable `start_authorized` transition the running/settlement
    /// states require (see the module-docs v1 mapping).
    pub(super) async fn fund_and_authorize(
        &mut self,
        attempt: AttemptId,
        lease: LeaseId,
        facts: PreparedFacts,
    ) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            self.push(Event::FundFailed { attempt });
            return;
        };
        let catalog_version = self.deps.catalog.load().version;
        let params = resize_freeze_params(&FreezeInputs {
            job: self.req.job,
            attempt,
            lease,
            provider: runtime.provider,
            account: self.req.account,
            api_key: &self.req.api_key,
            public_model: &self.req.public_model,
            concrete_model: &self.req.concrete_model,
            price: &runtime.price,
            beneficiary: runtime.beneficiary,
            catalog_version,
            facts,
            provider_payout_ppm: self.deps.policy.provider_payout_ppm,
            session_epoch: SessionEpoch::new(runtime.scope.session_epoch.0),
            dispatch_nonce: runtime.scope.dispatch_nonce.0,
            request_digest: runtime.scope.request_digest.0,
            coordinator_epoch: self.deps.coordinator_epoch,
        });
        let Some(params) = params else {
            self.push(Event::FundFailed { attempt });
            return;
        };
        match self.deps.ledger.resize_freeze(params).await {
            Ok(()) => self.push(Event::FundAuthorized { attempt }),
            Err(err) => {
                self.ledger_error = Some(err);
                self.push(Event::FundFailed { attempt });
            }
        }
    }

    pub(super) async fn send_start(&mut self, attempt: AttemptId) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            return;
        };
        if runtime.protocol == ProtocolGen::V1 {
            // v1 has no start frame: the inference_request was the start,
            // and the content already in hand proves emission. The reducer
            // still owns the transition.
            self.mark_running().await;
            self.push(Event::StartedAck { attempt });
            return;
        }
        let frame = runtime.start_frame();
        match runtime.session.submit_control(frame) {
            Ok(on_wire) => {
                self.spawn_wire_pump(attempt, WireKind::Start, on_wire);
                self.start_retry_at = Some(self.clock.now().saturating_add(START_RETRY_INTERVAL));
            }
            Err(_) => self.push(Event::SessionLost { attempt }),
        }
    }

    pub(super) async fn mark_running(&mut self) {
        if self.mark_running_done {
            return;
        }
        self.mark_running_done = true;
        if let Err(err) = self.deps.ledger.mark_running(self.req.job).await {
            tracing::warn!(job = %self.req.job, %err, "mark_running failed");
        }
    }
}
