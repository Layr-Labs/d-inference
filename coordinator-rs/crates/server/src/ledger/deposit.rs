use sqlx::{FromRow, types::Json};

use super::{
    LedgerService,
    reserve::json_string,
    types::{
        AccountId, DepositResult, LedgerAmount, LedgerError, MutationDisposition, StripeDeposit,
    },
};
use crate::db::ownership::{Authority, DurableDatabase, OperationRecord};

impl LedgerService {
    /// Applies a validated Stripe checkout event exactly once.
    pub async fn deposit(&self, deposit: &StripeDeposit) -> Result<DepositResult, LedgerError> {
        if !deposit.payload.is_object() {
            return Err(crate::ledger::types::InputError::TerminalPayloadNotObject.into());
        }
        if !deposit.currency.eq_ignore_ascii_case("usd") {
            return Err(LedgerError::OperationConflict);
        }
        if deposit.amount.as_i64() == 0 {
            return Err(crate::ledger::types::InputError::Empty("deposit amount").into());
        }
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.deposit_once(&authority, deposit).await;
            match result {
                Ok(Some(row)) => return deposit_from_row(row, MutationDisposition::Applied),
                Ok(None) => return self.resolve_deposit(&authority, deposit, false).await,
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::may_retry(attempt, source) =>
                {
                    self.db.retry_delay(attempt).await;
                    attempt += 1;
                }
                Err(LedgerError::Database(ref source))
                    if DurableDatabase::is_operation_conflict(source) =>
                {
                    return self.resolve_deposit_conflict(&authority, deposit).await;
                }
                Err(error) if DurableDatabase::is_ambiguous(&error) => {
                    return self.resolve_deposit(&authority, deposit, true).await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn deposit_once(
        &self,
        authority: &Authority,
        deposit: &StripeDeposit,
    ) -> Result<Option<DepositRow>, LedgerError> {
        self.db
            .bounded(
                sqlx::query_as_unchecked!(
                    DepositRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    billing AS MATERIALIZED (
                        SELECT
                            sessions.*,
                            balances.balance_micro_usd,
                            balances.withdrawable_micro_usd
                        FROM public.billing_sessions AS sessions
                        JOIN public.balances AS balances
                          ON balances.account_id = sessions.account_id
                        WHERE sessions.id = $3
                          AND sessions.payment_method = 'stripe'
                          AND lower(sessions.currency) = 'usd'
                          AND sessions.amount_micro_usd = $4
                          AND sessions.status = 'pending'
                          AND (
                              sessions.external_id = ''
                              OR sessions.external_id = $5
                          )
                          AND balances.balance_micro_usd >= 0
                          AND balances.withdrawable_micro_usd >= 0
                          AND balances.withdrawable_micro_usd
                              <= balances.balance_micro_usd
                          AND balances.balance_micro_usd
                              <= 9223372036854775807::BIGINT - $4
                        FOR UPDATE OF sessions, balances
                    ),
                    gate AS MATERIALIZED (
                        SELECT billing.*
                        FROM authority
                        CROSS JOIN billing
                        WHERE jsonb_typeof($10::JSONB) = 'object'
                          AND NOT EXISTS (
                              SELECT 1
                              FROM public.billing_sessions
                              WHERE external_id = $5 AND id <> $3
                          )
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
                            $6,
                            $7,
                            $8,
                            'deposit',
                            'applied',
                            gate.account_id,
                            $4,
                            0,
                            jsonb_build_object(
                                'account_id', gate.account_id,
                                'amount', $4::BIGINT,
                                'event_id', $9::TEXT
                            ),
                            $2,
                            2,
                            NOW()
                        FROM gate
                        RETURNING operation_id
                    ),
                    balance_update AS (
                        INSERT INTO public.balances (
                            account_id,
                            balance_micro_usd,
                            withdrawable_micro_usd,
                            updated_at
                        )
                        SELECT gate.account_id, $4, 0, NOW()
                        FROM gate
                        CROSS JOIN operation_insert
                        ON CONFLICT (account_id) DO UPDATE SET
                            balance_micro_usd =
                                balances.balance_micro_usd
                                + EXCLUDED.balance_micro_usd,
                            updated_at = NOW()
                        WHERE balances.balance_micro_usd >= 0
                          AND balances.withdrawable_micro_usd >= 0
                          AND balances.withdrawable_micro_usd
                              <= balances.balance_micro_usd
                          AND balances.balance_micro_usd
                              <= 9223372036854775807::BIGINT
                                 - EXCLUDED.balance_micro_usd
                        RETURNING account_id, balance_micro_usd
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
                            'stripe_deposit',
                            $4,
                            balance_update.balance_micro_usd,
                            'stripe:' || $5
                        FROM balance_update
                        RETURNING id
                    ),
                    billing_update AS (
                        UPDATE public.billing_sessions AS sessions
                        SET
                            external_id = $5,
                            processed_event_id = $9,
                            status = 'completed',
                            completed_at = NOW()
                        FROM gate, ledger_insert
                        WHERE sessions.id = gate.id
                          AND sessions.status = 'pending'
                        RETURNING sessions.account_id
                    ),
                    stripe_event_insert AS (
                        INSERT INTO public.stripe_deposit_events (
                            event_id,
                            checkout_session_id,
                            billing_session_id,
                            account_id,
                            amount_micro_usd,
                            currency,
                            status
                        )
                        SELECT
                            $9::TEXT,
                            $5,
                            $3,
                            billing_update.account_id,
                            $4,
                            'usd',
                            'applied'
                        FROM billing_update
                        RETURNING account_id
                    ),
                    external_event_insert AS (
                        INSERT INTO rust_coord.external_events (
                            external_event_id,
                            source,
                            event_id,
                            event_kind,
                            payload_digest,
                            payload,
                            status,
                            financial_operation_id,
                            owner_epoch,
                            processed_at
                        )
                        SELECT
                            $11,
                            'stripe',
                            $9::TEXT,
                            'checkout.session.completed',
                            $12,
                            $10,
                            'applied',
                            operation_insert.operation_id,
                            $2,
                            NOW()
                        FROM operation_insert
                        CROSS JOIN stripe_event_insert
                        RETURNING external_event_id
                    )
                    SELECT
                        stripe_event_insert.account_id,
                        $4::BIGINT AS amount
                    FROM stripe_event_insert
                    CROSS JOIN operation_insert
                    CROSS JOIN external_event_insert
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    deposit.billing_session_id.as_str(),
                    deposit.amount.as_i64(),
                    deposit.checkout_session_id.as_str(),
                    deposit.operation.id.as_uuid(),
                    deposit.operation.key.as_str(),
                    deposit.operation.digest.as_bytes().as_slice(),
                    deposit.event_id.as_str(),
                    Json(&deposit.payload),
                    deposit.external_event_id.as_uuid(),
                    deposit.payload_digest.as_bytes().as_slice(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    async fn resolve_deposit(
        &self,
        authority: &Authority,
        deposit: &StripeDeposit,
        ambiguous: bool,
    ) -> Result<DepositResult, LedgerError> {
        if let Some(operation) = self.db.operation(authority, &deposit.operation.key).await? {
            return deposit_from_operation(operation, deposit);
        }
        if ambiguous {
            return Err(LedgerError::CommitOutcomeUnknown(
                deposit.operation.key.clone(),
            ));
        }
        Err(LedgerError::OperationConflict)
    }

    async fn resolve_deposit_conflict(
        &self,
        authority: &Authority,
        deposit: &StripeDeposit,
    ) -> Result<DepositResult, LedgerError> {
        let Some(operation) = self.db.operation(authority, &deposit.operation.key).await? else {
            return Err(LedgerError::OperationConflict);
        };
        deposit_from_operation(operation, deposit)
    }
}

#[derive(Debug, FromRow)]
struct DepositRow {
    account_id: String,
    amount: i64,
}

fn deposit_from_row(
    row: DepositRow,
    disposition: MutationDisposition,
) -> Result<DepositResult, LedgerError> {
    Ok(DepositResult {
        disposition,
        account_id: AccountId::new(row.account_id).map_err(LedgerError::Invalid)?,
        amount: LedgerAmount::from_i64(row.amount).map_err(LedgerError::Invalid)?,
    })
}

fn deposit_from_operation(
    operation: OperationRecord,
    deposit: &StripeDeposit,
) -> Result<DepositResult, LedgerError> {
    if operation.operation_key != deposit.operation.key.as_str()
        || operation.digest()? != deposit.operation.digest
        || operation.kind != "deposit"
        || operation.status != "applied"
        || operation.amount_total_micro_usd != deposit.amount.as_i64()
        || operation.amount_withdrawable_micro_usd != 0
        || operation
            .result
            .get("event_id")
            .and_then(serde_json::Value::as_str)
            != Some(deposit.event_id.as_str())
    {
        return Err(LedgerError::OperationConflict);
    }
    let result = DepositRow {
        account_id: json_string(&operation.result, "account_id")?.to_owned(),
        amount: operation
            .result
            .get("amount")
            .and_then(serde_json::Value::as_i64)
            .ok_or(LedgerError::CorruptData("amount"))?,
    };
    deposit_from_row(result, MutationDisposition::Replayed)
}
