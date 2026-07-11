use std::sync::Arc;

use darkbloom_coordinator_core::ids::Digest;
use sqlx::FromRow;
use uuid::Uuid;

use super::{
    LedgerService,
    reserve::{json_i64, json_string, json_uuid},
    types::{
        AttemptId, JobId, JobState, LedgerAmount, LedgerError, MutationDisposition, Operation,
        OperationKey, ReviewDisposition, ReviewResolutionFacts, ReviewResolutionRequest,
        ReviewResolutionResult, SettleRequest, TerminalFacts, TerminalId, TerminalOutcome, Version,
        canonical_json_digest, priced_tokens,
    },
};
use crate::db::ownership::Authority;

impl LedgerService {
    /// Applies an explicit operator disposition to a quarantined job. Both
    /// branches journal the nonempty reason in the same transaction as the
    /// financial disposition.
    pub async fn resolve_review(
        &self,
        request: &ReviewResolutionRequest,
    ) -> Result<ReviewResolutionResult, LedgerError> {
        validate_review_request(request)?;
        match request.disposition {
            ReviewDisposition::Release => self.release_review(request).await,
            ReviewDisposition::Settle => self.settle_review(request).await,
        }
    }

    async fn release_review(
        &self,
        request: &ReviewResolutionRequest,
    ) -> Result<ReviewResolutionResult, LedgerError> {
        let authority = self.db.authority()?;
        let row = self
            .db
            .bounded(
                sqlx::query_as::<_, ReviewResolutionRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    locked AS MATERIALIZED (
                        SELECT jobs.*
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN public.balances AS balances
                          ON balances.account_id = jobs.account_id
                        CROSS JOIN authority
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.state = 'review_pending'
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
                            $4,
                            $5,
                            $6,
                            'release',
                            'released',
                            locked.job_id,
                            locked.account_id,
                            locked.reserved_total_micro_usd,
                            locked.reserved_withdrawable_micro_usd,
                            jsonb_build_object(
                                'job_id', locked.job_id,
                                'version', locked.version + 1,
                                'state', 'released_reviewed',
                                'total', locked.reserved_total_micro_usd,
                                'withdrawable',
                                    locked.reserved_withdrawable_micro_usd
                            ),
                            $2,
                            2,
                            NOW()
                        FROM locked
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
                            'rust-review-release:' || $5
                        FROM locked, balance_update
                        RETURNING id
                    ),
                    terminal_update AS (
                        UPDATE rust_coord.provider_terminals AS terminals
                        SET
                            status = 'released_reviewed',
                            owner_epoch = $2,
                            version = terminals.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW(),
                            disposition_at = NOW()
                        FROM locked, ledger_insert
                        WHERE terminals.job_id = locked.job_id
                          AND terminals.status IN (
                              'pending',
                              'conflict',
                              'rejected'
                          )
                        RETURNING terminals.terminal_id
                    ),
                    attempts_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            state = CASE
                                WHEN EXISTS (
                                    SELECT 1 FROM terminal_update
                                ) THEN 'terminal_recorded'
                                ELSE 'aborted'
                            END,
                            owner_epoch = $2,
                            version = attempts.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW()
                        FROM locked, ledger_insert
                        WHERE attempts.job_id = locked.job_id
                          AND attempts.state IN (
                              'prepared',
                              'not_sent',
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                        RETURNING attempts.attempt_id
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = 'released_reviewed',
                            error_class = 'operator_released_review',
                            version = jobs.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW(),
                            terminal_at = NOW()
                        FROM locked, ledger_insert
                        WHERE jobs.job_id = locked.job_id
                          AND jobs.version = locked.version
                          AND jobs.state = 'review_pending'
                        RETURNING jobs.job_id, jobs.version, jobs.state
                    ),
                    journal_insert AS (
                        INSERT INTO rust_coord.review_resolution_journal (
                            resolution_id,
                            job_id,
                            disposition,
                            operator_reason,
                            owner_epoch
                        )
                        SELECT
                            $7,
                            job_update.job_id,
                            'released_reviewed',
                            $8,
                            $2
                        FROM job_update
                        ON CONFLICT (job_id) DO NOTHING
                        RETURNING job_id
                    )
                    SELECT
                        job_update.job_id,
                        job_update.version,
                        job_update.state
                    FROM job_update
                    JOIN journal_insert USING (job_id)
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(request.job_id.as_uuid())
                .bind(request.operation.id.as_uuid())
                .bind(request.operation.key.as_str())
                .bind(request.operation.digest.as_bytes().as_slice())
                .bind(Uuid::new_v4())
                .bind(request.operator_reason.as_ref())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        if let Some(row) = row {
            return review_resolution_from_row(row, MutationDisposition::Applied);
        }
        self.resolve_review_replay(&authority, request).await
    }

    async fn settle_review(
        &self,
        request: &ReviewResolutionRequest,
    ) -> Result<ReviewResolutionResult, LedgerError> {
        let snapshot = match self.review_settlement_snapshot(request.job_id).await {
            Ok(snapshot) => snapshot,
            Err(LedgerError::NotFound) => {
                let authority = self.db.authority()?;
                return self.resolve_review_replay(&authority, request).await;
            }
            Err(error) => return Err(error),
        };
        let amounts = snapshot.amounts()?;
        let terminal = snapshot.terminal_facts()?;
        let settlement = self
            .settle(&SettleRequest {
                operation: request.operation.clone(),
                job_id: request.job_id,
                expected_job_version: snapshot.job_version()?,
                expected_job_state: JobState::ReviewPending,
                expected_attempt_version: snapshot.attempt_version()?,
                terminal,
                consumer_charge: amounts.0,
                provider_payout: amounts.1,
                platform_fee: amounts.2,
                referral_reward: amounts.3,
                accepted_cumulative_tokens: u64::try_from(snapshot.accepted_cumulative_tokens)
                    .map_err(|_| LedgerError::CorruptData("negative accepted output checkpoint"))?,
                consumer_key_hash: snapshot.consumer_key_hash.into(),
                review: Some(ReviewResolutionFacts {
                    resolution_id: Uuid::new_v4(),
                    operator_reason: request.operator_reason.clone(),
                }),
            })
            .await?;
        Ok(ReviewResolutionResult {
            disposition: settlement.disposition,
            job_id: settlement.job_id,
            state: JobState::SettledReviewed,
            version: settlement.version,
        })
    }

    async fn review_settlement_snapshot(
        &self,
        job_id: JobId,
    ) -> Result<ReviewSettlementRow, LedgerError> {
        let authority = self.db.authority()?;
        let row = self
            .db
            .bounded(
                sqlx::query_as::<_, ReviewSettlementRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        jobs.version AS job_version,
                        jobs.billable_input_tokens,
                        jobs.bounded_output_tokens,
                        jobs.accepted_cumulative_tokens,
                        jobs.input_micro_usd_per_million,
                        jobs.output_micro_usd_per_million,
                        jobs.provider_share_ppm,
                        jobs.referral_share_ppm,
                        jobs.consumer_key_hash,
                        attempts.version AS attempt_version,
                        terminals.terminal_id,
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
                        terminals.provider_signature
                    FROM rust_coord.inference_jobs AS jobs
                    JOIN rust_coord.inference_attempts AS attempts
                      ON attempts.job_id = jobs.job_id
                    JOIN LATERAL (
                        SELECT candidate.*
                        FROM rust_coord.provider_terminals AS candidate
                        WHERE candidate.job_id = jobs.job_id
                          AND candidate.attempt_id = attempts.attempt_id
                          AND candidate.status IN (
                              'pending',
                              'conflict',
                              'rejected'
                          )
                          AND candidate.worker_owner IS NULL
                        ORDER BY candidate.received_at, candidate.terminal_id
                        LIMIT 1
                    ) AS terminals ON TRUE
                    CROSS JOIN authority
                    WHERE jobs.job_id = $3
                      AND jobs.owner_epoch = $2
                      AND jobs.state = 'review_pending'
                      AND attempts.owner_epoch = $2
                      AND attempts.state IN (
                          'not_sent',
                          'queued',
                          'on_wire',
                          'sent_unknown',
                          'started'
                      )
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(job_id.as_uuid())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(row) = row else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::NotFound);
        };
        Ok(row)
    }

    async fn resolve_review_replay(
        &self,
        authority: &Authority,
        request: &ReviewResolutionRequest,
    ) -> Result<ReviewResolutionResult, LedgerError> {
        let Some(operation) = self.db.operation(authority, &request.operation.key).await? else {
            return Err(LedgerError::StaleVersion);
        };
        if operation.operation_key != request.operation.key.as_str()
            || operation.digest()? != request.operation.digest
            || operation.job_id != Some(request.job_id.as_uuid())
        {
            return Err(LedgerError::OperationConflict);
        }
        let expected_state = match request.disposition {
            ReviewDisposition::Release => "released_reviewed",
            ReviewDisposition::Settle => "settled_reviewed",
        };
        let journal_reason = self
            .db
            .bounded(
                sqlx::query_scalar::<_, String>(
                    r#"
                    SELECT operator_reason
                    FROM rust_coord.review_resolution_journal
                    WHERE job_id = $1 AND disposition = $2
                    "#,
                )
                .bind(request.job_id.as_uuid())
                .bind(expected_state)
                .fetch_optional(self.db.pool()),
            )
            .await?;
        if journal_reason.as_deref() != Some(request.operator_reason.as_ref()) {
            return Err(LedgerError::OperationConflict);
        }
        Ok(ReviewResolutionResult {
            disposition: MutationDisposition::Replayed,
            job_id: JobId::new(json_uuid(&operation.result, "job_id")?)
                .map_err(LedgerError::Invalid)?,
            state: JobState::from_database(json_string(&operation.result, "state")?)?,
            version: Version::from_database(json_i64(&operation.result, "version")?)?,
        })
    }
}

#[derive(Debug, FromRow)]
struct ReviewResolutionRow {
    job_id: Uuid,
    version: i64,
    state: String,
}

fn review_resolution_from_row(
    row: ReviewResolutionRow,
    disposition: MutationDisposition,
) -> Result<ReviewResolutionResult, LedgerError> {
    Ok(ReviewResolutionResult {
        disposition,
        job_id: JobId::new(row.job_id).map_err(LedgerError::Invalid)?,
        state: JobState::from_database(&row.state)?,
        version: Version::from_database(row.version)?,
    })
}

#[derive(Debug, FromRow)]
struct ReviewSettlementRow {
    job_version: i64,
    billable_input_tokens: Option<i64>,
    bounded_output_tokens: Option<i64>,
    accepted_cumulative_tokens: i64,
    input_micro_usd_per_million: Option<i64>,
    output_micro_usd_per_million: Option<i64>,
    provider_share_ppm: Option<i32>,
    referral_share_ppm: Option<i64>,
    consumer_key_hash: String,
    attempt_version: i64,
    terminal_id: Uuid,
    attempt_id: Uuid,
    provider_id: Uuid,
    provider_process_generation_id: Uuid,
    origin_session_epoch: i64,
    terminal_digest: Vec<u8>,
    raw_terminal: serde_json::Value,
    outcome: String,
    error_class: Option<String>,
    prompt_tokens: i64,
    completion_tokens: i64,
    reasoning_tokens: i64,
    response_digest: Vec<u8>,
    rolling_digest: Vec<u8>,
    final_generated_tokens: i64,
    provider_signature: Vec<u8>,
}

impl ReviewSettlementRow {
    fn amounts(
        &self,
    ) -> Result<(LedgerAmount, LedgerAmount, LedgerAmount, LedgerAmount), LedgerError> {
        let prompt_tokens = stored_tokens(self.prompt_tokens)?;
        if Some(self.prompt_tokens) != self.billable_input_tokens {
            return Err(LedgerError::CorruptData(
                "review terminal prompt usage differs from frozen prompt usage",
            ));
        }
        let completion_tokens = stored_tokens(self.completion_tokens)?;
        let bounded_output =
            stored_optional_tokens(self.bounded_output_tokens, "missing frozen output bound")?;
        let accepted_output = stored_tokens(self.accepted_cumulative_tokens)?;
        if completion_tokens > bounded_output || completion_tokens > accepted_output {
            return Err(LedgerError::CorruptData(
                "review terminal completion exceeds accepted output checkpoint",
            ));
        }
        let input_rate = stored_amount(
            self.input_micro_usd_per_million,
            "missing frozen input rate",
        )?;
        let output_rate = stored_amount(
            self.output_micro_usd_per_million,
            "missing frozen output rate",
        )?;
        let charge = priced_tokens(prompt_tokens, input_rate)?
            .checked_add(priced_tokens(completion_tokens, output_rate)?)?;
        let provider_share = stored_ppm(self.provider_share_ppm, "missing provider share")?;
        let referral_share = stored_ppm(self.referral_share_ppm, "missing referral share")?;
        let provider = proportional(charge, provider_share)?;
        let gross_fee = charge.checked_sub(provider)?;
        let referral = proportional(gross_fee, referral_share)?;
        let platform = gross_fee.checked_sub(referral)?;
        Ok((charge, provider, platform, referral))
    }

    fn terminal_facts(&self) -> Result<TerminalFacts, LedgerError> {
        Ok(TerminalFacts {
            terminal_id: TerminalId::new(self.terminal_id).map_err(LedgerError::Invalid)?,
            attempt_id: AttemptId::new(self.attempt_id).map_err(LedgerError::Invalid)?,
            provider_id: self.provider_id,
            provider_process_generation_id: self.provider_process_generation_id,
            origin_session_epoch: Version::from_database(self.origin_session_epoch)?,
            terminal_digest: stored_digest(&self.terminal_digest, "stored terminal digest width")?,
            raw_terminal: self.raw_terminal.clone(),
            outcome: TerminalOutcome::from_database(&self.outcome)?,
            error_class: self.error_class.clone().map(Arc::from),
            prompt_tokens: stored_tokens(self.prompt_tokens)?,
            completion_tokens: stored_tokens(self.completion_tokens)?,
            reasoning_tokens: stored_tokens(self.reasoning_tokens)?,
            response_digest: stored_digest(&self.response_digest, "stored response digest width")?,
            rolling_digest: stored_digest(&self.rolling_digest, "stored rolling digest width")?,
            final_generated_tokens: stored_tokens(self.final_generated_tokens)?,
            provider_signature: self.provider_signature.clone(),
            recovery_lease: None,
        })
    }

    fn job_version(&self) -> Result<Version, LedgerError> {
        Version::from_database(self.job_version)
    }

    fn attempt_version(&self) -> Result<Version, LedgerError> {
        Version::from_database(self.attempt_version)
    }
}

fn validate_review_request(request: &ReviewResolutionRequest) -> Result<(), LedgerError> {
    if request.operator_reason.is_empty()
        || request.operator_reason.trim() != request.operator_reason.as_ref()
        || request.operator_reason.len() > 4_096
    {
        return Err(super::types::InputError::Empty("operator review reason").into());
    }
    Ok(())
}

fn proportional(amount: LedgerAmount, share_ppm: u32) -> Result<LedgerAmount, LedgerError> {
    let scaled = u128::from(amount.as_i64() as u64)
        .checked_mul(u128::from(share_ppm))
        .ok_or(super::types::InputError::ArithmeticOverflow)?
        / 1_000_000;
    LedgerAmount::new(
        u64::try_from(scaled).map_err(|_| super::types::InputError::ArithmeticOverflow)?,
    )
    .map_err(LedgerError::Invalid)
}

fn stored_tokens(value: i64) -> Result<u64, LedgerError> {
    u64::try_from(value).map_err(|_| LedgerError::CorruptData("negative stored token count"))
}

fn stored_optional_tokens(value: Option<i64>, error: &'static str) -> Result<u64, LedgerError> {
    stored_tokens(value.ok_or(LedgerError::CorruptData(error))?)
}

fn stored_amount(value: Option<i64>, error: &'static str) -> Result<LedgerAmount, LedgerError> {
    LedgerAmount::from_i64(value.ok_or(LedgerError::CorruptData(error))?)
        .map_err(LedgerError::Invalid)
}

fn stored_ppm<T>(value: Option<T>, error: &'static str) -> Result<u32, LedgerError>
where
    T: TryInto<u32>,
{
    let value = value
        .ok_or(LedgerError::CorruptData(error))?
        .try_into()
        .map_err(|_| LedgerError::CorruptData(error))?;
    if value > 1_000_000 {
        return Err(LedgerError::CorruptData(error));
    }
    Ok(value)
}

fn stored_digest(value: &[u8], error: &'static str) -> Result<Digest, LedgerError> {
    Digest::try_from(value).map_err(|_| LedgerError::CorruptData(error))
}

/// Builds a replay-stable operator operation from the journaled inputs.
pub fn review_resolution_operation(
    job_id: JobId,
    disposition: ReviewDisposition,
    operator_reason: &str,
) -> Result<Operation, LedgerError> {
    let disposition = match disposition {
        ReviewDisposition::Settle => "settled_reviewed",
        ReviewDisposition::Release => "released_reviewed",
    };
    let payload = serde_json::json!({
        "disposition": disposition,
        "job_id": job_id.as_uuid(),
        "operator_reason": operator_reason,
    });
    Ok(Operation::new(
        OperationKey::new(format!("review-resolve:{job_id}:{disposition}"))?,
        canonical_json_digest(&payload)?,
    ))
}
