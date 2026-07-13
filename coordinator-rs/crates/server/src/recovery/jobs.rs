use std::{sync::Arc, time::Duration};

use darkbloom_coordinator_core::ids::Digest;
use serde_json::Value;
use sqlx::FromRow;
use uuid::Uuid;

use super::RecoveryService;
use crate::ledger::types::{
    AttemptId, JobId, JobState, LedgerError, TerminalFacts, TerminalId, TerminalLeaseToken,
    TerminalOutcome, Version,
};

const MAX_CLAIM_BATCH: u32 = 100;
const MAX_LEASE_MILLIS: u64 = 300_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JobRecoveryAction {
    /// No start was authorized; reconcile/release without provider dispatch.
    ReleasePreAuthorization,
    /// Authorization committed but the staged writer gate never opened.
    ReleaseNotSent,
    /// Start delivery is ambiguous and must be reconciled with the provider.
    ReconcileAuthorized,
    /// Provider durably acknowledged Start. Await its terminal replay.
    AwaitAuthorizedTerminal,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JobRecoveryLease {
    pub job_id: JobId,
    pub request_id: Uuid,
    pub reservation_id: Uuid,
    pub version: Version,
    pub state: JobState,
    pub action: JobRecoveryAction,
    pub attempt: Option<AuthorizedAttemptRecovery>,
    pub start_deadline_epoch_millis: Option<i64>,
    pub request_deadline_epoch_millis: i64,
    pub lease_until_epoch_millis: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizedAttemptRecovery {
    pub attempt_id: AttemptId,
    pub provider_id: Uuid,
    pub provider_process_generation_id: Uuid,
    pub session_epoch: Version,
    pub lease_id: Uuid,
    pub state: crate::ledger::AttemptState,
    pub version: Version,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalRecoveryLease {
    pub terminal_id: TerminalId,
    pub job_id: JobId,
    pub attempt_id: AttemptId,
    pub provider_id: Uuid,
    pub provider_process_generation_id: Uuid,
    pub origin_session_epoch: Version,
    pub terminal_digest: Digest,
    pub raw_terminal: Value,
    pub outcome: TerminalOutcome,
    pub error_class: Option<Arc<str>>,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub reasoning_tokens: u64,
    pub response_digest: Digest,
    pub rolling_digest: Digest,
    pub final_generated_tokens: u64,
    pub provider_signature: Vec<u8>,
    pub worker_id: Uuid,
    pub job_version: Version,
    pub job_state: JobState,
    pub attempt_version: Version,
    pub version: Version,
    pub lease_until_epoch_millis: i64,
}

impl TerminalRecoveryLease {
    #[must_use]
    pub fn into_terminal_facts(self) -> TerminalFacts {
        TerminalFacts {
            terminal_id: self.terminal_id,
            attempt_id: self.attempt_id,
            provider_id: self.provider_id,
            provider_process_generation_id: self.provider_process_generation_id,
            origin_session_epoch: self.origin_session_epoch,
            terminal_digest: self.terminal_digest,
            raw_terminal: self.raw_terminal,
            outcome: self.outcome,
            error_class: self.error_class,
            prompt_tokens: self.prompt_tokens,
            completion_tokens: self.completion_tokens,
            reasoning_tokens: self.reasoning_tokens,
            response_digest: self.response_digest,
            rolling_digest: self.rolling_digest,
            final_generated_tokens: self.final_generated_tokens,
            provider_signature: self.provider_signature,
            recovery_lease: Some(TerminalLeaseToken {
                worker_id: self.worker_id,
                version: self.version,
            }),
        }
    }
}

impl RecoveryService {
    /// Claims bounded active jobs with expired-or-absent leases.
    pub async fn claim_jobs(
        &self,
        worker_id: Uuid,
        limit: u32,
        lease_for: Duration,
    ) -> Result<Vec<JobRecoveryLease>, LedgerError> {
        validate_claim(worker_id, limit, lease_for)?;
        let authority = self.db.authority()?;
        let rows = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    JobLeaseRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    candidates AS MATERIALIZED (
                        SELECT jobs.job_id
                        FROM rust_coord.inference_jobs AS jobs
                        WHERE jobs.state IN (
                            'reserved',
                            'preparing',
                            'prepared',
                            'start_authorized',
                            'running'
                        )
                          AND (
                              jobs.worker_owner IS NULL
                              OR jobs.lease_until <= NOW()
                          )
                        ORDER BY jobs.updated_at, jobs.job_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $4
                    ),
                    claimed AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            owner_epoch = $2,
                            worker_owner = $3,
                            lease_until = CASE
                                WHEN jobs.state = 'running'
                                     AND jobs.request_deadline > NOW()
                                THEN GREATEST(
                                    NOW()
                                        + ($5::BIGINT * INTERVAL '1 millisecond'),
                                    LEAST(
                                        jobs.request_deadline,
                                        NOW()
                                            + (300000::BIGINT
                                                * INTERVAL '1 millisecond')
                                    )
                                )
                                ELSE NOW()
                                    + ($5::BIGINT * INTERVAL '1 millisecond')
                            END,
                            version = jobs.version + 1,
                            updated_at = NOW()
                        FROM candidates, authority
                        WHERE jobs.job_id = candidates.job_id
                        RETURNING
                            jobs.job_id,
                            jobs.request_id,
                            jobs.reservation_id,
                            jobs.version,
                            jobs.state,
                            jobs.lease_until AS claimed_lease_until,
                            (
                                EXTRACT(EPOCH FROM jobs.start_deadline) * 1000
                            )::BIGINT AS start_deadline_epoch_millis,
                            (
                                EXTRACT(EPOCH FROM jobs.request_deadline) * 1000
                            )::BIGINT AS request_deadline_epoch_millis,
                            (
                                EXTRACT(EPOCH FROM jobs.lease_until) * 1000
                            )::BIGINT AS lease_until_epoch_millis
                    ),
                    attempt_claim AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            owner_epoch = $2,
                            worker_owner = $3,
                            lease_until = claimed.claimed_lease_until,
                            version = attempts.version + 1,
                            updated_at = NOW()
                        FROM claimed
                        WHERE attempts.job_id = claimed.job_id
                          AND attempts.state IN (
                              'not_sent',
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                        RETURNING
                            attempts.job_id,
                            attempts.attempt_id,
                            attempts.provider_id,
                            attempts.provider_process_generation_id,
                            attempts.session_epoch,
                            attempts.lease_id,
                            attempts.state AS attempt_state,
                            attempts.version AS attempt_version
                    )
                    SELECT
                        claimed.job_id,
                        claimed.request_id,
                        claimed.reservation_id,
                        claimed.version,
                        claimed.state,
                        claimed.start_deadline_epoch_millis,
                        claimed.request_deadline_epoch_millis,
                        claimed.lease_until_epoch_millis,
                        attempt_claim.attempt_id,
                        attempt_claim.provider_id,
                        attempt_claim.provider_process_generation_id,
                        attempt_claim.session_epoch,
                        attempt_claim.lease_id,
                        attempt_claim.attempt_state,
                        attempt_claim.attempt_version
                    FROM claimed
                    LEFT JOIN attempt_claim USING (job_id)
                    ORDER BY claimed.job_id
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    worker_id,
                    i64::from(limit),
                    i64::try_from(lease_for.as_millis()).map_err(|_| {
                        LedgerError::Invalid(crate::ledger::types::InputError::ArithmeticOverflow)
                    })?,
                )
                .fetch_all(self.db.pool()),
            )
            .await?;
        if rows.is_empty() {
            self.db.verify_authority(&authority).await?;
        }
        rows.into_iter().map(JobLeaseRow::into_lease).collect()
    }

    /// Claims terminal-received rows independently of job recovery.
    pub async fn claim_terminals(
        &self,
        worker_id: Uuid,
        limit: u32,
        lease_for: Duration,
    ) -> Result<Vec<TerminalRecoveryLease>, LedgerError> {
        validate_claim(worker_id, limit, lease_for)?;
        let authority = self.db.authority()?;
        let rows = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    TerminalLeaseRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    candidates AS MATERIALIZED (
                        SELECT terminals.terminal_id
                        FROM rust_coord.provider_terminals AS terminals
                        JOIN rust_coord.inference_jobs AS jobs
                          ON jobs.job_id = terminals.job_id
                        JOIN rust_coord.inference_attempts AS attempts
                          ON attempts.attempt_id = terminals.attempt_id
                         AND attempts.job_id = terminals.job_id
                        WHERE terminals.status = 'pending'
                          AND (
                              terminals.worker_owner IS NULL
                              OR terminals.lease_until <= NOW()
                          )
                          AND jobs.state IN ('start_authorized', 'running')
                          AND jobs.request_deadline > NOW()
                          AND (
                              jobs.worker_owner IS NULL
                              OR jobs.lease_until <= NOW()
                          )
                          AND attempts.state IN (
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                          AND (
                              attempts.worker_owner IS NULL
                              OR attempts.lease_until <= NOW()
                          )
                        ORDER BY terminals.received_at, terminals.terminal_id
                        FOR UPDATE OF terminals, jobs, attempts SKIP LOCKED
                        LIMIT $4
                    ),
                    claimed AS (
                        UPDATE rust_coord.provider_terminals AS terminals
                        SET
                            owner_epoch = $2,
                            worker_owner = $3,
                            lease_until =
                                NOW() + ($5::BIGINT * INTERVAL '1 millisecond'),
                            version = terminals.version + 1,
                            updated_at = NOW()
                        FROM candidates, authority
                        WHERE terminals.terminal_id = candidates.terminal_id
                        RETURNING
                            terminals.terminal_id,
                            terminals.job_id,
                            terminals.attempt_id,
                            terminals.provider_id,
                            terminals.provider_process_generation_id,
                            terminals.origin_session_epoch,
                            terminals.terminal_digest,
                            terminals.raw_terminal,
                            terminals.outcome,
                            terminals.error_class,
                            terminals.prompt_tokens,
                            terminals.completion_tokens,
                            terminals.reasoning_tokens,
                            terminals.response_digest,
                            terminals.rolling_digest,
                            terminals.final_generated_tokens,
                            terminals.provider_signature,
                            terminals.version,
                            (
                                EXTRACT(EPOCH FROM terminals.lease_until) * 1000
                            )::BIGINT AS lease_until_epoch_millis
                    )
                    ,
                    job_claim AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            owner_epoch = $2,
                            worker_owner = $3,
                            lease_until =
                                NOW() + ($5::BIGINT * INTERVAL '1 millisecond'),
                            version = jobs.version + 1,
                            updated_at = NOW()
                        FROM claimed
                        WHERE jobs.job_id = claimed.job_id
                        RETURNING
                            jobs.job_id,
                            jobs.version AS job_version,
                            jobs.state AS job_state
                    ),
                    attempt_claim AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            owner_epoch = $2,
                            worker_owner = $3,
                            lease_until =
                                NOW() + ($5::BIGINT * INTERVAL '1 millisecond'),
                            version = attempts.version + 1,
                            updated_at = NOW()
                        FROM claimed
                        WHERE attempts.attempt_id = claimed.attempt_id
                        RETURNING
                            attempts.attempt_id,
                            attempts.version AS attempt_version
                    )
                    SELECT
                        claimed.*,
                        job_claim.job_version,
                        job_claim.job_state,
                        attempt_claim.attempt_version
                    FROM claimed
                    JOIN job_claim USING (job_id)
                    JOIN attempt_claim USING (attempt_id)
                    ORDER BY claimed.terminal_id
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    worker_id,
                    i64::from(limit),
                    i64::try_from(lease_for.as_millis()).map_err(|_| {
                        LedgerError::Invalid(crate::ledger::types::InputError::ArithmeticOverflow)
                    })?,
                )
                .fetch_all(self.db.pool()),
            )
            .await?;
        if rows.is_empty() {
            self.db.verify_authority(&authority).await?;
        }
        rows.into_iter()
            .map(|row| row.into_lease(worker_id))
            .collect()
    }

    /// Releases a job lease only when owner epoch, worker, version, and state
    /// are all still exact.
    pub async fn complete_job_lease(
        &self,
        worker_id: Uuid,
        job_id: JobId,
        version: Version,
        state: JobState,
    ) -> Result<Version, LedgerError> {
        if worker_id.is_nil() {
            return Err(crate::ledger::types::InputError::NilId("worker id").into());
        }
        let authority = self.db.authority()?;
        let next = self
            .db
            .bounded(
                sqlx::query_scalar_unchecked!(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    attempt_release AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            worker_owner = NULL,
                            lease_until = NULL,
                            version = attempts.version + 1,
                            updated_at = NOW()
                        FROM authority
                        WHERE attempts.job_id = $3
                          AND attempts.owner_epoch = $2
                          AND attempts.worker_owner = $4
                          AND attempts.lease_until > NOW()
                        RETURNING attempts.attempt_id
                    )
                    UPDATE rust_coord.inference_jobs AS jobs
                    SET
                        worker_owner = NULL,
                        lease_until = NULL,
                        version = jobs.version + 1,
                        updated_at = NOW()
                    FROM authority
                    LEFT JOIN (
                        SELECT COUNT(*) AS released_attempts
                        FROM attempt_release
                    ) AS released ON TRUE
                    WHERE jobs.job_id = $3
                      AND jobs.owner_epoch = $2
                      AND jobs.worker_owner = $4
                      AND jobs.version = $5
                      AND jobs.state = $6
                      AND jobs.lease_until > NOW()
                    RETURNING jobs.version
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    job_id.as_uuid(),
                    worker_id,
                    version.as_i64(),
                    state.as_str(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(next) = next else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::StaleVersion);
        };
        Version::from_database(next)
    }
}

#[derive(Debug, FromRow)]
struct JobLeaseRow {
    job_id: Uuid,
    request_id: Uuid,
    reservation_id: Uuid,
    version: i64,
    state: String,
    lease_until_epoch_millis: i64,
    attempt_id: Option<Uuid>,
    provider_id: Option<Uuid>,
    provider_process_generation_id: Option<Uuid>,
    session_epoch: Option<i64>,
    lease_id: Option<Uuid>,
    attempt_state: Option<String>,
    attempt_version: Option<i64>,
    start_deadline_epoch_millis: Option<i64>,
    request_deadline_epoch_millis: i64,
}

impl JobLeaseRow {
    fn into_lease(self) -> Result<JobRecoveryLease, LedgerError> {
        let state = JobState::from_database(&self.state)?;
        let action = match state {
            JobState::Reserved | JobState::Preparing | JobState::Prepared => {
                JobRecoveryAction::ReleasePreAuthorization
            }
            JobState::StartAuthorized | JobState::Running => match self.attempt_state.as_deref() {
                Some("not_sent") => JobRecoveryAction::ReleaseNotSent,
                Some("queued" | "on_wire" | "sent_unknown") => {
                    JobRecoveryAction::ReconcileAuthorized
                }
                Some("started") => JobRecoveryAction::AwaitAuthorizedTerminal,
                _ => return Err(LedgerError::CorruptData("authorized job attempt state")),
            },
            _ => return Err(LedgerError::CorruptData("claimed terminal job state")),
        };
        let attempt = match (
            self.attempt_id,
            self.provider_id,
            self.provider_process_generation_id,
            self.session_epoch,
            self.lease_id,
            self.attempt_state,
            self.attempt_version,
        ) {
            (
                Some(attempt_id),
                Some(provider_id),
                Some(provider_process_generation_id),
                Some(session_epoch),
                Some(lease_id),
                Some(attempt_state),
                Some(attempt_version),
            ) => Some(AuthorizedAttemptRecovery {
                attempt_id: AttemptId::new(attempt_id)
                    .map_err(|_| LedgerError::CorruptData("stored attempt id is nil"))?,
                provider_id,
                provider_process_generation_id,
                session_epoch: Version::from_database(session_epoch)?,
                lease_id,
                state: crate::ledger::AttemptState::from_database(&attempt_state)?,
                version: Version::from_database(attempt_version)?,
            }),
            (None, None, None, None, None, None, None) => None,
            _ => {
                return Err(LedgerError::CorruptData(
                    "partial authorized recovery attempt",
                ));
            }
        };
        Ok(JobRecoveryLease {
            job_id: JobId::new(self.job_id)
                .map_err(|_| LedgerError::CorruptData("stored job id is nil"))?,
            request_id: self.request_id,
            reservation_id: self.reservation_id,
            version: Version::from_database(self.version)?,
            state,
            action,
            attempt,
            start_deadline_epoch_millis: self.start_deadline_epoch_millis,
            request_deadline_epoch_millis: self.request_deadline_epoch_millis,
            lease_until_epoch_millis: self.lease_until_epoch_millis,
        })
    }
}

#[derive(Debug, FromRow)]
struct TerminalLeaseRow {
    terminal_id: Uuid,
    job_id: Uuid,
    attempt_id: Uuid,
    provider_id: Uuid,
    provider_process_generation_id: Uuid,
    origin_session_epoch: i64,
    terminal_digest: Vec<u8>,
    raw_terminal: Value,
    outcome: String,
    error_class: Option<String>,
    prompt_tokens: i64,
    completion_tokens: i64,
    reasoning_tokens: i64,
    response_digest: Vec<u8>,
    rolling_digest: Vec<u8>,
    final_generated_tokens: i64,
    provider_signature: Vec<u8>,
    version: i64,
    lease_until_epoch_millis: i64,
    job_version: i64,
    job_state: String,
    attempt_version: i64,
}

impl TerminalLeaseRow {
    fn into_lease(self, worker_id: Uuid) -> Result<TerminalRecoveryLease, LedgerError> {
        if self.provider_id.is_nil() || self.provider_process_generation_id.is_nil() {
            return Err(LedgerError::CorruptData(
                "stored terminal provider id is nil",
            ));
        }
        Ok(TerminalRecoveryLease {
            terminal_id: TerminalId::new(self.terminal_id)
                .map_err(|_| LedgerError::CorruptData("stored terminal id is nil"))?,
            job_id: JobId::new(self.job_id)
                .map_err(|_| LedgerError::CorruptData("stored job id is nil"))?,
            attempt_id: AttemptId::new(self.attempt_id)
                .map_err(|_| LedgerError::CorruptData("stored attempt id is nil"))?,
            provider_id: self.provider_id,
            provider_process_generation_id: self.provider_process_generation_id,
            origin_session_epoch: Version::from_database(self.origin_session_epoch)?,
            terminal_digest: Digest::try_from(self.terminal_digest.as_slice())
                .map_err(|_| LedgerError::CorruptData("stored terminal digest width"))?,
            raw_terminal: self.raw_terminal,
            outcome: TerminalOutcome::from_database(&self.outcome)?,
            error_class: self.error_class.map(Arc::from),
            prompt_tokens: stored_tokens(self.prompt_tokens)?,
            completion_tokens: stored_tokens(self.completion_tokens)?,
            reasoning_tokens: stored_tokens(self.reasoning_tokens)?,
            response_digest: Digest::try_from(self.response_digest.as_slice())
                .map_err(|_| LedgerError::CorruptData("stored response digest width"))?,
            rolling_digest: Digest::try_from(self.rolling_digest.as_slice())
                .map_err(|_| LedgerError::CorruptData("stored rolling digest width"))?,
            final_generated_tokens: stored_tokens(self.final_generated_tokens)?,
            provider_signature: self.provider_signature,
            worker_id,
            job_version: Version::from_database(self.job_version)?,
            job_state: JobState::from_database(&self.job_state)?,
            attempt_version: Version::from_database(self.attempt_version)?,
            version: Version::from_database(self.version)?,
            lease_until_epoch_millis: self.lease_until_epoch_millis,
        })
    }
}

fn stored_tokens(value: i64) -> Result<u64, LedgerError> {
    u64::try_from(value).map_err(|_| LedgerError::CorruptData("negative stored terminal tokens"))
}

fn validate_claim(worker_id: Uuid, limit: u32, lease_for: Duration) -> Result<(), LedgerError> {
    if worker_id.is_nil() {
        return Err(crate::ledger::types::InputError::NilId("worker id").into());
    }
    if limit == 0 || limit > MAX_CLAIM_BATCH {
        return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
    }
    let millis = u64::try_from(lease_for.as_millis())
        .map_err(|_| crate::ledger::types::InputError::ArithmeticOverflow)?;
    if millis == 0 || millis > MAX_LEASE_MILLIS {
        return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
    }
    Ok(())
}
