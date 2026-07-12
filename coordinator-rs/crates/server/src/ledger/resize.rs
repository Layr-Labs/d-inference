use std::sync::Arc;

use sqlx::FromRow;

use super::{
    LedgerService,
    reserve::{json_i64, json_string, json_uuid},
    types::{
        JobId, JobState, LedgerAmount, LedgerError, MutationDisposition, PreparedReservation,
        ReservationResult, Version,
    },
};
use crate::db::ownership::{Authority, DurableDatabase, OperationRecord};

impl LedgerService {
    /// Freezes prepared provider/pricing facts, resizes the exact reservation,
    /// and performs the start-authorized CAS atomically.
    pub async fn resize_and_authorize(
        &self,
        prepared: &PreparedReservation,
    ) -> Result<ReservationResult, LedgerError> {
        prepared.validate()?;
        if !matches!(
            prepared.expected_state,
            JobState::Reserved | JobState::Preparing | JobState::Prepared
        ) {
            return Err(LedgerError::StaleVersion);
        }
        let maximum_charge = prepared.maximum_charge()?;
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.resize_once(&authority, prepared, maximum_charge).await;
            match result {
                Ok(Some(row)) => return resize_from_row(row, MutationDisposition::Applied),
                Ok(None) => {
                    return self
                        .resolve_resize(&authority, prepared, maximum_charge, false)
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
                        .resolve_resize_conflict(&authority, prepared, maximum_charge)
                        .await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self
                        .resolve_resize(&authority, prepared, maximum_charge, true)
                        .await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn resize_once(
        &self,
        authority: &Authority,
        prepared: &PreparedReservation,
        maximum_charge: LedgerAmount,
    ) -> Result<Option<ResizeRow>, LedgerError> {
        let referral_account = prepared
            .referral_account_id
            .as_ref()
            .map(|account| account.as_str());
        let mut transaction = self.db.bounded(self.db.pool().begin()).await?;
        let controlled_key_hash = self
            .db
            .bounded(
                sqlx::query_scalar::<_, String>(
                    r#"
                    SELECT consumer_key_hash
                    FROM rust_coord.inference_jobs
                    WHERE job_id = $1 AND api_key_reserved_micro_usd > 0
                    "#,
                )
                .bind(prepared.job_id.as_uuid())
                .fetch_optional(&mut *transaction),
            )
            .await?;
        if let Some(key_hash) = controlled_key_hash {
            // A controlled request first reserves a small base amount and then
            // resizes to its maximum charge. Serialize both phases on the same
            // key so concurrent resizes cannot evaluate cumulative spend from
            // snapshots taken before another resize commits.
            self.db
                .bounded(
                    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1::TEXT, 0))")
                        .bind(key_hash)
                        .execute(&mut *transaction),
                )
                .await?;
        }
        let row = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    ResizeRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    job AS MATERIALIZED (
                        SELECT
                            jobs.*,
                            balances.balance_micro_usd,
                            balances.withdrawable_micro_usd,
                            CASE
                                WHEN $22::BIGINT >= jobs.reserved_total_micro_usd
                                THEN jobs.reserved_withdrawable_micro_usd
                                    + GREATEST(
                                        0::BIGINT,
                                        (
                                            $22::BIGINT
                                            - jobs.reserved_total_micro_usd
                                        ) - (
                                            balances.balance_micro_usd
                                            - balances.withdrawable_micro_usd
                                        )
                                    )
                                ELSE jobs.reserved_withdrawable_micro_usd
                                    - LEAST(
                                        jobs.reserved_total_micro_usd - $22::BIGINT,
                                        jobs.reserved_withdrawable_micro_usd
                                    )
                            END AS new_reserved_withdrawable
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN public.balances AS balances
                          ON balances.account_id = jobs.account_id
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.version = $4
                          AND jobs.state = $5
                          AND jobs.reservation_pre_debited
                          AND jobs.request_deadline > NOW()
                          AND NOT EXISTS (
                              SELECT 1
                              FROM rust_coord.provider_hard_untrust_epochs
                                  AS untrusted
                              WHERE untrusted.provider_id = $10
                                AND untrusted.hard_untrust_epoch >= $12
                          )
                          AND (
                              (
                                  $35::UUID IS NULL
                                  AND jobs.worker_owner IS NULL
                              )
                              OR (
                                  jobs.worker_owner = $35
                                  AND jobs.lease_until > NOW()
                              )
                          )
                          AND balances.balance_micro_usd >= 0
                          AND balances.withdrawable_micro_usd >= 0
                          AND balances.withdrawable_micro_usd
                              <= balances.balance_micro_usd
                          AND (
                              $22::BIGINT <= jobs.reserved_total_micro_usd
                              OR balances.balance_micro_usd >= (
                                  $22::BIGINT
                                  - jobs.reserved_total_micro_usd
                              )
                          )
                          AND (
                              $22::BIGINT >= jobs.reserved_total_micro_usd
                              OR balances.balance_micro_usd <= (
                                  9223372036854775807::BIGINT
                                  - (
                                      jobs.reserved_total_micro_usd
                                      - $22::BIGINT
                                  )
                              )
                          )
                          AND (
                              jobs.api_key_reserved_micro_usd = 0
                              OR EXISTS (
                                  SELECT 1
                                  FROM public.api_keys AS keys
                                  WHERE keys.id = jobs.api_key_id
                                    AND keys.key_hash = jobs.consumer_key_hash
                                    AND keys.owner_account_id = jobs.account_id
                                    AND keys.active
                                    AND (
                                        keys.expires_at IS NULL
                                        OR keys.expires_at > NOW()
                                    )
                                    AND (
                                        keys.allowed_models IN ('', '[]')
                                        OR EXISTS (
                                            SELECT 1
                                            FROM jsonb_array_elements_text(
                                                keys.allowed_models::JSONB
                                            ) AS allowed(model)
                                            WHERE allowed.model IN ($17, $18)
                                        )
                                    )
                                    AND (
                                        NOT keys.self_route_only
                                        OR EXISTS (
                                            SELECT 1
                                            FROM public.providers AS providers
                                            WHERE providers.id = $10::TEXT
                                              AND providers.account_id =
                                                  jobs.account_id
                                              AND providers.connected
                                              AND providers.trust_level =
                                                  'hardware'
                                              AND providers.session_epoch = $12
                                        )
                                    )
                                    AND (
                                        keys.limit_micro_usd IS NULL
                                        OR (
                                            COALESCE((
                                                SELECT SUM(
                                                    usage.cost_micro_usd
                                                )
                                                FROM public.usage
                                                WHERE usage.key_id = keys.id
                                                  AND usage.created_at >=
                                                    CASE keys.limit_reset
                                                      WHEN 'daily'
                                                        THEN date_trunc('day', NOW())
                                                      WHEN 'weekly'
                                                        THEN date_trunc('week', NOW())
                                                      WHEN 'monthly'
                                                        THEN date_trunc('month', NOW())
                                                      ELSE '-infinity'::TIMESTAMPTZ
                                                    END
                                            ), 0)::NUMERIC
                                            + COALESCE((
                                                SELECT SUM(
                                                    controlled_jobs
                                                        .api_key_reserved_micro_usd
                                                )
                                                FROM rust_coord.inference_jobs
                                                    AS controlled_jobs
                                                WHERE controlled_jobs.api_key_id =
                                                      keys.id
                                                  AND controlled_jobs.account_id =
                                                      jobs.account_id
                                                  AND controlled_jobs.job_id <>
                                                      jobs.job_id
                                                  AND controlled_jobs.state NOT IN (
                                                    'settled',
                                                    'released',
                                                    'settled_reviewed',
                                                    'released_reviewed'
                                                  )
                                            ), 0)::NUMERIC
                                            + $22::NUMERIC
                                            <= keys.limit_micro_usd::NUMERIC
                                        )
                                    )
                              )
                          )
                        FOR UPDATE OF jobs, balances
                    ),
                    beneficiary_seed AS (
                        INSERT INTO public.balances (
                            account_id,
                            balance_micro_usd,
                            withdrawable_micro_usd,
                            updated_at
                        )
                        SELECT account_id, 0, 0, NOW()
                        FROM (
                            SELECT DISTINCT account_id
                            FROM (
                                VALUES ($24::TEXT), ($25::TEXT), ($26::TEXT)
                            ) AS beneficiaries(account_id)
                            WHERE account_id IS NOT NULL
                        ) AS distinct_beneficiaries
                        ORDER BY account_id
                        ON CONFLICT (account_id) DO NOTHING
                        RETURNING account_id
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
                            'resize',
                            'applied',
                            job.job_id,
                            job.account_id,
                            $22::BIGINT - job.reserved_total_micro_usd,
                            job.new_reserved_withdrawable
                                - job.reserved_withdrawable_micro_usd,
                            jsonb_build_object(
                                'job_id', job.job_id,
                                'version', $4::BIGINT + 1,
                                'state', 'start_authorized',
                                'total', $22::BIGINT,
                                'withdrawable',
                                    job.new_reserved_withdrawable,
                                'input_rate', $31::BIGINT,
                                'output_rate', $32::BIGINT,
                                'provider_share_ppm', $34::BIGINT,
                                'pricing_version', $19::BIGINT,
                                'rounding_version', $20::BIGINT
                            ),
                            $2,
                            2,
                            NOW()
                        FROM authority
                        CROSS JOIN job
                        LEFT JOIN (
                            SELECT COUNT(*) AS seeded FROM beneficiary_seed
                        ) AS seeded ON TRUE
                        RETURNING operation_id
                    ),
                    attempt_insert AS (
                        INSERT INTO rust_coord.inference_attempts (
                            attempt_id,
                            job_id,
                            provider_id,
                            provider_process_generation_id,
                            session_epoch,
                            owner_epoch,
                            lease_id,
                            permit_id,
                            dispatch_nonce,
                            request_digest,
                            kind,
                            state,
                            worker_owner,
                            lease_until
                        )
                        SELECT
                            $9,
                            job.job_id,
                            $10,
                            $11,
                            $12,
                            $2,
                            $13,
                            $14,
                            $15,
                            $16,
                            $33::TEXT,
                            'not_sent',
                            $35,
                            job.lease_until
                        FROM job
                        CROSS JOIN operation_insert
                        RETURNING attempt_id
                    ),
                    balance_update AS (
                        UPDATE public.balances AS balances
                        SET
                            balance_micro_usd = CASE
                                WHEN $22::BIGINT
                                    >= job.reserved_total_micro_usd
                                THEN balances.balance_micro_usd - (
                                    $22::BIGINT
                                    - job.reserved_total_micro_usd
                                )
                                ELSE balances.balance_micro_usd + (
                                    job.reserved_total_micro_usd
                                    - $22::BIGINT
                                )
                            END,
                            withdrawable_micro_usd = CASE
                                WHEN job.new_reserved_withdrawable
                                    >= job.reserved_withdrawable_micro_usd
                                THEN balances.withdrawable_micro_usd - (
                                    job.new_reserved_withdrawable
                                    - job.reserved_withdrawable_micro_usd
                                )
                                ELSE balances.withdrawable_micro_usd + (
                                    job.reserved_withdrawable_micro_usd
                                    - job.new_reserved_withdrawable
                                )
                            END,
                            updated_at = NOW()
                        FROM job, operation_insert, attempt_insert
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
                            CASE
                                WHEN $22::BIGINT > job.reserved_total_micro_usd
                                THEN 'charge'
                                ELSE 'refund'
                            END,
                            job.reserved_total_micro_usd - $22::BIGINT,
                            balance_update.balance_micro_usd,
                            'rust-resize:' || $7
                        FROM job
                        CROSS JOIN balance_update
                        RETURNING id
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = 'start_authorized',
                            reserved_total_micro_usd = $22,
                            reserved_withdrawable_micro_usd =
                                job.new_reserved_withdrawable,
                            concrete_model = $17,
                            public_model = $18,
                            pricing_version = $19,
                            rounding_version = $20,
                            billable_input_tokens = $21,
                            bounded_output_tokens = $23,
                            provider_id = $10,
                            provider_account_id = $24,
                            platform_account_id = $25,
                            referral_account_id = $26,
                            provider_payout_micro_usd = $27,
                            platform_fee_micro_usd = $28,
                            referral_reward_micro_usd = $29,
                            input_micro_usd_per_million = $31,
                            output_micro_usd_per_million = $32,
                            provider_share_ppm = $34,
                            referral_share_ppm = $30,
                            api_key_reserved_micro_usd = CASE
                                WHEN job.api_key_reserved_micro_usd > 0 THEN $22
                                ELSE 0
                            END,
                            request_digest = $16,
                            start_authorized_at = NOW(),
                            start_deadline =
                                NOW() + ($36::BIGINT * INTERVAL '1 millisecond'),
                            version = jobs.version + 1,
                            updated_at = NOW()
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
                    CROSS JOIN attempt_insert
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    prepared.job_id.as_uuid(),
                    prepared.expected_version.as_i64(),
                    prepared.expected_state.as_str(),
                    prepared.operation.id.as_uuid(),
                    prepared.operation.key.as_str(),
                    prepared.operation.digest.as_bytes().as_slice(),
                    prepared.attempt_id.as_uuid(),
                    prepared.provider_id,
                    prepared.provider_process_generation_id,
                    prepared.session_epoch.as_i64(),
                    prepared.lease_id,
                    prepared.permit_id,
                    prepared.dispatch_nonce.as_bytes().as_slice(),
                    prepared.request_digest.as_bytes().as_slice(),
                    prepared.concrete_model.as_ref(),
                    prepared.public_model.as_ref(),
                    prepared.pricing_version.as_i64(),
                    prepared.rounding_version.as_i64(),
                    prepared.billable_input_tokens as i64,
                    maximum_charge.as_i64(),
                    prepared.bounded_output_tokens as i64,
                    prepared.provider_account_id.as_str(),
                    prepared.platform_account_id.as_str(),
                    referral_account,
                    prepared.maximum_provider_payout.as_i64(),
                    prepared.maximum_platform_fee.as_i64(),
                    prepared.maximum_referral_reward.as_i64(),
                    i64::from(prepared.referral_share_ppm),
                    prepared.input_micro_usd_per_million.as_i64(),
                    prepared.output_micro_usd_per_million.as_i64(),
                    prepared.attempt_kind.as_str(),
                    i64::from(prepared.provider_share_ppm),
                    prepared.execution_worker_id,
                    i64::try_from(prepared.start_deadline_millis)
                        .expect("validated start deadline fits i64"),
                )
                .fetch_optional(&mut *transaction),
            )
            .await?;
        self.db.bounded(transaction.commit()).await?;
        Ok(row)
    }

    async fn resolve_resize(
        &self,
        authority: &Authority,
        prepared: &PreparedReservation,
        maximum_charge: LedgerAmount,
        ambiguous: bool,
    ) -> Result<ReservationResult, LedgerError> {
        let operation = match self.db.operation(authority, &prepared.operation.key).await {
            Ok(operation) => operation,
            Err(error) if ambiguous => {
                return Err(LedgerError::CommitOutcomeUnknown {
                    operation: prepared.operation.key.clone(),
                    diagnostic: Arc::from(format!(
                        "authorization reconciliation query failed after ambiguous commit: {error}"
                    )),
                });
            }
            Err(error) => return Err(error),
        };
        if let Some(operation) = operation {
            return resize_from_operation(operation, prepared, maximum_charge);
        }
        if ambiguous {
            return Err(LedgerError::CommitOutcomeUnknown {
                operation: prepared.operation.key.clone(),
                diagnostic: "ambiguous authorization commit was not found during reconciliation"
                    .into(),
            });
        }
        let diagnostic = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    ResizeDiagnostic,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        jobs.version = $4
                            AND jobs.state = $5
                            AND jobs.owner_epoch = $2 AS current,
                        balances.balance_micro_usd
                            >= GREATEST(
                                0::BIGINT,
                                $6::BIGINT - jobs.reserved_total_micro_usd
                            ) AS funded,
                        NOT EXISTS (
                            SELECT 1
                            FROM rust_coord.provider_hard_untrust_epochs
                                AS untrusted
                            WHERE untrusted.provider_id = $7
                              AND untrusted.hard_untrust_epoch >= $8
                        ) AS provider_trusted,
                        (
                            jobs.api_key_reserved_micro_usd = 0
                            OR EXISTS (
                                SELECT 1
                                FROM public.api_keys AS keys
                                WHERE keys.id = jobs.api_key_id
                                  AND keys.key_hash = jobs.consumer_key_hash
                                  AND keys.owner_account_id = jobs.account_id
                                  AND keys.active
                                  AND (
                                      keys.expires_at IS NULL
                                      OR keys.expires_at > NOW()
                                  )
                                  AND (
                                      keys.allowed_models IN ('', '[]')
                                      OR EXISTS (
                                          SELECT 1
                                          FROM jsonb_array_elements_text(
                                              keys.allowed_models::JSONB
                                          ) AS allowed(model)
                                          WHERE allowed.model IN ($9, $10)
                                      )
                                  )
                                  AND (
                                      NOT keys.self_route_only
                                      OR EXISTS (
                                          SELECT 1
                                          FROM public.providers AS providers
                                          WHERE providers.id = $7::TEXT
                                            AND providers.account_id =
                                                jobs.account_id
                                            AND providers.connected
                                            AND providers.trust_level = 'hardware'
                                            AND providers.session_epoch = $8
                                      )
                                  )
                            )
                        ) AS api_key_controls_allowed,
                        (
                            jobs.api_key_reserved_micro_usd = 0
                            OR EXISTS (
                                SELECT 1
                                FROM public.api_keys AS keys
                                WHERE keys.id = jobs.api_key_id
                                  AND keys.key_hash = jobs.consumer_key_hash
                                  AND keys.owner_account_id = jobs.account_id
                                  AND (
                                      keys.limit_micro_usd IS NULL
                                      OR (
                                          COALESCE((
                                              SELECT SUM(usage.cost_micro_usd)
                                              FROM public.usage
                                              WHERE usage.key_id = keys.id
                                                AND usage.created_at >=
                                                  CASE keys.limit_reset
                                                    WHEN 'daily'
                                                      THEN date_trunc('day', NOW())
                                                    WHEN 'weekly'
                                                      THEN date_trunc('week', NOW())
                                                    WHEN 'monthly'
                                                      THEN date_trunc('month', NOW())
                                                    ELSE '-infinity'::TIMESTAMPTZ
                                                  END
                                          ), 0)::NUMERIC
                                          + COALESCE((
                                              SELECT SUM(
                                                  controlled_jobs
                                                      .api_key_reserved_micro_usd
                                              )
                                              FROM rust_coord.inference_jobs
                                                  AS controlled_jobs
                                              WHERE controlled_jobs.api_key_id =
                                                    keys.id
                                                AND controlled_jobs.account_id =
                                                    jobs.account_id
                                                AND controlled_jobs.job_id <>
                                                    jobs.job_id
                                                AND controlled_jobs.state NOT IN (
                                                  'settled',
                                                  'released',
                                                  'settled_reviewed',
                                                  'released_reviewed'
                                                )
                                          ), 0)::NUMERIC
                                          + $6::NUMERIC
                                          <= keys.limit_micro_usd::NUMERIC
                                      )
                                  )
                            )
                        ) AS api_key_spend_allowed
                    FROM rust_coord.inference_jobs AS jobs
                    JOIN public.balances AS balances
                      ON balances.account_id = jobs.account_id
                    WHERE jobs.job_id = $3
                      AND EXISTS (SELECT 1 FROM authority)
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    prepared.job_id.as_uuid(),
                    prepared.expected_version.as_i64(),
                    prepared.expected_state.as_str(),
                    maximum_charge.as_i64(),
                    prepared.provider_id,
                    prepared.session_epoch.as_i64(),
                    prepared.concrete_model.as_ref(),
                    prepared.public_model.as_ref(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match diagnostic {
            None => Err(LedgerError::NotFound),
            Some(row) if !row.current => Err(LedgerError::StaleVersion),
            Some(row) if !row.provider_trusted => Err(LedgerError::ProviderHardUntrusted),
            Some(row) if !row.api_key_controls_allowed => Err(LedgerError::ApiKeyControlRejected),
            Some(row) if !row.api_key_spend_allowed => Err(LedgerError::ApiKeySpendLimitExceeded),
            Some(row) if !row.funded => Err(LedgerError::InsufficientBalance),
            Some(_) => Err(LedgerError::OperationConflict),
        }
    }

    async fn resolve_resize_conflict(
        &self,
        authority: &Authority,
        prepared: &PreparedReservation,
        maximum_charge: LedgerAmount,
    ) -> Result<ReservationResult, LedgerError> {
        let Some(operation) = self
            .db
            .operation(authority, &prepared.operation.key)
            .await?
        else {
            return Err(LedgerError::OperationConflict);
        };
        resize_from_operation(operation, prepared, maximum_charge)
    }
}

#[derive(Debug, FromRow)]
struct ResizeRow {
    job_id: uuid::Uuid,
    version: i64,
    state: String,
    reserved_total_micro_usd: i64,
    reserved_withdrawable_micro_usd: i64,
}

#[derive(Debug, FromRow)]
struct ResizeDiagnostic {
    current: bool,
    funded: bool,
    provider_trusted: bool,
    api_key_controls_allowed: bool,
    api_key_spend_allowed: bool,
}

fn resize_from_row(
    row: ResizeRow,
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

fn resize_from_operation(
    operation: OperationRecord,
    prepared: &PreparedReservation,
    maximum_charge: LedgerAmount,
) -> Result<ReservationResult, LedgerError> {
    if operation.operation_key != prepared.operation.key.as_str()
        || operation.digest()? != prepared.operation.digest
        || operation.kind != "resize"
        || operation.status != "applied"
        || operation.job_id != Some(prepared.job_id.as_uuid())
    {
        return Err(LedgerError::OperationConflict);
    }
    let row = ResizeRow {
        job_id: json_uuid(&operation.result, "job_id")?,
        version: json_i64(&operation.result, "version")?,
        state: json_string(&operation.result, "state")?.to_owned(),
        reserved_total_micro_usd: json_i64(&operation.result, "total")?,
        reserved_withdrawable_micro_usd: json_i64(&operation.result, "withdrawable")?,
    };
    let result = resize_from_row(row, MutationDisposition::Replayed)?;
    if result.total != maximum_charge {
        return Err(LedgerError::OperationConflict);
    }
    Ok(result)
}
