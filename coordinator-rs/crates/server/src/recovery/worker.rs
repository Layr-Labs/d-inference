use std::{
    future::Future,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use darkbloom_coordinator_protocol::v2::AttemptStatusState;
use thiserror::Error;
use tokio::{task::JoinSet, time::MissedTickBehavior};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::{JobRecoveryAction, JobRecoveryLease, RecoveryService};
use crate::{
    ledger::{
        AuthorizedTerminalTimeoutRequest, LedgerError, LedgerService, Operation, OperationKey,
        ReleaseRequest, ReviewRequest, StartDispatchDisposition, StartDispatchRequest,
        canonical_json_digest,
    },
    pilot::PilotHandle,
    projection::FeeProjectionService,
    provider::DeliveryState,
    provider_control::{ProviderControlError, ProviderControlPlane},
    surface::{
        billing::{WithdrawalRecovery, WithdrawalRecoveryAction, WithdrawalRecoveryError},
        operations::{AdmissionGate, AdmissionKind, TelemetryService},
    },
};

const FEE_PROJECTION_NAME: &str = "legacy-fees";

/// Finite polling and lease bounds shared by all recovery lanes.
#[derive(Clone, Copy, Debug)]
pub struct RecoveryRuntimeConfig {
    pub batch_size: u32,
    pub lease_duration: Duration,
    pub poll_interval: Duration,
    pub outbox_retry_after: Duration,
}

impl Default for RecoveryRuntimeConfig {
    fn default() -> Self {
        Self {
            batch_size: 32,
            lease_duration: Duration::from_secs(30),
            poll_interval: Duration::from_millis(250),
            outbox_retry_after: Duration::from_secs(2),
        }
    }
}

impl RecoveryRuntimeConfig {
    fn validate(self) -> Result<Self, RecoveryRuntimeError> {
        if self.batch_size == 0
            || self.batch_size > 100
            || self.lease_duration.is_zero()
            || self.lease_duration > Duration::from_secs(300)
            || self.poll_interval.is_zero()
        {
            return Err(RecoveryRuntimeError::InvalidConfig);
        }
        Ok(self)
    }
}

/// Supervised owner of the durable recovery, outbox, and fee workers.
pub struct RecoveryRuntime {
    recovery: RecoveryService,
    ledger: LedgerService,
    fees: FeeProjectionService,
    pilot: Option<PilotHandle>,
    provider_control: Option<ProviderControlPlane>,
    admission: Option<AdmissionGate>,
    telemetry: Option<TelemetryService>,
    withdrawal_recovery: Option<WithdrawalRecovery>,
    config: RecoveryRuntimeConfig,
}

impl RecoveryRuntime {
    pub fn new(
        database: crate::database::Database,
        pilot: Option<PilotHandle>,
        config: RecoveryRuntimeConfig,
    ) -> Result<Self, RecoveryRuntimeError> {
        let provider_control = pilot.as_ref().and_then(PilotHandle::provider_control);
        Ok(Self {
            recovery: RecoveryService::new(database.clone()),
            ledger: LedgerService::new(database.clone()),
            fees: FeeProjectionService::new(database),
            pilot,
            provider_control,
            admission: None,
            telemetry: None,
            withdrawal_recovery: None,
            config: config.validate()?,
        })
    }

    #[must_use]
    pub fn with_provider_control(mut self, provider_control: Option<ProviderControlPlane>) -> Self {
        if provider_control.is_some() {
            self.provider_control = provider_control;
        }
        self
    }

    #[must_use]
    pub fn with_admission_gate(mut self, admission: Option<AdmissionGate>) -> Self {
        self.admission = admission;
        self
    }

    #[must_use]
    pub fn with_telemetry_service(mut self, telemetry: Option<TelemetryService>) -> Self {
        self.telemetry = telemetry;
        self
    }

    #[must_use]
    pub fn with_withdrawal_recovery(
        mut self,
        withdrawal_recovery: Option<WithdrawalRecovery>,
    ) -> Self {
        self.withdrawal_recovery = withdrawal_recovery;
        self
    }

    /// Runs independently leased recovery lanes. A fatal worker exit cancels and
    /// joins every sibling before returning.
    pub async fn run(self, cancellation: CancellationToken) -> Result<(), RecoveryRuntimeError> {
        let mut workers = JoinSet::new();
        let services = Arc::new(self);
        spawn_worker(
            &mut workers,
            "jobs",
            services.clone(),
            cancellation.clone(),
            |services, cancellation| async move { services.run_jobs(cancellation).await },
        );
        spawn_worker(
            &mut workers,
            "terminals",
            services.clone(),
            cancellation.clone(),
            |services, cancellation| async move { services.run_terminals(cancellation).await },
        );
        spawn_worker(
            &mut workers,
            "external-events",
            services.clone(),
            cancellation.clone(),
            |services, cancellation| async move { services.run_external_events(cancellation).await },
        );
        spawn_worker(
            &mut workers,
            "outbox",
            services.clone(),
            cancellation.clone(),
            |services, cancellation| async move { services.run_outbox(cancellation).await },
        );
        spawn_worker(
            &mut workers,
            "fees",
            services.clone(),
            cancellation.clone(),
            |services, cancellation| async move { services.run_fees(cancellation).await },
        );
        if services.telemetry.is_some() {
            spawn_worker(
                &mut workers,
                "telemetry",
                services,
                cancellation.clone(),
                |services, cancellation| async move { services.run_telemetry(cancellation).await },
            );
        }

        let outcome = tokio::select! {
            biased;
            () = cancellation.cancelled() => Ok(()),
            joined = workers.join_next() => match joined {
                Some(Ok(result)) => result,
                Some(Err(error)) => Err(RecoveryRuntimeError::TaskJoin(
                    Arc::from(error.to_string())
                )),
                None => Err(RecoveryRuntimeError::UnexpectedWorkerExit),
            },
        };
        cancellation.cancel();
        while let Some(joined) = workers.join_next().await {
            if outcome.is_ok() {
                match joined {
                    Ok(Ok(())) => {}
                    Ok(Err(error)) => return Err(error),
                    Err(error) => {
                        return Err(RecoveryRuntimeError::TaskJoin(Arc::from(error.to_string())));
                    }
                }
            }
        }
        outcome
    }

    async fn run_jobs(&self, cancellation: CancellationToken) -> Result<(), RecoveryRuntimeError> {
        let worker_id = Uuid::new_v4();
        let mut ticker = worker_ticker(self.config.poll_interval);
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                _ = ticker.tick() => {}
            }
            let leases = match self
                .recovery
                .claim_jobs(
                    worker_id,
                    self.config.batch_size,
                    self.config.lease_duration,
                )
                .await
            {
                Ok(leases) => leases,
                Err(error) => {
                    handle_claim_error("job recovery", error)?;
                    continue;
                }
            };
            for lease in leases {
                if cancellation.is_cancelled() {
                    return Ok(());
                }
                if let Err(error) = self.process_job(worker_id, &lease).await {
                    handle_item_error("job recovery", error)?;
                }
            }
        }
    }

    async fn process_job(
        &self,
        _worker_id: Uuid,
        lease: &JobRecoveryLease,
    ) -> Result<(), LedgerError> {
        match lease.action {
            JobRecoveryAction::ReleasePreAuthorization => {
                let payload = serde_json::json!({
                    "job_id": lease.job_id.as_uuid(),
                    "reason": "recovery_pre_authorization_release",
                });
                self.ledger
                    .release(&ReleaseRequest {
                        operation: Operation::new(
                            OperationKey::new(format!(
                                "recovery:release:{}",
                                lease.job_id.as_uuid()
                            ))?,
                            canonical_json_digest(&payload)?,
                        ),
                        job_id: lease.job_id,
                        expected_version: lease.version,
                        expected_state: lease.state,
                        reason: "recovery released a pre-authorization job".into(),
                    })
                    .await?;
                Ok(())
            }
            JobRecoveryAction::ReleaseNotSent => {
                if !deadline_elapsed(lease) {
                    return Ok(());
                }
                self.release_recovered_job(lease, "recovery_not_sent_deadline_release")
                    .await
            }
            JobRecoveryAction::ReconcileAuthorized => {
                if let Some(attempt) = &lease.attempt {
                    match self
                        .ledger
                        .ensure_provider_trusted(attempt.provider_id, attempt.session_epoch)
                        .await
                    {
                        Ok(()) => {}
                        Err(LedgerError::ProviderHardUntrusted) => {
                            self.ledger
                                .move_to_review(&ReviewRequest {
                                    job_id: lease.job_id,
                                    expected_version: lease.version,
                                    expected_state: lease.state,
                                    provider_id: attempt.provider_id,
                                    hard_untrust_epoch: attempt.session_epoch,
                                    accepted_cumulative_tokens: 0,
                                    reason: "recovery_provider_epoch_hard_untrusted".into(),
                                    evidence_digest: canonical_json_digest(&serde_json::json!({
                                        "job_id": lease.job_id.as_uuid(),
                                        "provider_id": attempt.provider_id,
                                        "reason": "recovery_provider_epoch_hard_untrusted",
                                        "session_epoch": attempt.session_epoch.as_i64(),
                                    }))?,
                                })
                                .await?;
                            return Ok(());
                        }
                        Err(error) => return Err(error),
                    }
                    let status = match &self.pilot {
                        Some(pilot) => pilot.query_recovered_attempt(lease).await,
                        None => Ok(None),
                    };
                    match status {
                        Ok(Some(status)) => match status.state {
                            AttemptStatusState::Prepared if !deadline_elapsed(lease) => {
                                let staged = self.pilot.as_ref().and_then(|pilot| {
                                    match pilot.stage_recovered_start(lease) {
                                        Ok(staged) => staged,
                                        Err(error) => {
                                            tracing::warn!(
                                                job_id = %lease.job_id,
                                                error = %error,
                                                "same-lease Start staging was unavailable"
                                            );
                                            None
                                        }
                                    }
                                });
                                if let Some(staged) = staged {
                                    let queued = self
                                        .ledger
                                        .record_start_dispatch(&StartDispatchRequest {
                                            job_id: lease.job_id,
                                            expected_job_version: lease.version,
                                            expected_job_state: lease.state,
                                            attempt_id: attempt.attempt_id,
                                            expected_attempt_version: attempt.version,
                                            expected_attempt_state: attempt.state,
                                            disposition: StartDispatchDisposition::Queued,
                                        })
                                        .await?;
                                    let delivery = staged
                                        .commit()
                                        .wait()
                                        .await
                                        .map_err(|_| LedgerError::Timeout)?;
                                    let disposition = match delivery {
                                        DeliveryState::OnWire => {
                                            Some(StartDispatchDisposition::OnWire)
                                        }
                                        DeliveryState::SentUnknown => {
                                            Some(StartDispatchDisposition::SentUnknown)
                                        }
                                        DeliveryState::Queued | DeliveryState::Failed(_) => None,
                                    };
                                    if let Some(disposition) = disposition {
                                        self.ledger
                                            .record_start_dispatch(&StartDispatchRequest {
                                                job_id: lease.job_id,
                                                expected_job_version: queued.job_version,
                                                expected_job_state: queued.job_state,
                                                attempt_id: attempt.attempt_id,
                                                expected_attempt_version: queued.attempt_version,
                                                expected_attempt_state: queued.attempt_state,
                                                disposition,
                                            })
                                            .await?;
                                    }
                                }
                            }
                            AttemptStatusState::Started => {
                                self.ledger
                                    .record_recovered_start_ack(
                                        attempt.attempt_id,
                                        attempt.provider_id,
                                        attempt.provider_process_generation_id,
                                        attempt.session_epoch,
                                    )
                                    .await?;
                            }
                            AttemptStatusState::Terminal => {
                                // Query handling immediately replays the durable
                                // terminal; retain this claim until it arrives.
                            }
                            AttemptStatusState::Unknown | AttemptStatusState::Prepared => {
                                if deadline_elapsed(lease) {
                                    self.review_reconciliation_failure(
                                        lease,
                                        "attempt_reconciliation_unknown_after_deadline",
                                    )
                                    .await?;
                                }
                            }
                        },
                        Ok(None) | Err(_) if deadline_elapsed(lease) => {
                            self.review_reconciliation_failure(
                                lease,
                                "attempt_reconciliation_unavailable_after_deadline",
                            )
                            .await?;
                        }
                        Ok(None) | Err(_) => {
                            // Retain the bounded claim and retry after expiry.
                        }
                    }
                }
                Ok(())
            }
            JobRecoveryAction::AwaitAuthorizedTerminal => {
                if !request_deadline_elapsed(lease)
                    && let Some(pilot) = &self.pilot
                {
                    // The exact historical identity is queried only to prompt
                    // terminal replay. A started attempt is never resent or
                    // rebound to another provider.
                    let _ = pilot.query_recovered_attempt(lease).await;
                }
                if request_deadline_elapsed(lease) {
                    let attempt = lease.attempt.as_ref().ok_or(LedgerError::CorruptData(
                        "authorized job has no started attempt",
                    ))?;
                    self.ledger
                        .expire_authorized_terminal(&AuthorizedTerminalTimeoutRequest {
                            job_id: lease.job_id,
                            expected_job_version: lease.version,
                            expected_job_state: lease.state,
                            attempt_id: attempt.attempt_id,
                            expected_attempt_version: attempt.version,
                        })
                        .await?;
                }
                Ok(())
            }
        }
    }

    async fn release_recovered_job(
        &self,
        lease: &JobRecoveryLease,
        reason: &'static str,
    ) -> Result<(), LedgerError> {
        let payload = serde_json::json!({
            "job_id": lease.job_id.as_uuid(),
            "reason": reason,
        });
        self.ledger
            .release(&ReleaseRequest {
                operation: Operation::new(
                    OperationKey::new(format!("recovery:release:{}", lease.job_id.as_uuid()))?,
                    canonical_json_digest(&payload)?,
                ),
                job_id: lease.job_id,
                expected_version: lease.version,
                expected_state: lease.state,
                reason: reason.into(),
            })
            .await
            .map(|_| ())
    }

    async fn review_reconciliation_failure(
        &self,
        lease: &JobRecoveryLease,
        reason: &'static str,
    ) -> Result<(), LedgerError> {
        let attempt = lease
            .attempt
            .as_ref()
            .ok_or(LedgerError::CorruptData("authorized job has no attempt"))?;
        self.ledger
            .move_to_review(&ReviewRequest {
                job_id: lease.job_id,
                expected_version: lease.version,
                expected_state: lease.state,
                provider_id: attempt.provider_id,
                hard_untrust_epoch: attempt.session_epoch,
                accepted_cumulative_tokens: 0,
                reason: reason.into(),
                evidence_digest: canonical_json_digest(&serde_json::json!({
                    "attempt_id": attempt.attempt_id.as_uuid(),
                    "deadline_epoch_millis": lease.start_deadline_epoch_millis,
                    "job_id": lease.job_id.as_uuid(),
                    "lease_id": attempt.lease_id,
                    "reason": reason,
                }))?,
            })
            .await
            .map(|_| ())
    }

    async fn run_terminals(
        &self,
        cancellation: CancellationToken,
    ) -> Result<(), RecoveryRuntimeError> {
        let worker_id = Uuid::new_v4();
        let mut ticker = worker_ticker(self.config.poll_interval);
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                _ = ticker.tick() => {}
            }
            let leases = match self
                .recovery
                .claim_terminals(
                    worker_id,
                    self.config.batch_size,
                    self.config.lease_duration,
                )
                .await
            {
                Ok(leases) => leases,
                Err(error) => {
                    handle_claim_error("terminal recovery", error)?;
                    continue;
                }
            };
            for lease in leases {
                if cancellation.is_cancelled() {
                    return Ok(());
                }
                let ack_lease = lease.clone();
                match self
                    .recovery
                    .disposition_terminal(&self.ledger, lease)
                    .await
                {
                    Ok(disposition) => {
                        if let Some(pilot) = &self.pilot
                            && let Err(error) =
                                pilot.ack_recovered_terminal(&ack_lease, disposition).await
                        {
                            tracing::warn!(
                                terminal_id = %ack_lease.terminal_id,
                                error = %error,
                                "durably committed terminal recovery ACK was not delivered"
                            );
                        }
                    }
                    Err(
                        error @ (LedgerError::ProviderHardUntrusted
                        | LedgerError::TerminalReview(_)),
                    ) => {
                        let reason = match error {
                            LedgerError::ProviderHardUntrusted => {
                                "recovery_provider_epoch_hard_untrusted"
                            }
                            LedgerError::TerminalReview(reason) => reason,
                            _ => unreachable!("matched terminal review errors"),
                        };
                        let terminal = ack_lease.clone().into_terminal_facts();
                        if let Err(error) = self
                            .ledger
                            .record_terminal_conflict(
                                ack_lease.job_id,
                                ack_lease.attempt_id,
                                &terminal,
                                reason,
                                0,
                            )
                            .await
                        {
                            handle_item_error("terminal quarantine", error)?;
                        }
                    }
                    Err(error) => handle_item_error("terminal recovery", error)?,
                }
            }
        }
    }

    async fn run_external_events(
        &self,
        cancellation: CancellationToken,
    ) -> Result<(), RecoveryRuntimeError> {
        let worker_id = Uuid::new_v4();
        let mut ticker = worker_ticker(self.config.poll_interval);
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                _ = ticker.tick() => {}
            }
            let _admission = match &self.admission {
                Some(gate) => match gate.enter(AdmissionKind::External) {
                    Ok(guard) => Some(guard),
                    Err(_) => continue,
                },
                None => None,
            };
            let leases = match self
                .recovery
                .claim_external_events(
                    worker_id,
                    self.config.batch_size,
                    self.config.lease_duration,
                )
                .await
            {
                Ok(leases) => leases,
                Err(error) => {
                    handle_claim_error("external-event recovery", error)?;
                    continue;
                }
            };
            for lease in leases {
                if cancellation.is_cancelled() {
                    return Ok(());
                }
                let digest_matches = canonical_json_digest(&lease.payload)? == lease.payload_digest;
                let disposition = if !digest_matches {
                    super::ExternalDisposition::Failed
                } else if lease.source.as_ref() == "micromdm"
                    && lease.event_kind.as_ref() == "SecurityInfo"
                {
                    let Some(control) = &self.provider_control else {
                        tracing::warn!(
                            event_id = %lease.event_id,
                            "MDM event retained until the provider control plane is available"
                        );
                        continue;
                    };
                    match control.recover_mdm_event(&lease).await {
                        Ok(disposition) => {
                            if disposition == super::ExternalDisposition::Rejected {
                                match control.mdm_provider_fence(&lease.event_id).await {
                                    Ok(Some(fence)) => {
                                        if let Some(pilot) = &self.pilot {
                                            pilot
                                                .fence_provider_epoch(
                                                    fence.provider_id,
                                                    fence.session_epoch,
                                                    "durable MDM posture mismatch",
                                                )
                                                .await;
                                        }
                                    }
                                    Ok(None) => {}
                                    Err(error) => {
                                        tracing::warn!(
                                            event_id = %lease.event_id,
                                            error = %error,
                                            "MDM provider fence lookup will retry after lease expiry"
                                        );
                                        continue;
                                    }
                                }
                            }
                            disposition
                        }
                        Err(
                            ProviderControlError::MalformedMdmEvent
                            | ProviderControlError::UnsolicitedMdmEvent
                            | ProviderControlError::MdmEventConflict,
                        ) => super::ExternalDisposition::Rejected,
                        Err(error) => {
                            tracing::warn!(
                                event_id = %lease.event_id,
                                error = %error,
                                "MDM event processing will retry after lease expiry"
                            );
                            continue;
                        }
                    }
                } else {
                    // Supported Stripe events are atomically marked applied by
                    // LedgerService. Any other row reaching this worker is unknown.
                    super::ExternalDisposition::Ignored
                };
                if let Err(error) = self
                    .recovery
                    .complete_external_event(
                        worker_id,
                        lease.external_event_id,
                        lease.version,
                        disposition,
                    )
                    .await
                {
                    handle_item_error("external-event recovery", error)?;
                }
            }
        }
    }

    async fn run_outbox(
        &self,
        cancellation: CancellationToken,
    ) -> Result<(), RecoveryRuntimeError> {
        let worker_id = Uuid::new_v4();
        let mut ticker = worker_ticker(self.config.poll_interval);
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                _ = ticker.tick() => {}
            }
            let _admission = match &self.admission {
                Some(gate) => match gate.enter(AdmissionKind::External) {
                    Ok(guard) => Some(guard),
                    Err(_) => continue,
                },
                None => None,
            };
            let leases = match self
                .recovery
                .claim_outbox(
                    worker_id,
                    self.config.batch_size,
                    self.config.lease_duration,
                )
                .await
            {
                Ok(leases) => leases,
                Err(error) => {
                    handle_claim_error("outbox recovery", error)?;
                    continue;
                }
            };
            for lease in leases {
                if cancellation.is_cancelled() {
                    return Ok(());
                }
                let disposition = match lease.kind.as_ref() {
                    "fee_projection" => match self.project_fee_page(Uuid::new_v4()).await {
                        Ok(()) => Some(super::OutboxDisposition::Delivered),
                        Err(LedgerError::StaleVersion) => Some(super::OutboxDisposition::Retry),
                        Err(error) => {
                            handle_item_error("fee projection outbox", error)?;
                            Some(super::OutboxDisposition::Retry)
                        }
                    },
                    "external_call" => {
                        let Some(recovery) = &self.withdrawal_recovery else {
                            tracing::warn!(
                                outbox_id = %lease.outbox_id,
                                "Stripe withdrawal outbox retained until recovery is configured"
                            );
                            continue;
                        };
                        match recovery.process(worker_id, &lease).await {
                            Ok(WithdrawalRecoveryAction::Handled) => None,
                            Ok(WithdrawalRecoveryAction::Retry) => {
                                Some(super::OutboxDisposition::Retry)
                            }
                            Err(
                                WithdrawalRecoveryError::InvalidPayload
                                | WithdrawalRecoveryError::Ledger(_),
                            ) => Some(super::OutboxDisposition::Failed),
                            Err(WithdrawalRecoveryError::StaleLease) => continue,
                            Err(error) => {
                                tracing::warn!(
                                    outbox_id = %lease.outbox_id,
                                    error = %error,
                                    "Stripe withdrawal recovery will retry"
                                );
                                Some(super::OutboxDisposition::Retry)
                            }
                        }
                    }
                    _ => Some(super::OutboxDisposition::Cancelled),
                };
                let Some(disposition) = disposition else {
                    continue;
                };
                if let Err(error) = self
                    .recovery
                    .complete_outbox(
                        worker_id,
                        lease.outbox_id,
                        lease.version,
                        disposition,
                        self.config.outbox_retry_after,
                    )
                    .await
                {
                    handle_item_error("outbox recovery", error)?;
                }
            }
        }
    }

    async fn run_fees(&self, cancellation: CancellationToken) -> Result<(), RecoveryRuntimeError> {
        let worker_id = Uuid::new_v4();
        let mut ticker = worker_ticker(self.config.poll_interval);
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                _ = ticker.tick() => {}
            }
            match self.project_fee_page(worker_id).await {
                Ok(()) | Err(LedgerError::StaleVersion) => {}
                Err(error) => handle_claim_error("fee projection", error)?,
            }
        }
    }

    async fn run_telemetry(
        &self,
        cancellation: CancellationToken,
    ) -> Result<(), RecoveryRuntimeError> {
        let worker_id = Uuid::new_v4();
        let Some(telemetry) = &self.telemetry else {
            return Ok(());
        };
        let mut ticker = worker_ticker(self.config.poll_interval);
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                _ = ticker.tick() => {}
            }
            let _admission = match &self.admission {
                Some(gate) => match gate.enter(AdmissionKind::External) {
                    Ok(guard) => Some(guard),
                    Err(_) => continue,
                },
                None => None,
            };
            if let Err(error) = telemetry.process_once(worker_id).await {
                tracing::warn!(error = %error, "durable telemetry delivery will retry");
            }
        }
    }

    async fn project_fee_page(&self, worker_id: Uuid) -> Result<(), LedgerError> {
        let batch = self
            .fees
            .claim(
                FEE_PROJECTION_NAME,
                worker_id,
                self.config.batch_size,
                self.config.lease_duration,
            )
            .await?;
        self.fees.complete(&batch, worker_id).await?;
        Ok(())
    }
}

fn spawn_worker<F, Fut>(
    workers: &mut JoinSet<Result<(), RecoveryRuntimeError>>,
    name: &'static str,
    services: Arc<RecoveryRuntime>,
    cancellation: CancellationToken,
    worker: F,
) where
    F: FnOnce(Arc<RecoveryRuntime>, CancellationToken) -> Fut + Send + 'static,
    Fut: Future<Output = Result<(), RecoveryRuntimeError>> + Send + 'static,
{
    workers.spawn(async move {
        tracing::info!(worker = name, "durable recovery worker started");
        let result = worker(services, cancellation).await;
        tracing::info!(worker = name, "durable recovery worker stopped");
        result
    });
}

fn worker_ticker(period: Duration) -> tokio::time::Interval {
    let mut ticker = tokio::time::interval(period);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    ticker
}

fn deadline_elapsed(lease: &JobRecoveryLease) -> bool {
    lease
        .start_deadline_epoch_millis
        .is_none_or(|deadline| epoch_millis_now() >= deadline)
}

fn request_deadline_elapsed(lease: &JobRecoveryLease) -> bool {
    epoch_millis_now() >= lease.request_deadline_epoch_millis
}

fn epoch_millis_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(i64::MAX, |duration| {
            i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
        })
}

fn handle_claim_error(
    operation: &'static str,
    error: LedgerError,
) -> Result<(), RecoveryRuntimeError> {
    if is_fatal(&error) {
        Err(error.into())
    } else {
        tracing::warn!(operation, error = %error, "durable worker claim will retry");
        Ok(())
    }
}

fn handle_item_error(
    operation: &'static str,
    error: LedgerError,
) -> Result<(), RecoveryRuntimeError> {
    if is_fatal(&error) {
        Err(error.into())
    } else {
        tracing::warn!(operation, error = %error, "durable worker item remains recoverable");
        Ok(())
    }
}

fn is_fatal(error: &LedgerError) -> bool {
    matches!(
        error,
        LedgerError::OwnershipLost
            | LedgerError::OwnershipUnavailable
            | LedgerError::CorruptData(_)
            | LedgerError::Invalid(_)
    )
}

#[derive(Debug, Error)]
pub enum RecoveryRuntimeError {
    #[error("invalid durable recovery runtime bounds")]
    InvalidConfig,
    #[error("durable recovery worker ended unexpectedly")]
    UnexpectedWorkerExit,
    #[error("durable recovery worker task failed: {0}")]
    TaskJoin(Arc<str>),
    #[error(transparent)]
    Ledger(#[from] LedgerError),
}
