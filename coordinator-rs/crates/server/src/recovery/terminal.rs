use sqlx::FromRow;

use super::{RecoveryService, TerminalRecoveryLease};
use crate::ledger::{
    JobState, LedgerAmount, LedgerError, LedgerService, Operation, OperationKey, SettleRequest,
    TerminalReleaseRequest, canonical_json_digest,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveredTerminalDisposition {
    Settled,
    Released,
}

impl RecoveryService {
    /// Applies one leased terminal using only frozen durable pricing facts.
    /// Output charging is capped by the last durable accepted checkpoint; the
    /// current pilot deliberately leaves that checkpoint at zero after a crash.
    pub async fn disposition_terminal(
        &self,
        ledger: &LedgerService,
        lease: TerminalRecoveryLease,
    ) -> Result<RecoveredTerminalDisposition, LedgerError> {
        let pricing = self.terminal_pricing(&lease).await?;
        ledger
            .ensure_provider_trusted(lease.provider_id, lease.origin_session_epoch)
            .await?;
        let completion_tokens = lease.completion_tokens;
        let accepted_cumulative_tokens = pricing.accepted_cumulative_tokens;
        let terminal = lease.into_terminal_facts();
        let operation_payload = serde_json::json!({
            "accepted_completion_tokens": accepted_cumulative_tokens,
            "job_id": pricing.job_id.as_uuid(),
            "terminal_digest": terminal.terminal_digest.as_bytes(),
        });
        let operation_kind = match terminal.outcome {
            crate::ledger::TerminalOutcome::Completed => "settle",
            crate::ledger::TerminalOutcome::Cancelled | crate::ledger::TerminalOutcome::Error => {
                "release"
            }
        };
        let operation = Operation::new(
            OperationKey::new(format!(
                "recovery:{operation_kind}:{}",
                terminal.terminal_id
            ))?,
            canonical_json_digest(&operation_payload)?,
        );
        match terminal.outcome {
            crate::ledger::TerminalOutcome::Completed => {
                let amounts = pricing.amounts(completion_tokens)?;
                ledger
                    .settle(&SettleRequest {
                        operation,
                        job_id: pricing.job_id,
                        expected_job_version: pricing.job_version,
                        expected_job_state: pricing.job_state,
                        expected_attempt_version: pricing.attempt_version,
                        terminal,
                        consumer_charge: amounts.0,
                        provider_payout: amounts.1,
                        platform_fee: amounts.2,
                        referral_reward: amounts.3,
                        accepted_cumulative_tokens: pricing.accepted_cumulative_tokens,
                        consumer_key_hash: pricing.consumer_key_hash.into(),
                        review: None,
                    })
                    .await?;
                Ok(RecoveredTerminalDisposition::Settled)
            }
            crate::ledger::TerminalOutcome::Cancelled | crate::ledger::TerminalOutcome::Error => {
                ledger
                    .release_terminal(&TerminalReleaseRequest {
                        operation,
                        job_id: pricing.job_id,
                        expected_job_version: pricing.job_version,
                        expected_job_state: pricing.job_state,
                        expected_attempt_version: pricing.attempt_version,
                        terminal,
                        accepted_cumulative_tokens,
                        reason: "recovered non-success provider terminal".into(),
                    })
                    .await?;
                Ok(RecoveredTerminalDisposition::Released)
            }
        }
    }

    async fn terminal_pricing(
        &self,
        lease: &TerminalRecoveryLease,
    ) -> Result<RecoveryPricing, LedgerError> {
        let authority = self.db.authority()?;
        let row = self
            .db
            .bounded(
                sqlx::query_as::<_, RecoveryPricingRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        jobs.job_id,
                        jobs.version AS job_version,
                        jobs.state AS job_state,
                        jobs.billable_input_tokens,
                        jobs.bounded_output_tokens,
                        jobs.accepted_cumulative_tokens,
                        jobs.input_micro_usd_per_million,
                        jobs.output_micro_usd_per_million,
                        jobs.provider_share_ppm,
                        jobs.referral_share_ppm::INTEGER AS referral_share_ppm,
                        jobs.consumer_key_hash,
                        attempts.version AS attempt_version
                    FROM rust_coord.inference_jobs AS jobs
                    JOIN rust_coord.inference_attempts AS attempts
                      ON attempts.job_id = jobs.job_id
                     AND attempts.attempt_id = $4
                    JOIN rust_coord.provider_terminals AS terminals
                      ON terminals.job_id = jobs.job_id
                     AND terminals.attempt_id = attempts.attempt_id
                     AND terminals.terminal_id = $7
                    CROSS JOIN authority
                    WHERE jobs.job_id = $3
                      AND jobs.owner_epoch = $2
                      AND jobs.version = $5
                      AND jobs.state = $6
                      AND attempts.owner_epoch = $2
                      AND attempts.version = $8
                      AND terminals.owner_epoch = $2
                      AND terminals.worker_owner = $9
                      AND terminals.version = $10
                      AND terminals.status = 'pending'
                      AND terminals.lease_until > NOW()
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(lease.job_id.as_uuid())
                .bind(lease.attempt_id.as_uuid())
                .bind(lease.job_version.as_i64())
                .bind(lease.job_state.as_str())
                .bind(lease.terminal_id.as_uuid())
                .bind(lease.attempt_version.as_i64())
                .bind(lease.worker_id)
                .bind(lease.version.as_i64())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(row) = row else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::StaleVersion);
        };
        row.validate(lease)
    }
}

#[derive(Debug, FromRow)]
struct RecoveryPricingRow {
    job_id: uuid::Uuid,
    job_version: i64,
    job_state: String,
    billable_input_tokens: Option<i64>,
    bounded_output_tokens: Option<i64>,
    accepted_cumulative_tokens: i64,
    input_micro_usd_per_million: Option<i64>,
    output_micro_usd_per_million: Option<i64>,
    provider_share_ppm: Option<i32>,
    referral_share_ppm: Option<i32>,
    consumer_key_hash: String,
    attempt_version: i64,
}

impl RecoveryPricingRow {
    fn validate(mut self, lease: &TerminalRecoveryLease) -> Result<RecoveryPricing, LedgerError> {
        let job_id = crate::ledger::JobId::new(self.job_id).map_err(LedgerError::Invalid)?;
        if lease.prompt_tokens
            != stored_optional_tokens(
                self.billable_input_tokens,
                "missing frozen input token count",
            )?
        {
            return Err(LedgerError::TerminalReview(
                "terminal prompt usage differs from frozen input tokens",
            ));
        }
        let bounded_output_tokens =
            stored_optional_tokens(self.bounded_output_tokens, "missing frozen output bound")?;
        let accepted_cumulative_tokens = stored_tokens(self.accepted_cumulative_tokens)?;
        if lease.completion_tokens > bounded_output_tokens
            || lease.final_generated_tokens > bounded_output_tokens
            || lease.final_generated_tokens < lease.completion_tokens
            || lease.reasoning_tokens > lease.completion_tokens
            || (lease.outcome == crate::ledger::TerminalOutcome::Completed
                && lease.final_generated_tokens != lease.completion_tokens)
        {
            return Err(LedgerError::TerminalReview(
                "terminal usage differs from frozen provider bounds",
            ));
        }
        if lease.outcome == crate::ledger::TerminalOutcome::Completed
            && lease.completion_tokens > accepted_cumulative_tokens
        {
            return Err(LedgerError::TerminalReview(
                "terminal completion exceeds the durable accepted checkpoint",
            ));
        }
        if self.consumer_key_hash.is_empty() {
            return Err(LedgerError::CorruptData(
                "paid job is missing consumer key provenance",
            ));
        }
        Ok(RecoveryPricing {
            job_id,
            job_version: crate::ledger::Version::from_database(self.job_version)?,
            job_state: JobState::from_database(&self.job_state)?,
            attempt_version: crate::ledger::Version::from_database(self.attempt_version)?,
            prompt_tokens: lease.prompt_tokens,
            accepted_cumulative_tokens,
            input_rate: stored_amount(
                self.input_micro_usd_per_million,
                "missing frozen input rate",
            )?,
            output_rate: stored_amount(
                self.output_micro_usd_per_million,
                "missing frozen output rate",
            )?,
            provider_share_ppm: stored_ppm(
                self.provider_share_ppm,
                "missing frozen provider share",
            )?,
            referral_share_ppm: stored_ppm(
                self.referral_share_ppm,
                "missing frozen referral share",
            )?,
            consumer_key_hash: std::mem::take(&mut self.consumer_key_hash),
        })
    }
}

struct RecoveryPricing {
    job_id: crate::ledger::JobId,
    job_version: crate::ledger::Version,
    job_state: JobState,
    attempt_version: crate::ledger::Version,
    prompt_tokens: u64,
    accepted_cumulative_tokens: u64,
    input_rate: LedgerAmount,
    output_rate: LedgerAmount,
    provider_share_ppm: u32,
    referral_share_ppm: u32,
    consumer_key_hash: String,
}

impl RecoveryPricing {
    fn amounts(
        &self,
        completion_tokens: u64,
    ) -> Result<(LedgerAmount, LedgerAmount, LedgerAmount, LedgerAmount), LedgerError> {
        let charge =
            crate::ledger::types::priced_tokens(self.prompt_tokens, self.input_rate)?.checked_add(
                crate::ledger::types::priced_tokens(completion_tokens, self.output_rate)?,
            )?;
        let provider = proportional(charge, self.provider_share_ppm)?;
        let gross_fee = charge.checked_sub(provider)?;
        let referral = proportional(gross_fee, self.referral_share_ppm)?;
        let platform = gross_fee.checked_sub(referral)?;
        Ok((charge, provider, platform, referral))
    }
}

fn proportional(amount: LedgerAmount, share_ppm: u32) -> Result<LedgerAmount, LedgerError> {
    let value = u128::from(amount.as_i64() as u64)
        .checked_mul(u128::from(share_ppm))
        .ok_or(crate::ledger::InputError::ArithmeticOverflow)?
        / 1_000_000;
    LedgerAmount::new(
        u64::try_from(value).map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?,
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

fn stored_ppm(value: Option<i32>, error: &'static str) -> Result<u32, LedgerError> {
    let value = u32::try_from(value.ok_or(LedgerError::CorruptData(error))?)
        .map_err(|_| LedgerError::CorruptData(error))?;
    if value > 1_000_000 {
        return Err(LedgerError::CorruptData(error));
    }
    Ok(value)
}
