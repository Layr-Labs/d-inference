use sqlx::{FromRow, types::Json};

use super::{
    LedgerService,
    reserve::{json_i64, json_uuid},
    types::{
        JobId, LedgerAmount, LedgerError, MutationDisposition, SettleRequest, SettlementResult,
        Version, canonical_json_digest,
    },
};
use crate::db::ownership::{Authority, DurableDatabase, OperationRecord};

impl LedgerService {
    /// Records the provider terminal and applies every settlement side effect
    /// atomically. No externally visible terminal can exist without its charge,
    /// refund, payouts, usage, fee allocations, and projection outbox row.
    pub async fn settle(&self, request: &SettleRequest) -> Result<SettlementResult, LedgerError> {
        request.validate()?;
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.settle_once(&authority, request).await;
            match result {
                Ok(Some(row)) => return settlement_from_row(row, MutationDisposition::Applied),
                Ok(None) => return self.resolve_settle(&authority, request, false).await,
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::may_retry(attempt, source) =>
                {
                    self.db.retry_delay(attempt).await;
                    attempt += 1;
                }
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::is_operation_conflict(source) =>
                {
                    return self.resolve_settle_conflict(&authority, request).await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self.resolve_settle(&authority, request, true).await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn settle_once(
        &self,
        authority: &Authority,
        request: &SettleRequest,
    ) -> Result<Option<SettlementRow>, LedgerError> {
        let error_class = request.terminal.error_class.as_deref();
        let outbox_payload = serde_json::json!({
            "job_id": request.job_id.as_uuid(),
            "settlement_operation_key": request.operation.key.as_str(),
        });
        let outbox_digest = canonical_json_digest(&outbox_payload)?;
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
        let review_resolution_id = request.review.as_ref().map(|review| review.resolution_id);
        let review_reason = request
            .review
            .as_ref()
            .map(|review| review.operator_reason.as_ref());
        self.db
            .bounded(
                sqlx::query_as_unchecked!(
                    SettlementRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    locked AS MATERIALIZED (
                        SELECT
                            jobs.*,
                            attempts.version AS attempt_version,
                            attempts.provider_process_generation_id,
                            attempts.session_epoch,
                            pricing.result AS pricing
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN rust_coord.inference_attempts AS attempts
                          ON attempts.job_id = jobs.job_id
                         AND attempts.attempt_id = $6
                        JOIN rust_coord.financial_operations AS pricing
                          ON pricing.job_id = jobs.job_id
                         AND pricing.kind = 'resize'
                         AND pricing.status = 'applied'
                        CROSS JOIN public.usage_totals AS totals
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.version = $4
                          AND jobs.state = $5
                          AND (
                              $36::UUID IS NOT NULL
                              OR jobs.request_deadline > NOW()
                          )
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
                          AND (
                              $36::UUID IS NOT NULL
                              OR NOT EXISTS (
                                  SELECT 1
                                  FROM rust_coord.provider_hard_untrust_epochs
                                      AS untrusted
                                  WHERE untrusted.provider_id = $8
                                    AND untrusted.hard_untrust_epoch >= $10
                              )
                          )
                          AND jobs.provider_id = $8
                          AND jobs.request_digest = attempts.request_digest
                          AND jobs.consumer_key_hash = $31
                          AND $14::TEXT = 'completed'
                          AND $15::TEXT IS NULL
                          AND jobs.billable_input_tokens = $16
                          AND $17::BIGINT <= jobs.bounded_output_tokens
                          AND $17::BIGINT <= $38::BIGINT
                          AND $18::BIGINT <= $17::BIGINT
                          AND $22::BIGINT = $17::BIGINT
                          AND $38::BIGINT <= jobs.bounded_output_tokens
                          AND (
                              $34::UUID IS NULL
                              OR $38::BIGINT
                                 <= jobs.accepted_cumulative_tokens
                          )
                          AND $27::BIGINT <= jobs.reserved_total_micro_usd
                          AND $28::BIGINT <= jobs.provider_payout_micro_usd
                          AND $29::BIGINT <= jobs.platform_fee_micro_usd
                          AND $30::BIGINT
                              <= COALESCE(jobs.referral_reward_micro_usd, 0)
                          AND $27::BIGINT = (
                              CEIL(
                                  $16::NUMERIC
                                  * (pricing.result->>'input_rate')::NUMERIC
                                  / 1000000
                              )
                              + CEIL(
                                  $17::NUMERIC
                                  * (pricing.result->>'output_rate')::NUMERIC
                                  / 1000000
                              )
                          )
                          AND $27::NUMERIC = (
                              $28::NUMERIC + $29::NUMERIC + $30::NUMERIC
                          )
                          AND $28::NUMERIC = FLOOR(
                              $27::NUMERIC
                              * jobs.provider_share_ppm::NUMERIC
                              / 1000000
                          )
                          AND $29::NUMERIC = (
                              $27::NUMERIC - $28::NUMERIC - $30::NUMERIC
                          )
                          AND $30::NUMERIC = FLOOR(
                              ($29::NUMERIC + $30::NUMERIC)
                              * COALESCE(jobs.referral_share_ppm, 0)::NUMERIC
                              / 1000000
                          )
                          AND totals.id = 1
                          AND totals.total_requests >= 0
                          AND totals.total_prompt_tokens >= 0
                          AND totals.total_completion_tokens >= 0
                          AND totals.total_requests
                              < 9223372036854775807::BIGINT
                          AND totals.total_prompt_tokens
                              <= 9223372036854775807::BIGINT - $16::BIGINT
                          AND totals.total_completion_tokens
                              <= 9223372036854775807::BIGINT - $17::BIGINT
                        FOR UPDATE OF jobs, attempts, totals
                    ),
                    gate AS MATERIALIZED (
                        SELECT
                            locked.*,
                            locked.reserved_total_micro_usd - $27::BIGINT
                                AS refund_total,
                            LEAST(
                                locked.reserved_total_micro_usd - $27::BIGINT,
                                locked.reserved_withdrawable_micro_usd
                            ) AS refund_withdrawable
                        FROM authority
                        CROSS JOIN locked
                        WHERE jsonb_typeof($13::JSONB) = 'object'
                          AND octet_length($20::BYTEA) > 0
                          AND (
                              (
                                  $36::UUID IS NULL
                                  AND $37::TEXT IS NULL
                                  AND locked.state <> 'review_pending'
                              )
                              OR (
                                  $36::UUID IS NOT NULL
                                  AND $37::TEXT IS NOT NULL
                                  AND $37::TEXT <> ''
                                  AND locked.state = 'review_pending'
                              )
                          )
                    ),
                    credit_components AS MATERIALIZED (
                        SELECT
                            gate.account_id,
                            gate.refund_total AS total,
                            gate.refund_withdrawable AS withdrawable
                        FROM gate
                        WHERE gate.refund_total > 0
                        UNION ALL
                        SELECT gate.provider_account_id, $28, $28
                        FROM gate
                        WHERE $28::BIGINT > 0
                        UNION ALL
                        SELECT gate.platform_account_id, $29, 0
                        FROM gate
                        WHERE $29::BIGINT > 0
                        UNION ALL
                        SELECT gate.referral_account_id, $30, $30
                        FROM gate
                        WHERE $30::BIGINT > 0
                    ),
                    credits AS MATERIALIZED (
                        SELECT
                            account_id,
                            SUM(total)::BIGINT AS total,
                            SUM(withdrawable)::BIGINT AS withdrawable
                        FROM credit_components
                        WHERE account_id IS NOT NULL
                        GROUP BY account_id
                    ),
                    credit_accounts AS MATERIALIZED (
                        SELECT
                            balances.account_id,
                            balances.balance_micro_usd,
                            balances.withdrawable_micro_usd,
                            credits.total,
                            credits.withdrawable
                        FROM public.balances AS balances
                        JOIN credits USING (account_id)
                        ORDER BY balances.account_id
                        FOR UPDATE OF balances
                    ),
                    credit_gate AS MATERIALIZED (
                        SELECT gate.*
                        FROM gate
                        WHERE
                            (SELECT COUNT(*) FROM credit_accounts)
                            = (SELECT COUNT(*) FROM credits)
                          AND NOT EXISTS (
                              SELECT 1
                              FROM credit_accounts
                              WHERE balance_micro_usd < 0
                                 OR withdrawable_micro_usd < 0
                                 OR withdrawable_micro_usd
                                    > balance_micro_usd
                                 OR balance_micro_usd
                                    > 9223372036854775807::BIGINT - total
                                 OR withdrawable_micro_usd
                                    > 9223372036854775807::BIGINT
                                      - withdrawable
                          )
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
                            $11,
                            credit_gate.job_id,
                            $6,
                            $8,
                            $9,
                            $10,
                            $12,
                            $13,
                            $14,
                            $15,
                            $16,
                            $17,
                            $18,
                            $19,
                            $21,
                            $22,
                            $20,
                            CASE
                                WHEN $36::UUID IS NULL THEN 'settled'
                                ELSE 'settled_reviewed'
                            END,
                            $2,
                            NOW()
                        FROM credit_gate
                        ON CONFLICT (terminal_id) DO UPDATE SET
                            status = CASE
                                WHEN $36::UUID IS NULL THEN 'settled'
                                ELSE 'settled_reviewed'
                            END,
                            owner_epoch = $2,
                            version = terminals.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW(),
                            disposition_at = NOW()
                        WHERE (
                                terminals.status = 'pending'
                                OR (
                                    $36::UUID IS NOT NULL
                                    AND terminals.status IN ('conflict', 'rejected')
                                )
                              )
                          AND terminals.job_id = EXCLUDED.job_id
                          AND terminals.attempt_id = EXCLUDED.attempt_id
                          AND terminals.provider_id = EXCLUDED.provider_id
                          AND terminals.provider_process_generation_id
                              = EXCLUDED.provider_process_generation_id
                          AND terminals.origin_session_epoch
                              = EXCLUDED.origin_session_epoch
                          AND terminals.terminal_digest
                              = EXCLUDED.terminal_digest
                          AND terminals.raw_terminal = EXCLUDED.raw_terminal
                          AND terminals.outcome = EXCLUDED.outcome
                          AND terminals.error_class
                              IS NOT DISTINCT FROM EXCLUDED.error_class
                          AND terminals.prompt_tokens = EXCLUDED.prompt_tokens
                          AND terminals.completion_tokens
                              = EXCLUDED.completion_tokens
                          AND terminals.reasoning_tokens
                              = EXCLUDED.reasoning_tokens
                          AND terminals.response_digest
                              = EXCLUDED.response_digest
                          AND terminals.rolling_digest
                              = EXCLUDED.rolling_digest
                          AND terminals.final_generated_tokens
                              = EXCLUDED.final_generated_tokens
                          AND terminals.provider_signature
                              = EXCLUDED.provider_signature
                          AND (
                              (
                                  $34::UUID IS NULL
                                  AND $35::BIGINT IS NULL
                                  AND terminals.worker_owner IS NULL
                              )
                              OR (
                                  terminals.worker_owner = $34
                                  AND terminals.version = $35
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
                            counterparty_account_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd,
                            result,
                            owner_epoch,
                            version,
                            completed_at
                        )
                        SELECT
                            $23,
                            $24,
                            $25,
                            'settle',
                            'applied',
                            credit_gate.job_id,
                            terminal_insert.terminal_id,
                            credit_gate.account_id,
                            credit_gate.provider_account_id,
                            $27,
                            credit_gate.reserved_withdrawable_micro_usd
                                - credit_gate.refund_withdrawable,
                            jsonb_build_object(
                                'job_id', credit_gate.job_id,
                                'version', $4::BIGINT + 1,
                                'state', CASE
                                    WHEN $36::UUID IS NULL THEN 'settled'
                                    ELSE 'settled_reviewed'
                                END,
                                'charged', $27::BIGINT,
                                'charged_withdrawable',
                                    credit_gate.reserved_withdrawable_micro_usd
                                    - credit_gate.refund_withdrawable,
                                'refunded', credit_gate.refund_total,
                                'refunded_withdrawable',
                                    credit_gate.refund_withdrawable
                            ),
                            $2,
                            2,
                            NOW()
                        FROM credit_gate
                        CROSS JOIN terminal_insert
                        RETURNING operation_id
                    ),
                    balance_update AS (
                        INSERT INTO public.balances (
                            account_id,
                            balance_micro_usd,
                            withdrawable_micro_usd,
                            updated_at
                        )
                        SELECT
                            credits.account_id,
                            credits.total,
                            credits.withdrawable,
                            NOW()
                        FROM credits
                        CROSS JOIN operation_insert
                        ORDER BY credits.account_id
                        ON CONFLICT (account_id) DO UPDATE SET
                            balance_micro_usd =
                                balances.balance_micro_usd
                                + EXCLUDED.balance_micro_usd,
                            withdrawable_micro_usd =
                                balances.withdrawable_micro_usd
                                + EXCLUDED.withdrawable_micro_usd,
                            updated_at = NOW()
                        WHERE balances.balance_micro_usd >= 0
                          AND balances.withdrawable_micro_usd >= 0
                          AND balances.withdrawable_micro_usd
                              <= balances.balance_micro_usd
                          AND balances.balance_micro_usd
                              <= 9223372036854775807::BIGINT
                                 - EXCLUDED.balance_micro_usd
                          AND balances.withdrawable_micro_usd
                              <= 9223372036854775807::BIGINT
                                 - EXCLUDED.withdrawable_micro_usd
                        RETURNING account_id, balance_micro_usd
                    ),
                    balanced AS MATERIALIZED (
                        SELECT 1
                        FROM operation_insert
                        WHERE
                            (SELECT COUNT(*) FROM credits)
                            = (SELECT COUNT(*) FROM balance_update)
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
                            balance_update.account_id,
                            'rust_settlement',
                            credits.total,
                            balance_update.balance_micro_usd,
                            'rust-settle:' || $24
                        FROM balance_update
                        JOIN credits USING (account_id)
                        CROSS JOIN balanced
                        RETURNING id
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = CASE
                                WHEN $36::UUID IS NULL THEN 'settled'
                                ELSE 'settled_reviewed'
                            END,
                            outcome = $14,
                            error_class = $15,
                            usage_prompt_tokens = $16,
                            usage_completion_tokens = $17,
                            usage_reasoning_tokens = $18,
                            accepted_cumulative_tokens = GREATEST(
                                jobs.accepted_cumulative_tokens,
                                $38::BIGINT
                            ),
                            response_digest = $19,
                            provider_payout_micro_usd = $28,
                            platform_fee_micro_usd = $29,
                            referral_reward_micro_usd = $30,
                            version = jobs.version + 1,
                            updated_at = NOW(),
                            terminal_at = NOW(),
                            worker_owner = NULL,
                            lease_until = NULL
                        FROM gate, balanced
                        WHERE jobs.job_id = gate.job_id
                          AND jobs.version = $4
                          AND jobs.state = $5
                        RETURNING
                            jobs.job_id,
                            jobs.version,
                            gate.refund_total
                    ),
                    review_journal AS (
                        INSERT INTO rust_coord.review_resolution_journal (
                            resolution_id,
                            job_id,
                            disposition,
                            operator_reason,
                            owner_epoch
                        )
                        SELECT
                            $36,
                            job_update.job_id,
                            'settled_reviewed',
                            $37,
                            $2
                        FROM job_update
                        WHERE $36::UUID IS NOT NULL
                        ON CONFLICT (job_id) DO NOTHING
                        RETURNING job_id
                    ),
                    review_gate AS MATERIALIZED (
                        SELECT job_update.*
                        FROM job_update
                        WHERE $36::UUID IS NULL
                           OR EXISTS (
                               SELECT 1
                               FROM review_journal
                               WHERE review_journal.job_id = job_update.job_id
                           )
                    ),
                    attempt_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            state = 'terminal_recorded',
                            version = attempts.version + 1,
                            updated_at = NOW(),
                            worker_owner = NULL,
                            lease_until = NULL
                        FROM review_gate
                        WHERE attempts.attempt_id = $6
                          AND attempts.version = $7
                          AND attempts.state IN (
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                        RETURNING attempts.attempt_id
                    ),
                    usage_insert AS (
                        INSERT INTO public.usage (
                            provider_id,
                            consumer_key_hash,
                            key_id,
                            model,
                            public_model,
                            prompt_tokens,
                            completion_tokens,
                            request_id,
                            cost_micro_usd
                        )
                        SELECT
                            $8::TEXT,
                            $31,
                            gate.api_key_id,
                            gate.concrete_model,
                            gate.public_model,
                            $16::INTEGER,
                            $17::INTEGER,
                            gate.request_id::TEXT,
                            $27
                        FROM gate
                        CROSS JOIN attempt_update
                        RETURNING id
                    ),
                    usage_totals_update AS (
                        UPDATE public.usage_totals
                        SET
                            total_requests = total_requests + 1,
                            total_prompt_tokens = total_prompt_tokens + $16,
                            total_completion_tokens =
                                total_completion_tokens + $17
                        FROM usage_insert
                        WHERE usage_totals.id = 1
                        RETURNING usage_totals.id
                    ),
                    provider_earning AS (
                        INSERT INTO public.provider_earnings (
                            account_id,
                            provider_id,
                            provider_key,
                            job_id,
                            model,
                            amount_micro_usd,
                            prompt_tokens,
                            completion_tokens
                        )
                        SELECT
                            gate.provider_account_id,
                            $8::TEXT,
                            $8::TEXT,
                            gate.job_id::TEXT,
                            gate.concrete_model,
                            $28,
                            $16::INTEGER,
                            $17::INTEGER
                        FROM gate
                        CROSS JOIN usage_totals_update
                        WHERE $28::BIGINT > 0
                        RETURNING id
                    ),
                    fee_allocations_insert AS (
                        INSERT INTO rust_coord.fee_allocations (
                            allocation_id,
                            operation_key,
                            job_id,
                            financial_operation_id,
                            kind,
                            source_account_id,
                            beneficiary_account_id,
                            amount_micro_usd,
                            owner_epoch
                        )
                        SELECT
                            gen_random_uuid(),
                            $24 || ':platform',
                            gate.job_id,
                            operation_insert.operation_id,
                            'platform',
                            gate.account_id,
                            gate.platform_account_id,
                            $29,
                            $2
                        FROM gate, operation_insert
                        WHERE $29::BIGINT > 0
                        UNION ALL
                        SELECT
                            gen_random_uuid(),
                            $24 || ':referral',
                            gate.job_id,
                            operation_insert.operation_id,
                            'referral',
                            gate.account_id,
                            gate.referral_account_id,
                            $30,
                            $2
                        FROM gate, operation_insert
                        WHERE $30::BIGINT > 0
                        RETURNING allocation_id
                    ),
                    checkpoint_seed AS (
                        INSERT INTO rust_coord.fee_projection_checkpoints (
                            projection_name,
                            owner_epoch
                        )
                        SELECT 'legacy-fees', $2
                        FROM operation_insert
                        ON CONFLICT (projection_name) DO NOTHING
                        RETURNING projection_name
                    ),
                    outbox_insert AS (
                        INSERT INTO rust_coord.outbox (
                            outbox_id,
                            operation_key,
                            payload_digest,
                            kind,
                            status,
                            job_id,
                            financial_operation_id,
                            payload,
                            owner_epoch
                        )
                        SELECT
                            $26,
                            'fee-project:' || $24,
                            $32,
                            'fee_projection',
                            'pending',
                            gate.job_id,
                            operation_insert.operation_id,
                            $33,
                            $2
                        FROM gate, operation_insert, review_gate, attempt_update,
                             usage_insert, usage_totals_update
                        RETURNING outbox_id
                    )
                    SELECT
                        review_gate.job_id,
                        review_gate.version,
                        $27::BIGINT AS charged,
                        credit_gate.reserved_withdrawable_micro_usd
                            - credit_gate.refund_withdrawable
                            AS charged_withdrawable,
                        review_gate.refund_total AS refunded,
                        credit_gate.refund_withdrawable
                            AS refunded_withdrawable
                    FROM review_gate
                    CROSS JOIN operation_insert
                    CROSS JOIN outbox_insert
                    CROSS JOIN credit_gate
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.job_id.as_uuid(),
                    request.expected_job_version.as_i64(),
                    request.expected_job_state.as_str(),
                    request.terminal.attempt_id.as_uuid(),
                    request.expected_attempt_version.as_i64(),
                    request.terminal.provider_id,
                    request.terminal.provider_process_generation_id,
                    request.terminal.origin_session_epoch.as_i64(),
                    request.terminal.terminal_id.as_uuid(),
                    request.terminal.terminal_digest.as_bytes().as_slice(),
                    Json(&request.terminal.raw_terminal),
                    request.terminal.outcome.as_str(),
                    error_class,
                    request.terminal.prompt_tokens as i64,
                    request.terminal.completion_tokens as i64,
                    request.terminal.reasoning_tokens as i64,
                    request.terminal.response_digest.as_bytes().as_slice(),
                    request.terminal.provider_signature.as_slice(),
                    request.terminal.rolling_digest.as_bytes().as_slice(),
                    request.terminal.final_generated_tokens as i64,
                    request.operation.id.as_uuid(),
                    request.operation.key.as_str(),
                    request.operation.digest.as_bytes().as_slice(),
                    uuid::Uuid::new_v4(),
                    request.consumer_charge.as_i64(),
                    request.provider_payout.as_i64(),
                    request.platform_fee.as_i64(),
                    request.referral_reward.as_i64(),
                    request.consumer_key_hash.as_ref(),
                    outbox_digest.as_bytes().as_slice(),
                    Json(&outbox_payload),
                    recovery_worker,
                    recovery_version,
                    review_resolution_id,
                    review_reason,
                    i64::try_from(request.accepted_cumulative_tokens)
                        .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?,
                )
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    async fn resolve_settle(
        &self,
        authority: &Authority,
        request: &SettleRequest,
        ambiguous: bool,
    ) -> Result<SettlementResult, LedgerError> {
        if let Some(operation) = self.db.operation(authority, &request.operation.key).await? {
            return settlement_from_operation(operation, request);
        }
        if ambiguous {
            return Err(LedgerError::CommitOutcomeUnknown {
                operation: request.operation.key.clone(),
                diagnostic: "ambiguous settlement commit was not found during reconciliation"
                    .into(),
            });
        }
        let diagnostic = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    SettleDiagnostic,
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
                        ) AS "current!",
                        (
                            $8::UUID IS NOT NULL
                            OR NOT EXISTS (
                                SELECT 1
                                FROM rust_coord.provider_hard_untrust_epochs
                                    AS untrusted
                                WHERE untrusted.provider_id = $6
                                  AND untrusted.hard_untrust_epoch >= $7
                            )
                        ) AS "provider_trusted!"
                    FROM authority
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.job_id.as_uuid(),
                    request.expected_job_version.as_i64(),
                    request.expected_job_state.as_str(),
                    request.terminal.provider_id,
                    request.terminal.origin_session_epoch.as_i64(),
                    request.review.as_ref().map(|review| review.resolution_id),
                )
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

    async fn resolve_settle_conflict(
        &self,
        authority: &Authority,
        request: &SettleRequest,
    ) -> Result<SettlementResult, LedgerError> {
        let Some(operation) = self.db.operation(authority, &request.operation.key).await? else {
            return Err(LedgerError::OperationConflict);
        };
        settlement_from_operation(operation, request)
    }
}

#[derive(Debug, FromRow)]
struct SettleDiagnostic {
    current: bool,
    provider_trusted: bool,
}

#[derive(Debug, FromRow)]
struct SettlementRow {
    job_id: uuid::Uuid,
    version: i64,
    charged: i64,
    charged_withdrawable: i64,
    refunded: i64,
    refunded_withdrawable: i64,
}

fn settlement_from_row(
    row: SettlementRow,
    disposition: MutationDisposition,
) -> Result<SettlementResult, LedgerError> {
    Ok(SettlementResult {
        disposition,
        job_id: JobId::new(row.job_id)
            .map_err(|_| LedgerError::CorruptData("stored job id is nil"))?,
        version: Version::from_database(row.version)?,
        charged: LedgerAmount::from_i64(row.charged).map_err(LedgerError::Invalid)?,
        charged_withdrawable: LedgerAmount::from_i64(row.charged_withdrawable)
            .map_err(LedgerError::Invalid)?,
        refunded: LedgerAmount::from_i64(row.refunded).map_err(LedgerError::Invalid)?,
        refunded_withdrawable: LedgerAmount::from_i64(row.refunded_withdrawable)
            .map_err(LedgerError::Invalid)?,
    })
}

fn settlement_from_operation(
    operation: OperationRecord,
    request: &SettleRequest,
) -> Result<SettlementResult, LedgerError> {
    if operation.operation_key != request.operation.key.as_str()
        || operation.digest()? != request.operation.digest
        || operation.kind != "settle"
        || operation.status != "applied"
        || operation.job_id != Some(request.job_id.as_uuid())
        || operation.terminal_id != Some(request.terminal.terminal_id.as_uuid())
        || operation.amount_total_micro_usd != request.consumer_charge.as_i64()
    {
        return Err(LedgerError::OperationConflict);
    }
    let row = SettlementRow {
        job_id: json_uuid(&operation.result, "job_id")?,
        version: json_i64(&operation.result, "version")?,
        charged: json_i64(&operation.result, "charged")?,
        charged_withdrawable: json_i64(&operation.result, "charged_withdrawable")?,
        refunded: json_i64(&operation.result, "refunded")?,
        refunded_withdrawable: json_i64(&operation.result, "refunded_withdrawable")?,
    };
    let result = settlement_from_row(row, MutationDisposition::Replayed)?;
    if result.charged != request.consumer_charge
        || operation.amount_withdrawable_micro_usd != result.charged_withdrawable.as_i64()
    {
        return Err(LedgerError::OperationConflict);
    }
    Ok(result)
}
