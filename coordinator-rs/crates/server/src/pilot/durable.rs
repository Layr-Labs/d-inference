use std::{sync::Arc, time::Duration};

use darkbloom_coordinator_core::{
    ids::{Digest as CoreDigest, ModelId},
    money::MicroUsd,
    request::AttemptKind,
    terminal::TerminalDisposition as CoreTerminalDisposition,
};
use darkbloom_coordinator_protocol::v2::{
    AttemptIdentity, Prepared, ProviderTerminal, StructuredErrorClass, TerminalDisposition,
    TerminalOutcome,
};
use sha2::Digest as _;
use uuid::Uuid;

use crate::{
    ledger::{
        AttemptState as DurableAttemptState, DurableAttemptIdentity, DurableAttemptKind,
        JobState as DurableJobState, MutationDisposition, PreparedReservation, ReleaseRequest,
        ReservationId, ReservationResult, ReserveRequest, SettleRequest, StartDispatchDisposition,
        StartDispatchRequest, TerminalFacts, TerminalOutcome as DurableTerminalOutcome, Version,
    },
    request::VerifiedTerminal,
};

use super::{
    billing::{BillingContext, DurableRequestIdentity},
    request::{AttemptPlan, ExecutionLeaseRenewal, PilotRequestError},
    runtime::DurablePilotServices,
};

const EXECUTION_LEASE_DURATION: Duration = Duration::from_secs(30);

struct AuthorizedDurableAttempt {
    job_version: Version,
    job_state: DurableJobState,
    attempt_id: crate::ledger::AttemptId,
    attempt_version: Version,
    attempt_state: DurableAttemptState,
}

/// Database-backed money and execution state for one pilot request.
///
/// Free self-route requests retain this shape but every method becomes an
/// explicit no-op. Paid requests cannot construct this value without healthy
/// ownership and the complete durable billing service.
pub(super) struct DurableExecution {
    identity: DurableRequestIdentity,
    consumer: BillingContext,
    services: Option<DurablePilotServices>,
    reservation: Option<ReservationResult>,
    authorized: Option<AuthorizedDurableAttempt>,
    authorization_uncertain: bool,
    review_pending: bool,
    execution_worker_id: Option<Uuid>,
}

impl DurableExecution {
    pub(super) fn new(
        identity: DurableRequestIdentity,
        consumer: BillingContext,
        services: Option<DurablePilotServices>,
    ) -> Result<Self, PilotRequestError> {
        match (&consumer, &services) {
            (BillingContext::FreeSelfRoute, _) => {}
            (BillingContext::Paid(_), Some(services))
                if services.billing.is_some() && services.ownership.is_healthy() => {}
            (BillingContext::Paid(_), _) => {
                return Err(PilotRequestError::Unavailable(Arc::from(
                    "paid pilot durability is unavailable",
                )));
            }
        }
        let execution_worker_id = consumer.is_paid().then(|| identity.execution_worker_id());
        Ok(Self {
            identity,
            consumer,
            services,
            reservation: None,
            authorized: None,
            authorization_uncertain: false,
            review_pending: false,
            execution_worker_id,
        })
    }

    #[must_use]
    pub(super) fn is_paid(&self) -> bool {
        self.consumer.is_paid()
    }

    #[must_use]
    pub(super) fn is_authorized(&self) -> bool {
        self.authorized.is_some() || self.authorization_uncertain || self.review_pending
    }

    #[must_use]
    pub(super) fn job_id(&self) -> crate::ledger::JobId {
        self.identity.job_id
    }

    pub(super) fn execution_lease_renewal(&self) -> Option<ExecutionLeaseRenewal> {
        let services = self.services.as_ref()?;
        let worker_id = self.execution_worker_id?;
        self.reservation.as_ref()?;
        Some(ExecutionLeaseRenewal {
            ledger: services.ledger.clone(),
            job_id: self.identity.job_id,
            worker_id,
            lease_for: EXECUTION_LEASE_DURATION,
        })
    }

    pub(super) async fn ensure_provider_trusted(
        &self,
        identity: &AttemptIdentity,
    ) -> Result<(), PilotRequestError> {
        let Some(services) = &self.services else {
            return Ok(());
        };
        services
            .ledger
            .ensure_provider_trusted(
                uuid_from_wire(identity.provider_id.as_bytes()),
                Version::new(identity.session_epoch.0).map_err(map_ledger_input)?,
            )
            .await
            .map_err(map_ledger_error)
    }

    pub(super) async fn reserve(
        &mut self,
        plan: &AttemptPlan,
        model: &ModelId,
        plaintext: &[u8],
        request_deadline_epoch_millis: u64,
    ) -> Result<(), PilotRequestError> {
        if let Some(services) = &self.services {
            services
                .ledger
                .ensure_provider_trusted(
                    uuid_from_wire(plan.session.identity.provider_id.as_bytes()),
                    Version::new(plan.session.identity.session_epoch.0)
                        .map_err(map_ledger_input)?,
                )
                .await
                .map_err(map_ledger_error)?;
        }
        let BillingContext::Paid(consumer) = &self.consumer else {
            return Ok(());
        };
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let billing = services
            .billing
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("billing unavailable")))?;
        let body_digest: [u8; 32] = sha2::Sha256::digest(plaintext).into();
        let immutable = serde_json::to_vec(&serde_json::json!({
            "account_id": consumer.account_id.as_str(),
            "api_key_id": consumer.api_key_id.as_ref(),
            "base_reservation": billing.policy().base_reservation.as_i64(),
            "body_digest": body_digest,
            "consumer_key_hash": consumer.consumer_key_hash.as_ref(),
            "job_id": self.identity.job_id.as_uuid(),
            "model": model.as_str(),
            "provisional_provider_id": plan.session.identity.provider_id,
            "provisional_session_epoch": plan.session.identity.session_epoch.0,
            "request_id": self.identity.request_id,
            "reservation_id": self.identity.reservation_id.as_uuid(),
            "request_deadline_epoch_millis": request_deadline_epoch_millis,
            "execution_worker_id": self.execution_worker_id,
        }))
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
        let request = ReserveRequest {
            operation: self
                .identity
                .operation("reserve", &immutable)
                .map_err(map_ledger_input)?,
            job_id: self.identity.job_id,
            request_id: self.identity.request_id,
            reservation_id: self.identity.reservation_id,
            account_id: consumer.account_id.clone(),
            api_key_id: consumer.api_key_id.clone(),
            consumer_key_hash: consumer.consumer_key_hash.clone(),
            amount: billing.policy().base_reservation,
            request_deadline_epoch_millis,
            execution_worker_id: self.execution_worker_id,
            execution_lease_millis: Some(
                u64::try_from(EXECUTION_LEASE_DURATION.as_millis())
                    .expect("bounded execution lease fits u64"),
            ),
            provisional_provider_id: Some(uuid_from_wire(
                plan.session.identity.provider_id.as_bytes(),
            )),
            provisional_session_epoch: Some(
                Version::new(plan.session.identity.session_epoch.0).map_err(map_ledger_input)?,
            ),
        };
        let reservation = services
            .ledger
            .reserve(&request)
            .await
            .map_err(map_ledger_error)?;
        if reservation.disposition == MutationDisposition::Replayed {
            self.authorization_uncertain = true;
            return Err(PilotRequestError::Unavailable(Arc::from(
                "durable request already exists; recovery owns its disposition",
            )));
        }
        self.reservation = Some(reservation);
        Ok(())
    }

    pub(super) async fn authorize(
        &mut self,
        plan: &AttemptPlan,
        prepared: &Prepared,
        kind: AttemptKind,
        attempt_ordinal: u8,
        start_deadline: Duration,
    ) -> Result<(), PilotRequestError> {
        if !self.is_paid() {
            return Ok(());
        }
        let BillingContext::Paid(consumer) = &self.consumer else {
            unreachable!("paid mode checked");
        };
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let billing = services
            .billing
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("billing unavailable")))?;
        let reservation = self.reservation.as_ref().ok_or_else(|| {
            PilotRequestError::Internal(Arc::from("authorization preceded durable reserve"))
        })?;
        let provider_id = uuid_from_wire(prepared.identity.provider_id.as_bytes());
        let process_generation =
            uuid_from_wire(prepared.identity.provider_process_generation.as_bytes());
        let session_epoch =
            Version::new(prepared.identity.session_epoch.0).map_err(map_ledger_input)?;
        services
            .ledger
            .ensure_provider_trusted(provider_id, session_epoch)
            .await
            .map_err(map_ledger_error)?;
        let provider_account = billing
            .provider_account(prepared.identity.provider_id)
            .ok_or_else(|| {
                PilotRequestError::Unavailable(Arc::from(
                    "provider beneficiary account is not configured",
                ))
            })?
            .clone();
        let amounts = billing
            .amounts(prepared.prompt_tokens, prepared.max_output_tokens)
            .map_err(map_ledger_input)?;
        let attempt_id = self
            .identity
            .attempt_id(attempt_ordinal, prepared.identity.provider_id)
            .map_err(map_ledger_input)?;
        if attempt_id.as_uuid().as_bytes() != prepared.identity.attempt_id.as_bytes() {
            return Err(PilotRequestError::Protocol(Arc::from(
                "prepared attempt differs from deterministic durable identity",
            )));
        }
        let immutable = serde_json::to_vec(&serde_json::json!({
            "account_id": consumer.account_id.as_str(),
            "api_key_id": consumer.api_key_id.as_ref(),
            "attempt_id": attempt_id.as_uuid(),
            "attempt_kind": match kind {
                AttemptKind::Primary => "primary",
                AttemptKind::Alternate => "alternate",
                AttemptKind::Hedge => "hedge",
            },
            "consumer_key_hash": consumer.consumer_key_hash.as_ref(),
            "dispatch_nonce": self.identity.dispatch_nonce(
                attempt_ordinal,
                prepared.identity.provider_id
            ).as_bytes(),
            "input_micro_usd_per_million":
                billing.policy().input_micro_usd_per_million.as_i64(),
            "job_id": self.identity.job_id.as_uuid(),
            "lease_id": uuid_from_wire(prepared.identity.lease_id.as_bytes()),
            "maximum_platform_fee": amounts.platform_fee.as_i64(),
            "maximum_provider_payout": amounts.provider_payout.as_i64(),
            "maximum_referral_reward": amounts.referral_reward.as_i64(),
            "output_micro_usd_per_million":
                billing.policy().output_micro_usd_per_million.as_i64(),
            "permit_id": plan.lease.permit_id().as_uuid(),
            "platform_account_id": billing.policy().platform_account_id.as_str(),
            "prepared": prepared,
            "pricing_version": billing.policy().pricing_version.as_i64(),
            "provider_account_id": provider_account.as_str(),
            "provider_share_ppm": billing.policy().provider_share_ppm,
            "public_model": plan.prepare.model.as_str(),
            "referral_account_id": billing
                .policy()
                .referral_account_id
                .as_ref()
                .map(crate::ledger::AccountId::as_str),
            "referral_share_ppm": billing.policy().referral_share_ppm,
            "rounding_version": billing.policy().rounding_version.as_i64(),
        }))
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
        let request = PreparedReservation {
            operation: self
                .identity
                .operation("authorize", &immutable)
                .map_err(map_ledger_input)?,
            job_id: self.identity.job_id,
            expected_version: reservation.version,
            expected_state: reservation.state,
            attempt_id,
            attempt_kind: match kind {
                AttemptKind::Primary => DurableAttemptKind::Primary,
                AttemptKind::Alternate => DurableAttemptKind::Alternate,
                AttemptKind::Hedge => DurableAttemptKind::Hedge,
            },
            provider_id,
            provider_process_generation_id: process_generation,
            session_epoch,
            lease_id: uuid_from_wire(prepared.identity.lease_id.as_bytes()),
            permit_id: plan.lease.permit_id().as_uuid(),
            dispatch_nonce: self
                .identity
                .dispatch_nonce(attempt_ordinal, prepared.identity.provider_id),
            request_digest: CoreDigest::new(*prepared.request_digest.as_bytes()),
            concrete_model: Arc::from(prepared.model.as_str()),
            public_model: Arc::from(plan.prepare.model.as_str()),
            pricing_version: billing.policy().pricing_version,
            rounding_version: billing.policy().rounding_version,
            billable_input_tokens: prepared.prompt_tokens,
            bounded_output_tokens: prepared.max_output_tokens,
            input_micro_usd_per_million: billing.policy().input_micro_usd_per_million,
            output_micro_usd_per_million: billing.policy().output_micro_usd_per_million,
            provider_account_id: provider_account,
            platform_account_id: billing.policy().platform_account_id.clone(),
            referral_account_id: billing.policy().referral_account_id.clone(),
            maximum_provider_payout: amounts.provider_payout,
            maximum_platform_fee: amounts.platform_fee,
            maximum_referral_reward: amounts.referral_reward,
            provider_share_ppm: billing.policy().provider_share_ppm,
            referral_share_ppm: billing.policy().referral_share_ppm,
            execution_worker_id: self.execution_worker_id,
            start_deadline_millis: u64::try_from(start_deadline.as_millis())
                .map_err(|_| map_ledger_input(crate::ledger::InputError::ArithmeticOverflow))?,
        };
        let result = match services.ledger.resize_and_authorize(&request).await {
            Ok(result) => result,
            Err(error) => return Err(self.authorization_error(error)),
        };
        self.authorized = Some(AuthorizedDurableAttempt {
            job_version: result.version,
            job_state: result.state,
            attempt_id,
            attempt_version: Version::new(1).expect("one is a valid version"),
            attempt_state: DurableAttemptState::NotSent,
        });
        // Immutable consumer context is deliberately used above and retained
        // for settlement; no transport credential can replace it.
        let _ = consumer;
        Ok(())
    }

    fn authorization_error(&mut self, error: crate::ledger::LedgerError) -> PilotRequestError {
        if matches!(
            error,
            crate::ledger::LedgerError::CommitOutcomeUnknown { .. }
        ) {
            self.authorization_uncertain = true;
            PilotRequestError::Unavailable(Arc::from(format!(
                "start authorization commit outcome is unknown; recovery owns the job: {error}"
            )))
        } else {
            map_ledger_error(error)
        }
    }

    pub(super) async fn record_start_dispatch(
        &mut self,
        disposition: StartDispatchDisposition,
    ) -> Result<(), PilotRequestError> {
        if !self.is_paid() {
            return Ok(());
        }
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let authorized = self.authorized.as_mut().ok_or_else(|| {
            PilotRequestError::Internal(Arc::from("start dispatch preceded authorization"))
        })?;
        let result = services
            .ledger
            .record_start_dispatch(&StartDispatchRequest {
                job_id: self.identity.job_id,
                expected_job_version: authorized.job_version,
                expected_job_state: authorized.job_state,
                attempt_id: authorized.attempt_id,
                expected_attempt_version: authorized.attempt_version,
                expected_attempt_state: authorized.attempt_state,
                disposition,
            })
            .await
            .map_err(map_ledger_error)?;
        authorized.job_version = result.job_version;
        authorized.job_state = result.job_state;
        authorized.attempt_version = result.attempt_version;
        authorized.attempt_state = result.attempt_state;
        Ok(())
    }

    pub(super) async fn review_provider(
        &mut self,
        identity: &AttemptIdentity,
        reason: &'static str,
        evidence: &[u8],
        accepted_cumulative_tokens: u64,
    ) -> Result<(), PilotRequestError> {
        if !self.is_paid() {
            return Ok(());
        }
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let (expected_version, expected_state) = if let Some(authorized) = &self.authorized {
            (authorized.job_version, authorized.job_state)
        } else {
            let reservation = self.reservation.as_ref().ok_or_else(|| {
                PilotRequestError::Internal(Arc::from("review preceded durable reserve"))
            })?;
            (reservation.version, reservation.state)
        };
        let review = crate::ledger::ReviewRequest {
            job_id: self.identity.job_id,
            expected_version,
            expected_state,
            provider_id: uuid_from_wire(identity.provider_id.as_bytes()),
            hard_untrust_epoch: Version::new(identity.session_epoch.0).map_err(map_ledger_input)?,
            accepted_cumulative_tokens,
            reason: Arc::from(reason),
            evidence_digest: CoreDigest::new(sha2::Sha256::digest(evidence).into()),
        };
        let next = services
            .ledger
            .move_to_review(&review)
            .await
            .map_err(map_ledger_error)?;
        self.review_pending = true;
        if let Some(authorized) = &mut self.authorized {
            authorized.job_version = next;
            authorized.job_state = DurableJobState::ReviewPending;
        } else if let Some(reservation) = &mut self.reservation {
            reservation.version = next;
            reservation.state = DurableJobState::ReviewPending;
        }
        Ok(())
    }

    pub(super) async fn lookup_terminal(
        &self,
        terminal: &ProviderTerminal,
    ) -> Result<crate::ledger::TerminalLookup, PilotRequestError> {
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let authorized = self.authorized.as_ref().ok_or_else(|| {
            PilotRequestError::Internal(Arc::from("terminal preceded authorization"))
        })?;
        services
            .ledger
            .lookup_terminal(
                DurableAttemptIdentity {
                    request_id: uuid_from_wire(terminal.identity.request_id.as_bytes()),
                    reservation_id: ReservationId::new(uuid_from_wire(
                        terminal.identity.reservation_id.as_bytes(),
                    ))
                    .map_err(map_ledger_input)?,
                    attempt_id: authorized.attempt_id,
                    provider_id: uuid_from_wire(terminal.identity.provider_id.as_bytes()),
                    provider_process_generation_id: uuid_from_wire(
                        terminal.identity.provider_process_generation.as_bytes(),
                    ),
                    session_epoch: Version::new(terminal.identity.session_epoch.0)
                        .map_err(map_ledger_input)?,
                    lease_id: uuid_from_wire(terminal.identity.lease_id.as_bytes()),
                },
                CoreDigest::new(*terminal.terminal_digest.as_bytes()),
            )
            .await
            .map_err(map_ledger_error)
    }

    pub(super) async fn persist_terminal_conflict(
        &mut self,
        terminal: &ProviderTerminal,
        reason: &'static str,
        accepted_cumulative_tokens: u64,
    ) -> Result<(), PilotRequestError> {
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let authorized = self.authorized.as_ref().ok_or_else(|| {
            PilotRequestError::Internal(Arc::from("terminal preceded authorization"))
        })?;
        let raw_terminal = serde_json::to_value(terminal)
            .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
        services
            .ledger
            .record_terminal_conflict(
                self.identity.job_id,
                authorized.attempt_id,
                &TerminalFacts {
                    terminal_id: self
                        .identity
                        .terminal_id(terminal.terminal_digest.as_bytes())
                        .map_err(map_ledger_input)?,
                    attempt_id: authorized.attempt_id,
                    provider_id: uuid_from_wire(terminal.identity.provider_id.as_bytes()),
                    provider_process_generation_id: uuid_from_wire(
                        terminal.identity.provider_process_generation.as_bytes(),
                    ),
                    origin_session_epoch: Version::new(terminal.identity.session_epoch.0)
                        .map_err(map_ledger_input)?,
                    terminal_digest: CoreDigest::new(*terminal.terminal_digest.as_bytes()),
                    raw_terminal,
                    outcome: match terminal.outcome {
                        TerminalOutcome::Completed => DurableTerminalOutcome::Completed,
                        TerminalOutcome::Cancelled => DurableTerminalOutcome::Cancelled,
                        TerminalOutcome::Error => DurableTerminalOutcome::Error,
                    },
                    error_class: terminal
                        .error_class
                        .map(|class| Arc::from(structured_error_class_name(class))),
                    prompt_tokens: terminal.prompt_tokens,
                    completion_tokens: terminal.completion_tokens,
                    reasoning_tokens: terminal.reasoning_tokens,
                    response_digest: CoreDigest::new(*terminal.response_hash.as_bytes()),
                    rolling_digest: CoreDigest::new(*terminal.rolling_digest.as_bytes()),
                    final_generated_tokens: terminal.final_generated_tokens,
                    provider_signature: terminal.signature.as_bytes().to_vec(),
                    recovery_lease: None,
                },
                reason,
                accepted_cumulative_tokens,
            )
            .await
            .map_err(map_ledger_error)?;
        self.review_pending = true;
        Ok(())
    }

    pub(super) async fn settle(
        &mut self,
        terminal: &ProviderTerminal,
        summary: VerifiedTerminal,
    ) -> Result<TerminalDisposition, PilotRequestError> {
        if let Some(services) = &self.services {
            services
                .ledger
                .ensure_provider_trusted(
                    uuid_from_wire(terminal.identity.provider_id.as_bytes()),
                    Version::new(terminal.identity.session_epoch.0).map_err(map_ledger_input)?,
                )
                .await
                .map_err(map_ledger_error)?;
        }
        if !self.is_paid() {
            return Ok(match terminal.outcome {
                TerminalOutcome::Completed => TerminalDisposition::Settled,
                TerminalOutcome::Cancelled | TerminalOutcome::Error => {
                    TerminalDisposition::Released
                }
            });
        }
        if self.authorized.as_ref().is_some_and(|attempt| {
            matches!(
                attempt.attempt_state,
                DurableAttemptState::Queued
                    | DurableAttemptState::OnWire
                    | DurableAttemptState::SentUnknown
            )
        }) {
            self.record_start_dispatch(StartDispatchDisposition::Running)
                .await?;
        }
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let authorized = self.authorized.as_ref().ok_or_else(|| {
            PilotRequestError::Internal(Arc::from("terminal preceded authorization"))
        })?;
        let provider_id = uuid_from_wire(terminal.identity.provider_id.as_bytes());
        let process_generation =
            uuid_from_wire(terminal.identity.provider_process_generation.as_bytes());
        let session_epoch =
            Version::new(terminal.identity.session_epoch.0).map_err(map_ledger_input)?;
        let raw_terminal = serde_json::to_value(terminal)
            .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
        let immutable = serde_json::to_vec(&raw_terminal)
            .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
        if terminal.outcome != TerminalOutcome::Completed {
            let request = crate::ledger::TerminalReleaseRequest {
                operation: self
                    .identity
                    .operation("terminal-release", &immutable)
                    .map_err(map_ledger_input)?,
                job_id: self.identity.job_id,
                expected_job_version: authorized.job_version,
                expected_job_state: authorized.job_state,
                expected_attempt_version: authorized.attempt_version,
                terminal: TerminalFacts {
                    terminal_id: self
                        .identity
                        .terminal_id(terminal.terminal_digest.as_bytes())
                        .map_err(map_ledger_input)?,
                    attempt_id: authorized.attempt_id,
                    provider_id,
                    provider_process_generation_id: process_generation,
                    origin_session_epoch: session_epoch,
                    terminal_digest: CoreDigest::new(*terminal.terminal_digest.as_bytes()),
                    raw_terminal,
                    outcome: match terminal.outcome {
                        TerminalOutcome::Cancelled => DurableTerminalOutcome::Cancelled,
                        TerminalOutcome::Error => DurableTerminalOutcome::Error,
                        TerminalOutcome::Completed => unreachable!("handled above"),
                    },
                    error_class: terminal
                        .error_class
                        .map(|class| Arc::from(structured_error_class_name(class))),
                    prompt_tokens: terminal.prompt_tokens,
                    completion_tokens: summary.completion_tokens,
                    reasoning_tokens: terminal.reasoning_tokens,
                    response_digest: CoreDigest::new(*terminal.response_hash.as_bytes()),
                    rolling_digest: CoreDigest::new(*terminal.rolling_digest.as_bytes()),
                    final_generated_tokens: terminal.final_generated_tokens,
                    provider_signature: terminal.signature.as_bytes().to_vec(),
                    recovery_lease: None,
                },
                accepted_cumulative_tokens: summary.completion_tokens,
                reason: Arc::from("provider terminal did not complete"),
            };
            services
                .ledger
                .release_terminal(&request)
                .await
                .map_err(map_ledger_error)?;
            return Ok(TerminalDisposition::Released);
        }
        let billing = services
            .billing
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("billing unavailable")))?;
        let BillingContext::Paid(consumer) = &self.consumer else {
            unreachable!("paid mode checked");
        };
        let amounts = billing
            .amounts(terminal.prompt_tokens, summary.completion_tokens)
            .map_err(map_ledger_input)?;
        let request = SettleRequest {
            operation: self
                .identity
                .operation("settle", &immutable)
                .map_err(map_ledger_input)?,
            job_id: self.identity.job_id,
            expected_job_version: authorized.job_version,
            expected_job_state: authorized.job_state,
            expected_attempt_version: authorized.attempt_version,
            terminal: TerminalFacts {
                terminal_id: self
                    .identity
                    .terminal_id(terminal.terminal_digest.as_bytes())
                    .map_err(map_ledger_input)?,
                attempt_id: authorized.attempt_id,
                provider_id,
                provider_process_generation_id: process_generation,
                origin_session_epoch: session_epoch,
                terminal_digest: CoreDigest::new(*terminal.terminal_digest.as_bytes()),
                raw_terminal,
                outcome: DurableTerminalOutcome::Completed,
                error_class: None,
                prompt_tokens: terminal.prompt_tokens,
                completion_tokens: summary.completion_tokens,
                reasoning_tokens: terminal.reasoning_tokens,
                response_digest: CoreDigest::new(*terminal.response_hash.as_bytes()),
                rolling_digest: CoreDigest::new(*terminal.rolling_digest.as_bytes()),
                final_generated_tokens: terminal.final_generated_tokens,
                provider_signature: terminal.signature.as_bytes().to_vec(),
                recovery_lease: None,
            },
            consumer_charge: amounts.consumer_charge,
            provider_payout: amounts.provider_payout,
            platform_fee: amounts.platform_fee,
            referral_reward: amounts.referral_reward,
            accepted_cumulative_tokens: summary.completion_tokens,
            consumer_key_hash: consumer.consumer_key_hash.clone(),
            review: None,
        };
        services
            .ledger
            .settle(&request)
            .await
            .map_err(map_ledger_error)?;
        Ok(TerminalDisposition::Settled)
    }

    pub(super) fn core_disposition(
        &self,
        terminal: &ProviderTerminal,
    ) -> Result<CoreTerminalDisposition, PilotRequestError> {
        if terminal.outcome != TerminalOutcome::Completed {
            return Ok(CoreTerminalDisposition::Released);
        }
        Ok(CoreTerminalDisposition::Settled {
            // Paid money is exclusively database-authoritative. The pure
            // request reducer retains only a zero-valued settlement marker;
            // the validated accepted checkpoint is priced and committed by
            // LedgerService before the provider receives TerminalAck.
            charged: if self.is_paid() {
                MicroUsd::ZERO
            } else {
                MicroUsd::new(1)
            },
        })
    }

    pub(super) async fn release(&mut self, reason: &'static str) -> Result<(), PilotRequestError> {
        if !self.is_paid() || self.authorized.is_some() {
            return Ok(());
        }
        let Some(reservation) = self.reservation.as_ref() else {
            return Ok(());
        };
        let services = self
            .services
            .as_ref()
            .ok_or_else(|| PilotRequestError::Unavailable(Arc::from("durability unavailable")))?;
        let operation_payload = serde_json::to_vec(&serde_json::json!({
            "job_id": self.identity.job_id.as_uuid(),
            "reason": reason,
            "version": reservation.version.as_i64(),
        }))
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
        services
            .ledger
            .release(&ReleaseRequest {
                operation: self
                    .identity
                    .operation("release", &operation_payload)
                    .map_err(map_ledger_input)?,
                job_id: self.identity.job_id,
                expected_version: reservation.version,
                expected_state: reservation.state,
                reason: Arc::from(reason),
            })
            .await
            .map_err(map_ledger_error)?;
        Ok(())
    }
}

fn structured_error_class_name(class: StructuredErrorClass) -> &'static str {
    match class {
        StructuredErrorClass::InvalidRequest => "invalid_request",
        StructuredErrorClass::Capacity => "capacity",
        StructuredErrorClass::ModelNotReady => "model_not_ready",
        StructuredErrorClass::Draining => "draining",
        StructuredErrorClass::Cancelled => "cancelled",
        StructuredErrorClass::Fault => "fault",
        StructuredErrorClass::Security => "security",
    }
}

fn uuid_from_wire(bytes: &[u8; 16]) -> Uuid {
    Uuid::from_bytes(*bytes)
}

fn map_ledger_input(error: crate::ledger::InputError) -> PilotRequestError {
    PilotRequestError::Internal(Arc::from(error.to_string()))
}

fn map_ledger_error(error: crate::ledger::LedgerError) -> PilotRequestError {
    match error {
        crate::ledger::LedgerError::InsufficientBalance => PilotRequestError::PaymentRequired,
        crate::ledger::LedgerError::ProviderHardUntrusted => {
            PilotRequestError::Provider(Arc::from(error.to_string()))
        }
        crate::ledger::LedgerError::OwnershipUnavailable
        | crate::ledger::LedgerError::OwnershipLost
        | crate::ledger::LedgerError::Timeout
        | crate::ledger::LedgerError::CommitOutcomeUnknown { .. } => {
            PilotRequestError::Unavailable(Arc::from(error.to_string()))
        }
        other => PilotRequestError::Internal(Arc::from(other.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_authorization_outcome_blocks_pre_authorization_cleanup() {
        let identity =
            DurableRequestIdentity::from_request_id(Uuid::new_v4()).expect("request identity");
        let mut durable = DurableExecution::new(identity, BillingContext::FreeSelfRoute, None)
            .expect("free durable execution");
        let error = durable.authorization_error(crate::ledger::LedgerError::CommitOutcomeUnknown {
            operation: crate::ledger::OperationKey::new("pilot:test:authorize")
                .expect("operation key"),
            diagnostic: Arc::from("authorization reconciliation query failed after timeout"),
        });
        assert!(durable.authorization_uncertain);
        assert!(
            durable.is_authorized(),
            "cleanup must not treat an uncertain authorization as pre-authorization"
        );
        assert!(matches!(
            error,
            PilotRequestError::Unavailable(message)
                if message.contains("reconciliation query failed after timeout")
        ));
    }
}
