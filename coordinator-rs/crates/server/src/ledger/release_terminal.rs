use sqlx::{FromRow, types::Json};

use super::{
    LedgerService,
    reserve::{json_i64, json_string, json_uuid},
    types::{
        JobId, JobState, LedgerAmount, LedgerError, MutationDisposition, OperationKey,
        ReservationResult, TerminalReleaseRequest, Version,
    },
};
use crate::db::ownership::{Authority, DurableDatabase, OperationRecord};

impl LedgerService {
    /// Atomically records a signed non-success terminal, refunds the exact
    /// reservation provenance, and terminalizes the job and attempt.
    pub async fn release_terminal(
        &self,
        request: &TerminalReleaseRequest,
    ) -> Result<ReservationResult, LedgerError> {
        request.validate()?;
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.release_terminal_once(&authority, request).await;
            match result {
                Ok(Some(row)) => {
                    return terminal_release_from_row(row, MutationDisposition::Applied);
                }
                Ok(None) => {
                    return self
                        .resolve_terminal_release(&authority, request, false)
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
                        .resolve_terminal_release(&authority, request, false)
                        .await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self
                        .resolve_terminal_release(&authority, request, true)
                        .await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn release_terminal_once(
        &self,
        authority: &Authority,
        request: &TerminalReleaseRequest,
    ) -> Result<Option<TerminalReleaseRow>, LedgerError> {
        let recovery_worker = request
            .terminal
            .recovery_lease
            .as_ref()
            .map(|lease| lease.worker_id);
        let recovery_version = request
            .terminal
            .recovery_lease
            .as_ref()
            .map(|lease| lease.version.as_i64());
        self.db
            .bounded(
                sqlx::query_as::<_, TerminalReleaseRow>(
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
                        JOIN public.balances AS balances
                          ON balances.account_id = jobs.account_id
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
                          AND $29::BIGINT <= jobs.bounded_output_tokens
                          AND (
                              $27::UUID IS NULL
                              OR $29::BIGINT
                                 <= jobs.accepted_cumulative_tokens
                          )
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
                        FOR UPDATE OF jobs, attempts, balances
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
                          AND (
                              (
                                  $27::UUID IS NULL
                                  AND $28::BIGINT IS NULL
                                  AND terminals.worker_owner IS NULL
                              )
                              OR (
                                  terminals.worker_owner = $27
                                  AND terminals.version = $28
                                  AND terminals.lease_until > NOW()
                              )
                          )
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
                            $23, $24, $25, 'release', 'released', locked.job_id,
                            terminal_insert.terminal_id, locked.account_id,
                            locked.reserved_total_micro_usd,
                            locked.reserved_withdrawable_micro_usd,
                            jsonb_build_object(
                                'job_id', locked.job_id,
                                'version', $4::BIGINT + 1,
                                'state', 'released',
                                'total', locked.reserved_total_micro_usd,
                                'withdrawable',
                                    locked.reserved_withdrawable_micro_usd
                            ),
                            $2, 2, NOW()
                        FROM locked
                        CROSS JOIN terminal_insert
                        RETURNING operation_id
                    ),
                    balance_update AS (
                        UPDATE public.balances AS balances
                        SET
                            balance_micro_usd =
                                balances.balance_micro_usd
                                + locked.reserved_total_micro_usd,
                            withdrawable_micro_usd =
                                balances.withdrawable_micro_usd
                                + locked.reserved_withdrawable_micro_usd,
                            updated_at = NOW()
                        FROM locked, operation_insert
                        WHERE balances.account_id = locked.account_id
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
                            locked.account_id,
                            'refund',
                            locked.reserved_total_micro_usd,
                            balance_update.balance_micro_usd,
                            'rust-terminal-release:' || $24
                        FROM locked, balance_update
                        RETURNING id
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = 'released',
                            outcome = $14,
                            error_class = COALESCE($15, $26),
                            usage_prompt_tokens = $16,
                            usage_completion_tokens = $29,
                            usage_reasoning_tokens = $18,
                            accepted_cumulative_tokens = GREATEST(
                                jobs.accepted_cumulative_tokens,
                                $29::BIGINT
                            ),
                            response_digest = $19,
                            version = jobs.version + 1,
                            updated_at = NOW(),
                            terminal_at = NOW(),
                            worker_owner = NULL,
                            lease_until = NULL
                        FROM locked, ledger_insert
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
                            state = 'terminal_recorded',
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
                .bind(request.reason.as_ref())
                .bind(recovery_worker)
                .bind(recovery_version)
                .bind(
                    i64::try_from(request.accepted_cumulative_tokens)
                        .expect("validated accepted token checkpoint fits i64"),
                )
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    async fn resolve_terminal_release(
        &self,
        authority: &Authority,
        request: &TerminalReleaseRequest,
        ambiguous: bool,
    ) -> Result<ReservationResult, LedgerError> {
        if let Some(operation) = self.db.operation(authority, &request.operation.key).await? {
            return terminal_release_from_operation(operation, request);
        }
        if ambiguous {
            return Err(LedgerError::CommitOutcomeUnknown {
                operation: request.operation.key.clone(),
                diagnostic: "ambiguous terminal release commit was not found during reconciliation"
                    .into(),
            });
        }
        let diagnostic = self
            .db
            .bounded(
                sqlx::query_as::<_, TerminalReleaseDiagnostic>(
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
struct TerminalReleaseDiagnostic {
    current: bool,
    provider_trusted: bool,
}

#[derive(Debug, FromRow)]
struct TerminalReleaseRow {
    job_id: uuid::Uuid,
    version: i64,
    state: String,
    reserved_total_micro_usd: i64,
    reserved_withdrawable_micro_usd: i64,
}

fn terminal_release_from_row(
    row: TerminalReleaseRow,
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

fn terminal_release_from_operation(
    operation: OperationRecord,
    request: &TerminalReleaseRequest,
) -> Result<ReservationResult, LedgerError> {
    if operation.operation_key != request.operation.key.as_str()
        || operation.digest()? != request.operation.digest
        || operation.kind != "release"
        || operation.status != "released"
        || operation.job_id != Some(request.job_id.as_uuid())
        || operation.terminal_id != Some(request.terminal.terminal_id.as_uuid())
    {
        return Err(LedgerError::OperationConflict);
    }
    terminal_release_from_row(
        TerminalReleaseRow {
            job_id: json_uuid(&operation.result, "job_id")?,
            version: json_i64(&operation.result, "version")?,
            state: json_string(&operation.result, "state")?.to_owned(),
            reserved_total_micro_usd: json_i64(&operation.result, "total")?,
            reserved_withdrawable_micro_usd: json_i64(&operation.result, "withdrawable")?,
        },
        MutationDisposition::Replayed,
    )
}

#[allow(dead_code)]
fn _operation_key_type_pin(_: OperationKey) {}
