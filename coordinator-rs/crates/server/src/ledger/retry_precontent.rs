use sqlx::{FromRow, types::Json};

use super::{
    LedgerService,
    reserve::{json_i64, json_string, json_uuid},
    types::{
        JobId, JobState, LedgerAmount, LedgerError, MutationDisposition, ReservationResult,
        TerminalReleaseRequest, Version,
    },
};
use crate::db::ownership::{Authority, DurableDatabase, OperationRecord};

impl LedgerService {
    /// Records a signed non-success terminal without refunding the reservation,
    /// releases the failed attempt, and returns the job to `prepared` so its
    /// sole bounded alternate can be authorized.
    pub async fn retry_precontent(
        &self,
        request: &TerminalReleaseRequest,
    ) -> Result<ReservationResult, LedgerError> {
        request.validate()?;
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.retry_precontent_once(&authority, request).await;
            match result {
                Ok(Some(row)) => return retry_from_row(row, MutationDisposition::Applied),
                Ok(None) => {
                    return self
                        .resolve_precontent_retry(&authority, request, false)
                        .await;
                }
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::may_retry(attempt, source) =>
                {
                    self.db.retry_delay(attempt).await;
                    attempt += 1;
                }
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::is_operation_conflict(source) =>
                {
                    return self
                        .resolve_precontent_retry(&authority, request, false)
                        .await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self
                        .resolve_precontent_retry(&authority, request, true)
                        .await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn retry_precontent_once(
        &self,
        authority: &Authority,
        request: &TerminalReleaseRequest,
    ) -> Result<Option<PrecontentRetryRow>, LedgerError> {
        self.db
            .bounded(
                sqlx::query_as::<_, PrecontentRetryRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    locked AS MATERIALIZED (
                        SELECT jobs.*
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN rust_coord.inference_attempts AS attempts
                          ON attempts.job_id = jobs.job_id
                         AND attempts.attempt_id = $6
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.version = $4
                          AND jobs.state = $5
                          AND jobs.reservation_pre_debited
                          AND jobs.request_deadline > NOW()
                          AND attempts.owner_epoch = $2
                          AND attempts.version = $7
                          AND attempts.state IN (
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                          AND attempts.provider_id = $8
                          AND attempts.provider_process_generation_id = $9
                          AND attempts.session_epoch = $10
                          AND NOT EXISTS (
                              SELECT 1
                              FROM rust_coord.provider_hard_untrust_epochs
                                  AS untrusted
                              WHERE untrusted.provider_id = $8
                                AND untrusted.hard_untrust_epoch >= $10
                          )
                          AND $14::TEXT IN ('cancelled', 'error')
                          AND jobs.billable_input_tokens = $16
                          AND $18::BIGINT <= $17::BIGINT
                          AND $22::BIGINT >= $17::BIGINT
                          AND $22::BIGINT <= jobs.bounded_output_tokens
                        FOR UPDATE OF jobs, attempts
                    ),
                    terminal_insert AS (
                        INSERT INTO rust_coord.provider_terminals AS terminals (
                            terminal_id,
                            job_id,
                            attempt_id,
                            provider_id,
                            provider_process_generation_id,
                            origin_session_epoch,
                            terminal_digest,
                            raw_terminal,
                            outcome,
                            error_class,
                            prompt_tokens,
                            completion_tokens,
                            reasoning_tokens,
                            response_digest,
                            rolling_digest,
                            final_generated_tokens,
                            provider_signature,
                            status,
                            owner_epoch,
                            disposition_at
                        )
                        SELECT
                            $11, locked.job_id, $6, $8, $9, $10, $12, $13,
                            $14, $15, $16, $17, $18, $19, $21, $22, $20,
                            'released', $2, NOW()
                        FROM locked
                        ON CONFLICT (terminal_id) DO UPDATE SET
                            status = 'released',
                            owner_epoch = $2,
                            version = terminals.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW(),
                            disposition_at = NOW()
                        WHERE terminals.status = 'pending'
                          AND terminals.job_id = EXCLUDED.job_id
                          AND terminals.attempt_id = EXCLUDED.attempt_id
                          AND terminals.provider_id = EXCLUDED.provider_id
                          AND terminals.provider_process_generation_id
                              = EXCLUDED.provider_process_generation_id
                          AND terminals.origin_session_epoch
                              = EXCLUDED.origin_session_epoch
                          AND terminals.terminal_digest = EXCLUDED.terminal_digest
                          AND terminals.raw_terminal = EXCLUDED.raw_terminal
                          AND terminals.outcome = EXCLUDED.outcome
                          AND terminals.error_class
                              IS NOT DISTINCT FROM EXCLUDED.error_class
                          AND terminals.prompt_tokens = EXCLUDED.prompt_tokens
                          AND terminals.completion_tokens = EXCLUDED.completion_tokens
                          AND terminals.reasoning_tokens = EXCLUDED.reasoning_tokens
                          AND terminals.response_digest = EXCLUDED.response_digest
                          AND terminals.rolling_digest = EXCLUDED.rolling_digest
                          AND terminals.final_generated_tokens
                              = EXCLUDED.final_generated_tokens
                          AND terminals.provider_signature = EXCLUDED.provider_signature
                        RETURNING terminals.terminal_id
                    ),
                    operation_insert AS (
                        INSERT INTO rust_coord.financial_operations (
                            operation_id,
                            operation_key,
                            operation_digest,
                            kind,
                            status,
                            job_id,
                            terminal_id,
                            account_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd,
                            result,
                            owner_epoch,
                            version,
                            completed_at
                        )
                        SELECT
                            $23, $24, $25, 'release', 'applied', locked.job_id,
                            terminal_insert.terminal_id, locked.account_id, 0, 0,
                            jsonb_build_object(
                                'job_id', locked.job_id,
                                'version', $4::BIGINT + 1,
                                'state', 'prepared',
                                'total', locked.reserved_total_micro_usd,
                                'withdrawable',
                                    locked.reserved_withdrawable_micro_usd
                            ),
                            $2, 2, NOW()
                        FROM locked
                        CROSS JOIN terminal_insert
                        RETURNING operation_id
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = 'prepared',
                            outcome = NULL,
                            error_class = NULL,
                            usage_prompt_tokens = NULL,
                            usage_completion_tokens = NULL,
                            usage_reasoning_tokens = NULL,
                            response_digest = NULL,
                            accepted_chunk_sequence = 0,
                            accepted_cumulative_tokens = 0,
                            start_authorized_at = NULL,
                            start_deadline = NULL,
                            version = jobs.version + 1,
                            updated_at = NOW()
                        FROM locked, operation_insert
                        WHERE jobs.job_id = locked.job_id
                          AND jobs.version = $4
                          AND jobs.state = $5
                        RETURNING
                            jobs.job_id,
                            jobs.version,
                            jobs.state,
                            jobs.reserved_total_micro_usd,
                            jobs.reserved_withdrawable_micro_usd
                    ),
                    attempt_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            state = 'aborted',
                            version = attempts.version + 1,
                            updated_at = NOW(),
                            worker_owner = NULL,
                            lease_until = NULL
                        FROM job_update
                        WHERE attempts.attempt_id = $6
                          AND attempts.version = $7
                          AND attempts.state IN (
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                        RETURNING attempts.attempt_id
                    )
                    SELECT
                        job_update.job_id,
                        job_update.version,
                        job_update.state,
                        job_update.reserved_total_micro_usd,
                        job_update.reserved_withdrawable_micro_usd
                    FROM job_update
                    CROSS JOIN attempt_update
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(request.job_id.as_uuid())
                .bind(request.expected_job_version.as_i64())
                .bind(request.expected_job_state.as_str())
                .bind(request.terminal.attempt_id.as_uuid())
                .bind(request.expected_attempt_version.as_i64())
                .bind(request.terminal.provider_id)
                .bind(request.terminal.provider_process_generation_id)
                .bind(request.terminal.origin_session_epoch.as_i64())
                .bind(request.terminal.terminal_id.as_uuid())
                .bind(request.terminal.terminal_digest.as_bytes().as_slice())
                .bind(Json(&request.terminal.raw_terminal))
                .bind(request.terminal.outcome.as_str())
                .bind(request.terminal.error_class.as_deref())
                .bind(request.terminal.prompt_tokens as i64)
                .bind(request.terminal.completion_tokens as i64)
                .bind(request.terminal.reasoning_tokens as i64)
                .bind(request.terminal.response_digest.as_bytes().as_slice())
                .bind(request.terminal.provider_signature.as_slice())
                .bind(request.terminal.rolling_digest.as_bytes().as_slice())
                .bind(request.terminal.final_generated_tokens as i64)
                .bind(request.operation.id.as_uuid())
                .bind(request.operation.key.as_str())
                .bind(request.operation.digest.as_bytes().as_slice())
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    async fn resolve_precontent_retry(
        &self,
        authority: &Authority,
        request: &TerminalReleaseRequest,
        ambiguous: bool,
    ) -> Result<ReservationResult, LedgerError> {
        if let Some(operation) = self.db.operation(authority, &request.operation.key).await? {
            return retry_from_operation(operation, request);
        }
        if ambiguous {
            return Err(LedgerError::CommitOutcomeUnknown {
                operation: request.operation.key.clone(),
                diagnostic: "ambiguous precontent retry commit was not found during reconciliation"
                    .into(),
            });
        }
        let diagnostic = self
            .db
            .bounded(
                sqlx::query_as::<_, PrecontentRetryDiagnostic>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        EXISTS (
                            SELECT 1
                            FROM rust_coord.inference_jobs
                            WHERE job_id = $3
                              AND owner_epoch = $2
                              AND version = $4
                              AND state = $5
                        ) AS current,
                        NOT EXISTS (
                            SELECT 1
                            FROM rust_coord.provider_hard_untrust_epochs
                                AS untrusted
                            WHERE untrusted.provider_id = $6
                              AND untrusted.hard_untrust_epoch >= $7
                        ) AS provider_trusted
                    FROM authority
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(request.job_id.as_uuid())
                .bind(request.expected_job_version.as_i64())
                .bind(request.expected_job_state.as_str())
                .bind(request.terminal.provider_id)
                .bind(request.terminal.origin_session_epoch.as_i64())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match diagnostic {
            Some(row) if !row.current => Err(LedgerError::StaleVersion),
            Some(row) if !row.provider_trusted => Err(LedgerError::ProviderHardUntrusted),
            Some(_) => Err(LedgerError::OperationConflict),
            None => Err(LedgerError::OwnershipLost),
        }
    }
}

#[derive(Debug, FromRow)]
struct PrecontentRetryDiagnostic {
    current: bool,
    provider_trusted: bool,
}

#[derive(Debug, FromRow)]
struct PrecontentRetryRow {
    job_id: uuid::Uuid,
    version: i64,
    state: String,
    reserved_total_micro_usd: i64,
    reserved_withdrawable_micro_usd: i64,
}

fn retry_from_row(
    row: PrecontentRetryRow,
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
        state: JobState::from_database(&row.state)?,
    })
}

fn retry_from_operation(
    operation: OperationRecord,
    request: &TerminalReleaseRequest,
) -> Result<ReservationResult, LedgerError> {
    if operation.operation_key != request.operation.key.as_str()
        || operation.digest()? != request.operation.digest
        || operation.kind != "release"
        || operation.status != "applied"
        || operation.job_id != Some(request.job_id.as_uuid())
        || operation.terminal_id != Some(request.terminal.terminal_id.as_uuid())
    {
        return Err(LedgerError::OperationConflict);
    }
    retry_from_row(
        PrecontentRetryRow {
            job_id: json_uuid(&operation.result, "job_id")?,
            version: json_i64(&operation.result, "version")?,
            state: json_string(&operation.result, "state")?.to_owned(),
            reserved_total_micro_usd: json_i64(&operation.result, "total")?,
            reserved_withdrawable_micro_usd: json_i64(&operation.result, "withdrawable")?,
        },
        MutationDisposition::Replayed,
    )
}
