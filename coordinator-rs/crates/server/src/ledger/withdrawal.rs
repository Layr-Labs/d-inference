use sqlx::{FromRow, types::Json};

use super::{
    LedgerService,
    reserve::json_string,
    types::{
        LedgerError, MutationDisposition, WithdrawalDisposition, WithdrawalId, WithdrawalRequest,
        WithdrawalResult, WithdrawalStatus, WithdrawalTransition, canonical_json_digest,
    },
};
use crate::db::ownership::{Authority, DurableDatabase, OperationRecord};

impl LedgerService {
    /// Debits withdrawable provenance and creates the external-call outbox row.
    pub async fn create_withdrawal(
        &self,
        request: &WithdrawalRequest,
    ) -> Result<WithdrawalResult, LedgerError> {
        let net = request.net()?;
        if request.amount.as_i64() == 0 || request.method.is_empty() {
            return Err(crate::ledger::types::InputError::Empty("withdrawal field").into());
        }
        if !request.external_payload.is_object() {
            return Err(crate::ledger::types::InputError::TerminalPayloadNotObject.into());
        }
        let payload_digest = canonical_json_digest(&request.external_payload)?;
        if payload_digest != request.payload_digest {
            return Err(LedgerError::OperationConflict);
        }
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self
                .create_withdrawal_once(&authority, request, net, payload_digest)
                .await;
            match result {
                Ok(Some(row)) => return withdrawal_from_row(row, false),
                Ok(None) => {
                    return self
                        .resolve_create_withdrawal(&authority, request, payload_digest, false)
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
                        .resolve_create_withdrawal(&authority, request, payload_digest, false)
                        .await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self
                        .resolve_create_withdrawal(&authority, request, payload_digest, true)
                        .await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn create_withdrawal_once(
        &self,
        authority: &Authority,
        request: &WithdrawalRequest,
        net: crate::ledger::types::LedgerAmount,
        payload_digest: darkbloom_coordinator_core::ids::Digest,
    ) -> Result<Option<WithdrawalRow>, LedgerError> {
        self.db
            .bounded(
                sqlx::query_as_unchecked!(
                    WithdrawalRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    account AS MATERIALIZED (
                        SELECT balances.*
                        FROM public.balances AS balances
                        WHERE balances.account_id = $3
                          AND balances.balance_micro_usd >= $4
                          AND balances.withdrawable_micro_usd >= $4
                          AND balances.withdrawable_micro_usd
                              <= balances.balance_micro_usd
                        FOR UPDATE
                    ),
                    gate AS MATERIALIZED (
                        SELECT account.*
                        FROM authority
                        CROSS JOIN account
                        WHERE jsonb_typeof($13::JSONB) = 'object'
                    ),
                    withdrawal_insert AS (
                        INSERT INTO public.stripe_withdrawals (
                            id,
                            account_id,
                            stripe_account_id,
                            amount_micro_usd,
                            fee_micro_usd,
                            net_micro_usd,
                            method,
                            status
                        )
                        SELECT
                            $5,
                            gate.account_id,
                            $6,
                            $4,
                            $7,
                            $8,
                            $9,
                            'pending'
                        FROM gate
                        ON CONFLICT DO NOTHING
                        RETURNING id, account_id
                    ),
                    operation_insert AS (
                        INSERT INTO rust_coord.financial_operations (
                            operation_id,
                            operation_key,
                            operation_digest,
                            kind,
                            status,
                            account_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd,
                            result,
                            owner_epoch,
                            version,
                            completed_at
                        )
                        SELECT
                            $10,
                            $11,
                            $12,
                            'withdrawal_intent',
                            'applied',
                            withdrawal_insert.account_id,
                            $4,
                            $4,
                            jsonb_build_object(
                                'withdrawal_id', $5,
                                'status', 'pending',
                                'refunded', FALSE,
                                'manual_review', FALSE
                            ),
                            $2,
                            2,
                            NOW()
                        FROM withdrawal_insert
                        RETURNING operation_id
                    ),
                    balance_update AS (
                        UPDATE public.balances AS balances
                        SET
                            balance_micro_usd = balances.balance_micro_usd - $4,
                            withdrawable_micro_usd =
                                balances.withdrawable_micro_usd - $4,
                            updated_at = NOW()
                        FROM withdrawal_insert, operation_insert
                        WHERE balances.account_id = withdrawal_insert.account_id
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
                            withdrawal_insert.account_id,
                            'stripe_payout',
                            -$4::BIGINT,
                            balance_update.balance_micro_usd,
                            'stripe_withdraw:' || $5
                        FROM withdrawal_insert, balance_update
                        RETURNING id
                    ),
                    outbox_insert AS (
                        INSERT INTO rust_coord.outbox (
                            outbox_id,
                            operation_key,
                            payload_digest,
                            kind,
                            status,
                            financial_operation_id,
                            payload,
                            owner_epoch
                        )
                        SELECT
                            $14,
                            'withdrawal-call:' || $5,
                            $15,
                            'external_call',
                            'pending',
                            operation_insert.operation_id,
                            $13,
                            $2
                        FROM operation_insert, ledger_insert
                        RETURNING outbox_id
                    )
                    SELECT
                        $5::TEXT AS withdrawal_id,
                        'pending'::TEXT AS status,
                        FALSE AS refunded,
                        FALSE AS manual_review
                    FROM operation_insert
                    CROSS JOIN outbox_insert
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.account_id.as_str(),
                    request.amount.as_i64(),
                    request.withdrawal_id.as_str(),
                    request.stripe_account_id.as_str(),
                    request.fee.as_i64(),
                    net.as_i64(),
                    request.method.as_ref(),
                    request.operation.id.as_uuid(),
                    request.operation.key.as_str(),
                    request.operation.digest.as_bytes().as_slice(),
                    Json(&request.external_payload),
                    request.outbox_id.as_uuid(),
                    payload_digest.as_bytes().as_slice(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    /// Applies an exact external status transition.
    pub async fn mark_withdrawal(
        &self,
        transition: &WithdrawalTransition,
        target: WithdrawalStatus,
    ) -> Result<WithdrawalResult, LedgerError> {
        if !matches!(
            (transition.expected_status, target),
            (WithdrawalStatus::Pending, WithdrawalStatus::Transferred)
                | (WithdrawalStatus::Pending, WithdrawalStatus::Paid)
                | (WithdrawalStatus::Transferred, WithdrawalStatus::Paid)
        ) {
            return Err(LedgerError::OperationConflict);
        }
        if target == WithdrawalStatus::Transferred && transition.transfer_id.is_none() {
            return Err(crate::ledger::types::InputError::Empty("transfer id").into());
        }
        if target == WithdrawalStatus::Paid
            && transition.payout_id.is_none()
            && transition.sweep_payout_id.is_none()
        {
            return Err(crate::ledger::types::InputError::Empty("payout id").into());
        }
        self.transition_withdrawal(transition, target).await
    }

    /// Marks a sweep-paid withdrawal using the exact expected state.
    pub async fn mark_sweep_paid(
        &self,
        transition: &WithdrawalTransition,
    ) -> Result<WithdrawalResult, LedgerError> {
        if !matches!(
            transition.expected_status,
            WithdrawalStatus::Pending | WithdrawalStatus::Transferred
        ) {
            return Err(LedgerError::StaleVersion);
        }
        if transition.sweep_payout_id.is_none() {
            return Err(crate::ledger::types::InputError::Empty("sweep payout id").into());
        }
        self.transition_withdrawal(transition, WithdrawalStatus::Paid)
            .await
    }

    /// Reopens only the exact paid sweep instance after an external failure.
    pub async fn reopen_failed_sweep(
        &self,
        transition: &WithdrawalTransition,
    ) -> Result<WithdrawalResult, LedgerError> {
        if transition.expected_status != WithdrawalStatus::Paid
            || transition.sweep_payout_id.is_none()
            || transition.failure_reason.is_none()
        {
            return Err(LedgerError::OperationConflict);
        }
        self.transition_withdrawal(transition, WithdrawalStatus::Transferred)
            .await
    }

    async fn transition_withdrawal(
        &self,
        transition: &WithdrawalTransition,
        target: WithdrawalStatus,
    ) -> Result<WithdrawalResult, LedgerError> {
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.transition_once(&authority, transition, target).await;
            match result {
                Ok(Some(row)) => return withdrawal_from_row(row, false),
                Ok(None) => {
                    if transition.expected_status == WithdrawalStatus::Paid
                        && target == WithdrawalStatus::Transferred
                        && transition.sweep_payout_id.is_some()
                    {
                        return self
                            .resolve_failed_sweep_tombstone(&authority, transition)
                            .await;
                    }
                    return self
                        .resolve_withdrawal(
                            &authority,
                            &transition.operation,
                            &transition.withdrawal_id,
                            false,
                        )
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
                        .resolve_withdrawal_conflict(
                            &authority,
                            &transition.operation,
                            &transition.withdrawal_id,
                        )
                        .await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self
                        .resolve_withdrawal(
                            &authority,
                            &transition.operation,
                            &transition.withdrawal_id,
                            true,
                        )
                        .await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn resolve_failed_sweep_tombstone(
        &self,
        authority: &Authority,
        transition: &WithdrawalTransition,
    ) -> Result<WithdrawalResult, LedgerError> {
        let sweep_id = transition
            .sweep_payout_id
            .as_ref()
            .ok_or(crate::ledger::types::InputError::Empty("sweep payout id"))?;
        let row = self
            .db
            .bounded(
                sqlx::query_as::<_, WithdrawalRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        withdrawals.id AS withdrawal_id,
                        withdrawals.status,
                        withdrawals.refunded,
                        withdrawals.status = 'review_pending' AS manual_review
                    FROM public.stripe_withdrawals AS withdrawals
                    WHERE withdrawals.id = $3
                      AND EXISTS (
                          SELECT 1
                          FROM public.stripe_sweep_failures AS failures
                          WHERE failures.payout_id = $4
                      )
                      AND EXISTS (SELECT 1 FROM authority)
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(transition.withdrawal_id.as_str())
                .bind(sweep_id.as_str())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match row {
            Some(row) => withdrawal_from_row(row, true),
            None => {
                self.db.verify_authority(authority).await?;
                Err(LedgerError::StaleVersion)
            }
        }
    }

    async fn transition_once(
        &self,
        authority: &Authority,
        transition: &WithdrawalTransition,
        target: WithdrawalStatus,
    ) -> Result<Option<WithdrawalRow>, LedgerError> {
        let transfer_id = transition
            .transfer_id
            .as_ref()
            .map_or("", |value| value.as_str());
        let payout_id = transition
            .payout_id
            .as_ref()
            .map_or("", |value| value.as_str());
        let sweep_id = transition
            .sweep_payout_id
            .as_ref()
            .map_or("", |value| value.as_str());
        let failure = transition.failure_reason.as_deref().unwrap_or("");
        let serialization_key = if sweep_id.is_empty() {
            format!("stripe-withdrawal:{}", transition.withdrawal_id.as_str())
        } else {
            format!("stripe-sweep:{sweep_id}")
        };
        let mut transaction = self.db.bounded(self.db.pool().begin()).await?;
        self.db
            .bounded(
                sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
                    .bind(serialization_key)
                    .execute(&mut *transaction),
            )
            .await?;
        let row = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    WithdrawalRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    failure_tombstone AS (
                        INSERT INTO public.stripe_sweep_failures (
                            payout_id,
                            failure_reason
                        )
                        SELECT $8, $9
                        FROM authority
                        WHERE $4 = 'paid'
                          AND $5 = 'transferred'
                          AND $8 <> ''
                          AND $9 <> ''
                        ON CONFLICT (payout_id) DO UPDATE SET
                            failure_reason = EXCLUDED.failure_reason
                        RETURNING payout_id
                    ),
                    withdrawal_update AS (
                        UPDATE public.stripe_withdrawals AS withdrawals
                        SET
                            status = $5,
                            transfer_id = CASE
                                WHEN $6 <> '' THEN $6 ELSE withdrawals.transfer_id
                            END,
                            payout_id = CASE
                                WHEN $7 <> '' THEN $7 ELSE withdrawals.payout_id
                            END,
                            sweep_payout_id = CASE
                                WHEN $5 = 'transferred' AND $4 = 'paid'
                                THEN withdrawals.sweep_payout_id
                                WHEN $5 = 'transferred' THEN ''
                                WHEN $8 <> '' THEN $8
                                ELSE withdrawals.sweep_payout_id
                            END,
                            failure_reason = CASE
                                WHEN $9 <> '' THEN $9 ELSE withdrawals.failure_reason
                            END,
                            updated_at = NOW()
                        FROM authority
                        LEFT JOIN (
                            SELECT COUNT(*) AS recorded
                            FROM failure_tombstone
                        ) AS failure_record ON TRUE
                        WHERE withdrawals.id = $3
                          AND withdrawals.status = $4
                          AND withdrawals.refunded = FALSE
                          AND (
                              $6 = ''
                              OR withdrawals.transfer_id = ''
                              OR withdrawals.transfer_id = $6
                          )
                          AND (
                              $7 = ''
                              OR withdrawals.payout_id = ''
                              OR withdrawals.payout_id = $7
                          )
                          AND (
                              $8 = ''
                              OR $4 <> 'paid'
                              OR withdrawals.sweep_payout_id = $8
                          )
                          AND (
                              $5 <> 'paid'
                              OR $8 = ''
                              OR withdrawals.sweep_payout_id <> $8
                          )
                          AND (
                              $5 <> 'paid'
                              OR $8 = ''
                              OR NOT EXISTS (
                                  SELECT 1
                                  FROM public.stripe_sweep_failures AS failures
                                  WHERE failures.payout_id = $8
                              )
                          )
                        RETURNING withdrawals.id, withdrawals.account_id
                    ),
                    operation_insert AS (
                        INSERT INTO rust_coord.financial_operations (
                            operation_id,
                            operation_key,
                            operation_digest,
                            kind,
                            status,
                            account_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd,
                            result,
                            owner_epoch,
                            version,
                            completed_at
                        )
                        SELECT
                            $10,
                            $11,
                            $12,
                            'withdrawal_complete',
                            'applied',
                            withdrawal_update.account_id,
                            0,
                            0,
                            jsonb_build_object(
                                'withdrawal_id', $3,
                                'status', $5,
                                'refunded', FALSE,
                                'manual_review', ($5 = 'review_pending')
                            ),
                            $2,
                            2,
                            NOW()
                        FROM withdrawal_update
                        RETURNING operation_id
                    )
                    SELECT
                        $3::TEXT AS withdrawal_id,
                        $5::TEXT AS status,
                        FALSE AS refunded,
                        ($5 = 'review_pending') AS manual_review
                    FROM operation_insert
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    transition.withdrawal_id.as_str(),
                    transition.expected_status.as_str(),
                    target.as_str(),
                    transfer_id,
                    payout_id,
                    sweep_id,
                    failure,
                    transition.operation.id.as_uuid(),
                    transition.operation.key.as_str(),
                    transition.operation.digest.as_bytes().as_slice(),
                )
                .fetch_optional(&mut *transaction),
            )
            .await?;
        self.db.bounded(transaction.commit()).await?;
        Ok(row)
    }

    /// Handles transfer reversal with a paid-vs-not-paid status CAS. A reversal
    /// after `paid` is fail-closed into manual review; earlier states are
    /// refunded exactly once.
    pub async fn reverse_withdrawal(
        &self,
        transition: &WithdrawalTransition,
    ) -> Result<WithdrawalResult, LedgerError> {
        if transition.expected_status == WithdrawalStatus::Paid {
            let mut review = transition.clone();
            review.failure_reason = Some("transfer_reversed_after_paid".into());
            return self
                .transition_withdrawal(&review, WithdrawalStatus::ReviewPending)
                .await
                .map(|mut result| {
                    result.disposition = WithdrawalDisposition::ManualReview;
                    result
                });
        }
        if !matches!(
            transition.expected_status,
            WithdrawalStatus::Pending | WithdrawalStatus::Transferred
        ) {
            return Err(LedgerError::StaleVersion);
        }
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.reversal_once(&authority, transition).await;
            match result {
                Ok(Some(row)) => return withdrawal_from_row(row, false),
                Ok(None) => {
                    return self
                        .resolve_withdrawal(
                            &authority,
                            &transition.operation,
                            &transition.withdrawal_id,
                            false,
                        )
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
                        .resolve_withdrawal_conflict(
                            &authority,
                            &transition.operation,
                            &transition.withdrawal_id,
                        )
                        .await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self
                        .resolve_withdrawal(
                            &authority,
                            &transition.operation,
                            &transition.withdrawal_id,
                            true,
                        )
                        .await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn reversal_once(
        &self,
        authority: &Authority,
        transition: &WithdrawalTransition,
    ) -> Result<Option<WithdrawalRow>, LedgerError> {
        self.db
            .bounded(
                sqlx::query_as_unchecked!(
                    WithdrawalRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    withdrawal AS MATERIALIZED (
                        SELECT withdrawals.*
                        FROM public.stripe_withdrawals AS withdrawals
                        WHERE withdrawals.id = $3
                          AND withdrawals.status = $4
                          AND withdrawals.refunded = FALSE
                        FOR UPDATE
                    ),
                    gate AS MATERIALIZED (
                        SELECT withdrawal.*
                        FROM authority
                        CROSS JOIN withdrawal
                        JOIN public.balances AS balances
                          ON balances.account_id = withdrawal.account_id
                        WHERE balances.balance_micro_usd >= 0
                          AND balances.withdrawable_micro_usd >= 0
                          AND balances.withdrawable_micro_usd
                              <= balances.balance_micro_usd
                          AND balances.balance_micro_usd
                              <= 9223372036854775807::BIGINT
                                 - withdrawal.amount_micro_usd
                          AND balances.withdrawable_micro_usd
                              <= 9223372036854775807::BIGINT
                                 - withdrawal.amount_micro_usd
                    ),
                    withdrawal_update AS (
                        UPDATE public.stripe_withdrawals AS withdrawals
                        SET
                            status = 'failed',
                            refunded = TRUE,
                            fee_refunded = TRUE,
                            failure_reason = 'transfer_reversed',
                            updated_at = NOW()
                        FROM gate
                        WHERE withdrawals.id = gate.id
                          AND withdrawals.status = $4
                          AND withdrawals.refunded = FALSE
                        RETURNING
                            withdrawals.id,
                            withdrawals.account_id,
                            withdrawals.amount_micro_usd
                    ),
                    operation_insert AS (
                        INSERT INTO rust_coord.financial_operations (
                            operation_id,
                            operation_key,
                            operation_digest,
                            kind,
                            status,
                            account_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd,
                            result,
                            owner_epoch,
                            version,
                            completed_at
                        )
                        SELECT
                            $5,
                            $6,
                            $7,
                            'withdrawal_refund',
                            'applied',
                            withdrawal_update.account_id,
                            withdrawal_update.amount_micro_usd,
                            withdrawal_update.amount_micro_usd,
                            jsonb_build_object(
                                'withdrawal_id', $3,
                                'status', 'failed',
                                'refunded', TRUE,
                                'manual_review', FALSE
                            ),
                            $2,
                            2,
                            NOW()
                        FROM withdrawal_update
                        RETURNING operation_id
                    ),
                    balance_update AS (
                        UPDATE public.balances AS balances
                        SET
                            balance_micro_usd =
                                balances.balance_micro_usd
                                + withdrawal_update.amount_micro_usd,
                            withdrawable_micro_usd =
                                balances.withdrawable_micro_usd
                                + withdrawal_update.amount_micro_usd,
                            updated_at = NOW()
                        FROM withdrawal_update, operation_insert
                        WHERE balances.account_id = withdrawal_update.account_id
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
                            withdrawal_update.account_id,
                            'refund',
                            withdrawal_update.amount_micro_usd,
                            balance_update.balance_micro_usd,
                            'stripe_withdraw:' || withdrawal_update.id
                        FROM withdrawal_update, balance_update
                        RETURNING id
                    )
                    SELECT
                        $3::TEXT AS withdrawal_id,
                        'failed'::TEXT AS status,
                        TRUE AS refunded,
                        FALSE AS manual_review
                    FROM operation_insert
                    CROSS JOIN ledger_insert
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    transition.withdrawal_id.as_str(),
                    transition.expected_status.as_str(),
                    transition.operation.id.as_uuid(),
                    transition.operation.key.as_str(),
                    transition.operation.digest.as_bytes().as_slice(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    async fn resolve_withdrawal(
        &self,
        authority: &Authority,
        operation: &crate::ledger::types::Operation,
        withdrawal_id: &WithdrawalId,
        ambiguous: bool,
    ) -> Result<WithdrawalResult, LedgerError> {
        if let Some(record) = self.db.operation(authority, &operation.key).await? {
            return withdrawal_from_operation(record, operation, withdrawal_id);
        }
        if ambiguous {
            Err(LedgerError::CommitOutcomeUnknown {
                operation: operation.key.clone(),
                diagnostic: "ambiguous withdrawal commit was not found during reconciliation"
                    .into(),
            })
        } else {
            Err(LedgerError::StaleVersion)
        }
    }

    async fn resolve_create_withdrawal(
        &self,
        authority: &Authority,
        request: &WithdrawalRequest,
        payload_digest: darkbloom_coordinator_core::ids::Digest,
        ambiguous: bool,
    ) -> Result<WithdrawalResult, LedgerError> {
        if let Some(record) = self.db.operation(authority, &request.operation.key).await? {
            self.validate_withdrawal_payload(authority, request, payload_digest)
                .await?;
            return withdrawal_from_operation(record, &request.operation, &request.withdrawal_id);
        }
        let diagnostic = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    WithdrawalCreateDiagnostic,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        EXISTS (
                            SELECT 1
                            FROM public.balances
                            WHERE account_id = $3
                              AND balance_micro_usd >= $4
                              AND withdrawable_micro_usd >= $4
                              AND withdrawable_micro_usd
                                  <= balance_micro_usd
                        ) AS funded,
                        EXISTS (
                            SELECT 1
                            FROM public.stripe_withdrawals
                            WHERE id = $5
                        ) AS withdrawal_conflict
                    WHERE EXISTS (SELECT 1 FROM authority)
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.account_id.as_str(),
                    request.amount.as_i64(),
                    request.withdrawal_id.as_str(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match diagnostic {
            Some(row) if row.withdrawal_conflict => Err(LedgerError::OperationConflict),
            Some(row) if !row.funded => Err(LedgerError::InsufficientBalance),
            Some(_) if ambiguous => Err(LedgerError::CommitOutcomeUnknown {
                operation: request.operation.key.clone(),
                diagnostic:
                    "ambiguous withdrawal intent commit was not found during reconciliation".into(),
            }),
            Some(_) => Err(LedgerError::OperationConflict),
            None => Err(LedgerError::OwnershipLost),
        }
    }

    async fn validate_withdrawal_payload(
        &self,
        authority: &Authority,
        request: &WithdrawalRequest,
        payload_digest: darkbloom_coordinator_core::ids::Digest,
    ) -> Result<(), LedgerError> {
        let matches = self
            .db
            .bounded(
                sqlx::query_scalar::<_, bool>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT EXISTS (
                        SELECT 1
                        FROM rust_coord.outbox
                        JOIN rust_coord.financial_operations AS operations
                          ON operations.operation_id = outbox.financial_operation_id
                        WHERE outbox.outbox_id = $3
                          AND outbox.payload_digest = $4
                          AND outbox.payload = $5
                          AND operations.operation_key = $6
                    )
                    FROM authority
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(request.outbox_id.as_uuid())
                .bind(payload_digest.as_bytes().as_slice())
                .bind(Json(&request.external_payload))
                .bind(request.operation.key.as_str())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match matches {
            Some(true) => Ok(()),
            Some(false) => Err(LedgerError::OperationConflict),
            None => Err(LedgerError::OwnershipLost),
        }
    }

    async fn resolve_withdrawal_conflict(
        &self,
        authority: &Authority,
        operation: &crate::ledger::types::Operation,
        withdrawal_id: &WithdrawalId,
    ) -> Result<WithdrawalResult, LedgerError> {
        let Some(record) = self.db.operation(authority, &operation.key).await? else {
            return Err(LedgerError::OperationConflict);
        };
        withdrawal_from_operation(record, operation, withdrawal_id)
    }
}

#[derive(Debug, FromRow)]
struct WithdrawalRow {
    withdrawal_id: String,
    status: String,
    refunded: bool,
    manual_review: bool,
}

#[derive(Debug, FromRow)]
struct WithdrawalCreateDiagnostic {
    funded: bool,
    withdrawal_conflict: bool,
}

fn withdrawal_from_row(
    row: WithdrawalRow,
    replayed: bool,
) -> Result<WithdrawalResult, LedgerError> {
    WithdrawalId::new(row.withdrawal_id).map_err(LedgerError::Invalid)?;
    let status = WithdrawalStatus::from_database(&row.status)?;
    Ok(WithdrawalResult {
        disposition: if row.manual_review {
            WithdrawalDisposition::ManualReview
        } else if replayed {
            WithdrawalDisposition::Replayed
        } else {
            WithdrawalDisposition::Applied
        },
        status,
        refunded: row.refunded,
    })
}

fn withdrawal_from_operation(
    record: OperationRecord,
    operation: &crate::ledger::types::Operation,
    withdrawal_id: &WithdrawalId,
) -> Result<WithdrawalResult, LedgerError> {
    if record.operation_key != operation.key.as_str()
        || record.digest()? != operation.digest
        || !matches!(
            record.kind.as_str(),
            "withdrawal_intent" | "withdrawal_complete" | "withdrawal_refund"
        )
        || record.status != "applied"
        || record
            .result
            .get("withdrawal_id")
            .and_then(serde_json::Value::as_str)
            != Some(withdrawal_id.as_str())
    {
        return Err(LedgerError::OperationConflict);
    }
    withdrawal_from_row(
        WithdrawalRow {
            withdrawal_id: json_string(&record.result, "withdrawal_id")?.to_owned(),
            status: json_string(&record.result, "status")?.to_owned(),
            refunded: record
                .result
                .get("refunded")
                .and_then(serde_json::Value::as_bool)
                .ok_or(LedgerError::CorruptData("refunded"))?,
            manual_review: record
                .result
                .get("manual_review")
                .and_then(serde_json::Value::as_bool)
                .ok_or(LedgerError::CorruptData("manual_review"))?,
        },
        true,
    )
}

#[allow(dead_code)]
fn _mutation_disposition_pin(_: MutationDisposition) {}
