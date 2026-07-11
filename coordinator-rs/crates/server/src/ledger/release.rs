use sqlx::FromRow;

use super::{
    LedgerService,
    reserve::{json_i64, json_uuid},
    types::{
        JobId, LedgerAmount, LedgerError, MutationDisposition, ReleaseRequest, ReservationResult,
        Version,
    },
};
use crate::db::ownership::{Authority, DurableDatabase, OperationRecord};

impl LedgerService {
    /// Releases an exact reservation provenance and terminalizes the job in one
    /// statement guarded by status/version CAS.
    pub async fn release(
        &self,
        request: &ReleaseRequest,
    ) -> Result<ReservationResult, LedgerError> {
        if request.reason.is_empty() {
            return Err(crate::ledger::types::InputError::Empty("release reason").into());
        }
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.release_once(&authority, request).await;
            match result {
                Ok(Some(row)) => return release_from_row(row, MutationDisposition::Applied),
                Ok(None) => return self.resolve_release(&authority, request, false).await,
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::may_retry(attempt, source) =>
                {
                    self.db.retry_delay(attempt).await;
                    attempt += 1;
                }
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::is_operation_conflict(source) =>
                {
                    return self.resolve_release_conflict(&authority, request).await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self.resolve_release(&authority, request, true).await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn release_once(
        &self,
        authority: &Authority,
        request: &ReleaseRequest,
    ) -> Result<Option<ReleaseRow>, LedgerError> {
        self.db
            .bounded(
                sqlx::query_as_unchecked!(
                    ReleaseRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    job AS MATERIALIZED (
                        SELECT jobs.*
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN public.balances AS balances
                          ON balances.account_id = jobs.account_id
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.version = $4
                          AND jobs.state = $5
                          AND (
                              jobs.state IN ('reserved', 'preparing', 'prepared')
                              OR (
                                  jobs.state = 'start_authorized'
                                  AND jobs.start_deadline <= NOW()
                                  AND EXISTS (
                                      SELECT 1
                                      FROM rust_coord.inference_attempts AS attempts
                                      WHERE attempts.job_id = jobs.job_id
                                        AND attempts.state = 'not_sent'
                                  )
                              )
                          )
                          AND jobs.reservation_pre_debited
                          AND balances.balance_micro_usd >= 0
                          AND balances.withdrawable_micro_usd >= 0
                          AND balances.withdrawable_micro_usd
                              <= balances.balance_micro_usd
                          AND balances.balance_micro_usd
                              <= 9223372036854775807::BIGINT
                                 - jobs.reserved_total_micro_usd
                          AND balances.withdrawable_micro_usd
                              <= 9223372036854775807::BIGINT
                                 - jobs.reserved_withdrawable_micro_usd
                        FOR UPDATE OF jobs, balances
                    ),
                    operation_insert AS (
                        INSERT INTO rust_coord.financial_operations (
                            operation_id,
                            operation_key,
                            operation_digest,
                            kind,
                            status,
                            job_id,
                            account_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd,
                            result,
                            owner_epoch,
                            version,
                            completed_at
                        )
                        SELECT
                            $6,
                            $7,
                            $8,
                            'release',
                            'released',
                            job.job_id,
                            job.account_id,
                            job.reserved_total_micro_usd,
                            job.reserved_withdrawable_micro_usd,
                            jsonb_build_object(
                                'job_id', job.job_id,
                                'version', $4::BIGINT + 1,
                                'state', 'released',
                                'total', job.reserved_total_micro_usd,
                                'withdrawable',
                                    job.reserved_withdrawable_micro_usd
                            ),
                            $2,
                            2,
                            NOW()
                        FROM authority
                        CROSS JOIN job
                        RETURNING operation_id
                    ),
                    balance_update AS (
                        UPDATE public.balances AS balances
                        SET
                            balance_micro_usd =
                                balances.balance_micro_usd
                                + job.reserved_total_micro_usd,
                            withdrawable_micro_usd =
                                balances.withdrawable_micro_usd
                                + job.reserved_withdrawable_micro_usd,
                            updated_at = NOW()
                        FROM job, operation_insert
                        WHERE balances.account_id = job.account_id
                        RETURNING balances.balance_micro_usd
                    ),
                    ledger_insert AS (
                        INSERT INTO public.ledger_entries (
                            account_id,
                            entry_type,
                            amount_micro_usd,
                            balance_after,
                            reference
                        )
                        SELECT
                            job.account_id,
                            'refund',
                            job.reserved_total_micro_usd,
                            balance_update.balance_micro_usd,
                            'rust-release:' || $7
                        FROM job, balance_update
                        RETURNING id
                    ),
                    attempts_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            state = 'aborted',
                            version = attempts.version + 1,
                            updated_at = NOW(),
                            worker_owner = NULL,
                            lease_until = NULL
                        FROM job, ledger_insert
                        WHERE attempts.job_id = job.job_id
                          AND attempts.state IN ('prepared', 'not_sent')
                        RETURNING attempts.attempt_id
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = 'released',
                            error_class = $9,
                            version = jobs.version + 1,
                            updated_at = NOW(),
                            terminal_at = NOW(),
                            worker_owner = NULL,
                            lease_until = NULL
                        FROM job, ledger_insert
                        WHERE jobs.job_id = job.job_id
                          AND jobs.version = $4
                          AND jobs.state = $5
                        RETURNING
                            jobs.job_id,
                            jobs.version,
                            jobs.state,
                            jobs.reserved_total_micro_usd,
                            jobs.reserved_withdrawable_micro_usd
                    )
                    SELECT
                        job_update.job_id,
                        job_update.version,
                        job_update.state,
                        job_update.reserved_total_micro_usd,
                        job_update.reserved_withdrawable_micro_usd
                    FROM job_update
                    CROSS JOIN operation_insert
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.job_id.as_uuid(),
                    request.expected_version.as_i64(),
                    request.expected_state.as_str(),
                    request.operation.id.as_uuid(),
                    request.operation.key.as_str(),
                    request.operation.digest.as_bytes().as_slice(),
                    request.reason.as_ref(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    async fn resolve_release(
        &self,
        authority: &Authority,
        request: &ReleaseRequest,
        ambiguous: bool,
    ) -> Result<ReservationResult, LedgerError> {
        if let Some(operation) = self.db.operation(authority, &request.operation.key).await? {
            return release_from_operation(operation, request);
        }
        if ambiguous {
            return Err(LedgerError::CommitOutcomeUnknown {
                operation: request.operation.key.clone(),
                diagnostic: "ambiguous release commit was not found during reconciliation".into(),
            });
        }
        let current = self
            .db
            .bounded(
                sqlx::query_scalar_unchecked!(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT EXISTS (
                        SELECT 1
                        FROM rust_coord.inference_jobs
                        WHERE job_id = $3
                          AND owner_epoch = $2
                          AND version = $4
                          AND state = $5
                    ) AS "current!"
                    FROM authority
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.job_id.as_uuid(),
                    request.expected_version.as_i64(),
                    request.expected_state.as_str(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match current {
            Some(true) => Err(LedgerError::OperationConflict),
            Some(false) => Err(LedgerError::StaleVersion),
            None => Err(LedgerError::OwnershipLost),
        }
    }

    async fn resolve_release_conflict(
        &self,
        authority: &Authority,
        request: &ReleaseRequest,
    ) -> Result<ReservationResult, LedgerError> {
        let Some(operation) = self.db.operation(authority, &request.operation.key).await? else {
            return Err(LedgerError::OperationConflict);
        };
        release_from_operation(operation, request)
    }
}

#[derive(Debug, FromRow)]
struct ReleaseRow {
    job_id: uuid::Uuid,
    version: i64,
    state: String,
    reserved_total_micro_usd: i64,
    reserved_withdrawable_micro_usd: i64,
}

fn release_from_row(
    row: ReleaseRow,
    disposition: MutationDisposition,
) -> Result<ReservationResult, LedgerError> {
    Ok(ReservationResult {
        disposition,
        job_id: JobId::new(row.job_id)
            .map_err(|_| LedgerError::CorruptData("stored job id is nil"))?,
        version: Version::from_database(row.version)?,
        total: LedgerAmount::from_i64(row.reserved_total_micro_usd)
            .map_err(LedgerError::Invalid)?,
        withdrawable: LedgerAmount::from_i64(row.reserved_withdrawable_micro_usd)
            .map_err(LedgerError::Invalid)?,
        state: crate::ledger::types::JobState::from_database(&row.state)?,
    })
}

fn release_from_operation(
    operation: OperationRecord,
    request: &ReleaseRequest,
) -> Result<ReservationResult, LedgerError> {
    if operation.operation_key != request.operation.key.as_str()
        || operation.digest()? != request.operation.digest
        || operation.kind != "release"
        || operation.status != "released"
        || operation.job_id != Some(request.job_id.as_uuid())
    {
        return Err(LedgerError::OperationConflict);
    }
    release_from_row(
        ReleaseRow {
            job_id: json_uuid(&operation.result, "job_id")?,
            version: json_i64(&operation.result, "version")?,
            state: operation
                .result
                .get("state")
                .and_then(serde_json::Value::as_str)
                .ok_or(LedgerError::CorruptData("state"))?
                .to_owned(),
            reserved_total_micro_usd: json_i64(&operation.result, "total")?,
            reserved_withdrawable_micro_usd: json_i64(&operation.result, "withdrawable")?,
        },
        MutationDisposition::Replayed,
    )
}
