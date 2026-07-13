use std::sync::Arc;

use serde::{Deserialize, Serialize};
use sqlx::{FromRow, Row, types::Json as SqlJson};
use uuid::Uuid;

use crate::{
    database::Database,
    ledger::canonical_json_digest,
    recovery::OutboxLease,
    telemetry::datadog::{self, Metric, Tag, TagKey},
};

use super::{
    error::BillingError,
    store::BillingStore,
    stripe::{Payout, StripeClient, StripeError, StripeOutcome, Transfer},
};

#[derive(Clone, Debug)]
pub struct WithdrawalRecovery {
    store: BillingStore,
    stripe: Arc<StripeClient>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WithdrawalRecoveryAction {
    Handled,
    Retry,
}

impl WithdrawalRecovery {
    pub fn new(database: Database, settings: super::StripeSettings) -> Result<Self, BillingError> {
        Ok(Self {
            store: BillingStore::new(database),
            stripe: Arc::new(StripeClient::new(settings)?),
        })
    }

    pub(super) fn from_parts(store: BillingStore, stripe: Arc<StripeClient>) -> Self {
        Self { store, stripe }
    }

    pub async fn process(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
    ) -> Result<WithdrawalRecoveryAction, WithdrawalRecoveryError> {
        if worker_id.is_nil()
            || lease.kind.as_ref() != "external_call"
            || canonical_json_digest(&lease.payload)? != lease.payload_digest
        {
            return Err(WithdrawalRecoveryError::InvalidPayload);
        }
        let payload: WithdrawalPayload = serde_json::from_value(lease.payload.clone())
            .map_err(|_| WithdrawalRecoveryError::InvalidPayload)?;
        payload.validate(lease)?;
        let stored = self.load(&payload.withdrawal_id).await?;
        stored.validate(&payload)?;

        if stored.refunded || stored.status == "failed" {
            self.complete_existing(worker_id, lease, "failed").await?;
            return Ok(WithdrawalRecoveryAction::Handled);
        }
        if stored.status == "review_pending" {
            self.complete_existing(worker_id, lease, "failed").await?;
            return Ok(WithdrawalRecoveryAction::Handled);
        }
        if stored.status == "paid"
            || (stored.status == "transferred" && payload.method == "standard")
        {
            self.complete_existing(worker_id, lease, "delivered")
                .await?;
            return Ok(WithdrawalRecoveryAction::Handled);
        }

        self.mark_submitted(worker_id, lease, &payload).await?;
        let transfer = match self.reconcile_transfer(&payload, &stored).await {
            Ok(transfer) => transfer,
            Err(error) if error.outcome == StripeOutcome::Unknown => {
                if lease.attempts < lease.max_attempts {
                    return Ok(WithdrawalRecoveryAction::Retry);
                }
                return self
                    .finish_external_unknown(
                        worker_id,
                        lease,
                        &payload,
                        &format!("Stripe transfer outcome remained unknown: {error}"),
                    )
                    .await;
            }
            Err(error) => {
                return self
                    .finish_failure(
                        worker_id,
                        lease,
                        &payload,
                        &stored,
                        &format!("Stripe transfer failed permanently: {error}"),
                    )
                    .await;
            }
        };

        self.record_transfer(worker_id, lease, &payload, &transfer)
            .await?;
        if payload.method == "standard" {
            self.complete_success(worker_id, lease, &payload, &transfer, None)
                .await?;
            return Ok(WithdrawalRecoveryAction::Handled);
        }

        let payout = match self.reconcile_payout(&payload, &stored).await {
            Ok(payout) => payout,
            Err(error) if error.outcome == StripeOutcome::Unknown => {
                if lease.attempts < lease.max_attempts {
                    return Ok(WithdrawalRecoveryAction::Retry);
                }
                return self
                    .finish_external_unknown(
                        worker_id,
                        lease,
                        &payload,
                        &format!("Stripe payout outcome remained unknown: {error}"),
                    )
                    .await;
            }
            Err(error) => {
                return self
                    .finish_instant_fallback(
                        worker_id,
                        lease,
                        &payload,
                        &transfer,
                        &format!("Stripe payout failed permanently: {error}"),
                    )
                    .await;
            }
        };
        self.complete_success(worker_id, lease, &payload, &transfer, Some(&payout))
            .await?;
        Ok(WithdrawalRecoveryAction::Handled)
    }

    async fn load(&self, withdrawal_id: &str) -> Result<StoredWithdrawal, WithdrawalRecoveryError> {
        sqlx::query_as::<_, StoredWithdrawal>(
            r#"
            SELECT
                id, account_id, stripe_account_id, transfer_id, payout_id,
                amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
                refunded, idempotency_key, external_state, provenance
            FROM public.stripe_withdrawals
            WHERE id = $1
            "#,
        )
        .bind(withdrawal_id)
        .fetch_optional(self.store.pool())
        .await?
        .ok_or(WithdrawalRecoveryError::InvalidPayload)
    }

    async fn reconcile_transfer(
        &self,
        payload: &WithdrawalPayload,
        stored: &StoredWithdrawal,
    ) -> Result<Transfer, StripeError> {
        if !stored.transfer_id.is_empty() {
            return self.stripe.transfer(&stored.transfer_id).await;
        }
        if let Some(transfer) = self
            .stripe
            .find_transfer(&payload.stripe_account_id, &payload.withdrawal_id)
            .await?
        {
            return Ok(transfer);
        }
        let outcome = self
            .stripe
            .create_transfer(
                &payload.stripe_account_id,
                payload.amount_cents,
                &payload.transfer_idempotency_key,
                &payload.withdrawal_id,
            )
            .await;
        crate::fault_checkpoint_async!(
            ExternalCallUnknown,
            "WithdrawalRecoveryService::reconcile_transfer",
            |error| StripeError {
                code: String::new(),
                message: error.to_string(),
                outcome: StripeOutcome::Unknown,
            }
        );
        match outcome {
            Ok(transfer) => Ok(transfer),
            Err(error) if error.outcome == StripeOutcome::Unknown => self
                .stripe
                .find_transfer(&payload.stripe_account_id, &payload.withdrawal_id)
                .await?
                .ok_or(error),
            Err(error) => Err(error),
        }
    }

    async fn reconcile_payout(
        &self,
        payload: &WithdrawalPayload,
        stored: &StoredWithdrawal,
    ) -> Result<Payout, StripeError> {
        if !stored.payout_id.is_empty() {
            return self
                .stripe
                .payout(&payload.stripe_account_id, &stored.payout_id)
                .await;
        }
        if let Some(payout) = self
            .stripe
            .find_payout(&payload.stripe_account_id, &payload.withdrawal_id)
            .await?
        {
            return Ok(payout);
        }
        let outcome = self
            .stripe
            .create_payout(
                &payload.stripe_account_id,
                payload.amount_cents,
                &payload.payout_idempotency_key,
                &payload.withdrawal_id,
            )
            .await;
        match outcome {
            Ok(payout) => Ok(payout),
            Err(error) if error.outcome == StripeOutcome::Unknown => self
                .stripe
                .find_payout(&payload.stripe_account_id, &payload.withdrawal_id)
                .await?
                .ok_or(error),
            Err(error) => Err(error),
        }
    }

    async fn mark_submitted(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
        payload: &WithdrawalPayload,
    ) -> Result<(), WithdrawalRecoveryError> {
        let mut transaction = self.store.begin("mark Stripe withdrawal submitted").await?;
        let updated = sqlx::query(
            r#"
            UPDATE public.stripe_withdrawals AS withdrawals
            SET
                external_state = 'submitted_unknown',
                attempt_count = GREATEST(attempt_count, $6),
                next_attempt_at = NOW(),
                updated_at = NOW()
            FROM rust_coord.outbox AS outbox
            WHERE withdrawals.id = $1
              AND withdrawals.provenance = $2
              AND outbox.outbox_id = $3
              AND outbox.worker_owner = $4
              AND outbox.version = $5
              AND outbox.status = 'processing'
              AND outbox.lease_until > NOW()
              AND withdrawals.status IN ('pending', 'transferred')
              AND NOT withdrawals.refunded
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(SqlJson(&lease.payload))
        .bind(lease.outbox_id.as_uuid())
        .bind(worker_id)
        .bind(lease.version.as_i64())
        .bind(i32::try_from(lease.attempts).unwrap_or(i32::MAX))
        .execute(transaction.connection())
        .await?;
        if updated.rows_affected() != 1 {
            return Err(WithdrawalRecoveryError::StaleLease);
        }
        transaction.commit().await?;
        Ok(())
    }

    async fn record_transfer(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
        payload: &WithdrawalPayload,
        transfer: &Transfer,
    ) -> Result<(), WithdrawalRecoveryError> {
        let mut transaction = self.store.begin("record recovered Stripe transfer").await?;
        lock_withdrawal(transaction.connection(), &payload.withdrawal_id).await?;
        let updated = sqlx::query(
            r#"
            UPDATE public.stripe_withdrawals AS withdrawals
            SET
                status = 'transferred',
                transfer_id = $6,
                external_state = 'confirmed',
                updated_at = NOW()
            FROM rust_coord.outbox AS outbox
            WHERE withdrawals.id = $1
              AND withdrawals.provenance = $2
              AND outbox.outbox_id = $3
              AND outbox.worker_owner = $4
              AND outbox.version = $5
              AND outbox.status = 'processing'
              AND outbox.lease_until > NOW()
              AND withdrawals.status IN ('pending', 'transferred')
              AND NOT withdrawals.refunded
              AND withdrawals.transfer_id IN ('', $6)
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(SqlJson(&lease.payload))
        .bind(lease.outbox_id.as_uuid())
        .bind(worker_id)
        .bind(lease.version.as_i64())
        .bind(&transfer.id)
        .execute(transaction.connection())
        .await?;
        if updated.rows_affected() != 1 {
            return Err(WithdrawalRecoveryError::StaleLease);
        }
        transaction.commit().await?;
        Ok(())
    }

    async fn complete_success(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
        payload: &WithdrawalPayload,
        transfer: &Transfer,
        payout: Option<&Payout>,
    ) -> Result<(), WithdrawalRecoveryError> {
        let mut transaction = self
            .store
            .begin("complete recovered Stripe withdrawal")
            .await?;
        lock_withdrawal(transaction.connection(), &payload.withdrawal_id).await?;
        let payout_id = payout.map_or("", |payout| payout.id.as_str());
        let status = if payout.is_some_and(|payout| payout.status == "paid") {
            "paid"
        } else {
            "transferred"
        };
        let withdrawal = sqlx::query(
            r#"
            UPDATE public.stripe_withdrawals
            SET
                status = $4,
                transfer_id = $2,
                payout_id = CASE WHEN $3 = '' THEN payout_id ELSE $3 END,
                external_state = 'confirmed',
                completed_at = NOW(),
                updated_at = NOW()
            WHERE id = $1
              AND provenance = $5
              AND status IN ('pending', 'transferred', 'paid')
              AND NOT refunded
              AND transfer_id IN ('', $2)
              AND (payout_id = '' OR $3 = '' OR payout_id = $3)
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(&transfer.id)
        .bind(payout_id)
        .bind(status)
        .bind(SqlJson(&lease.payload))
        .execute(transaction.connection())
        .await?;
        if withdrawal.rows_affected() != 1 {
            return Err(WithdrawalRecoveryError::StaleLease);
        }
        complete_outbox(
            transaction.connection(),
            worker_id,
            lease,
            "delivered",
            true,
        )
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    async fn finish_failure(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
        payload: &WithdrawalPayload,
        stored: &StoredWithdrawal,
        reason: &str,
    ) -> Result<WithdrawalRecoveryAction, WithdrawalRecoveryError> {
        if !stored.transfer_id.is_empty() || stored.status == "transferred" {
            return self
                .finish_instant_fallback(
                    worker_id,
                    lease,
                    payload,
                    &Transfer {
                        id: stored.transfer_id.clone(),
                    },
                    reason,
                )
                .await;
        }
        let mut transaction = self
            .store
            .begin("refund failed recovered withdrawal")
            .await?;
        lock_withdrawal(transaction.connection(), &payload.withdrawal_id).await?;
        let balance = sqlx::query(
            r#"
            UPDATE public.balances AS balances
            SET
                balance_micro_usd = balances.balance_micro_usd + $2,
                withdrawable_micro_usd = balances.withdrawable_micro_usd + $2,
                updated_at = NOW()
            FROM public.stripe_withdrawals AS withdrawals
            WHERE withdrawals.id = $1
              AND withdrawals.provenance = $3
              AND withdrawals.status = 'pending'
              AND NOT withdrawals.refunded
              AND withdrawals.transfer_id = ''
              AND balances.account_id = withdrawals.account_id
              AND balances.balance_micro_usd <= 9223372036854775807 - $2
              AND balances.withdrawable_micro_usd <= 9223372036854775807 - $2
            RETURNING balances.account_id, balances.balance_micro_usd
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(payload.gross_micro_usd)
        .bind(SqlJson(&lease.payload))
        .fetch_optional(transaction.connection())
        .await?
        .ok_or(WithdrawalRecoveryError::StaleLease)?;
        let account_id = balance.get::<String, _>("account_id");
        let balance_after = balance.get::<i64, _>("balance_micro_usd");
        sqlx::query(
            r#"
            INSERT INTO public.ledger_entries (
                account_id, entry_type, amount_micro_usd, balance_after, reference
            )
            VALUES ($1, 'refund', $2, $3, 'stripe_withdraw:' || $4)
            "#,
        )
        .bind(&account_id)
        .bind(payload.gross_micro_usd)
        .bind(balance_after)
        .bind(&payload.withdrawal_id)
        .execute(transaction.connection())
        .await?;
        self.record_failure(transaction.connection(), payload, lease, reason, true)
            .await?;
        complete_outbox(transaction.connection(), worker_id, lease, "failed", false).await?;
        transaction.commit().await?;
        Ok(WithdrawalRecoveryAction::Handled)
    }

    async fn finish_external_unknown(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
        payload: &WithdrawalPayload,
        reason: &str,
    ) -> Result<WithdrawalRecoveryAction, WithdrawalRecoveryError> {
        let mut transaction = self
            .store
            .begin("retain unresolved Stripe withdrawal for review")
            .await?;
        lock_withdrawal(transaction.connection(), &payload.withdrawal_id).await?;
        let updated = sqlx::query(
            r#"
            UPDATE public.stripe_withdrawals
            SET
                status = 'review_pending',
                external_state = 'external_unknown',
                failure_reason = $3,
                attempt_count = GREATEST(attempt_count, $4),
                updated_at = NOW()
            WHERE id = $1
              AND provenance = $2
              AND status IN ('pending', 'transferred')
              AND NOT refunded
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(SqlJson(&lease.payload))
        .bind(bounded_reason(reason))
        .bind(i32::try_from(lease.attempts).unwrap_or(i32::MAX))
        .execute(transaction.connection())
        .await?;
        if updated.rows_affected() != 1 {
            return Err(WithdrawalRecoveryError::StaleLease);
        }
        complete_outbox(transaction.connection(), worker_id, lease, "failed", false).await?;
        transaction.commit().await?;
        datadog::counter(
            Metric::ExternalUnknown,
            1,
            &[Tag::new(TagKey::Source, "stripe")],
        );
        Ok(WithdrawalRecoveryAction::Handled)
    }

    async fn finish_instant_fallback(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
        payload: &WithdrawalPayload,
        transfer: &Transfer,
        reason: &str,
    ) -> Result<WithdrawalRecoveryAction, WithdrawalRecoveryError> {
        let mut transaction = self
            .store
            .begin("reopen failed recovered instant payout")
            .await?;
        lock_withdrawal(transaction.connection(), &payload.withdrawal_id).await?;
        let row = sqlx::query(
            r#"
            SELECT account_id, fee_micro_usd, fee_refunded
            FROM public.stripe_withdrawals
            WHERE id = $1
              AND provenance = $2
              AND status = 'transferred'
              AND NOT refunded
              AND transfer_id = $3
            FOR UPDATE
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(SqlJson(&lease.payload))
        .bind(&transfer.id)
        .fetch_optional(transaction.connection())
        .await?
        .ok_or(WithdrawalRecoveryError::StaleLease)?;
        let account_id = row.get::<String, _>("account_id");
        let fee = row.get::<i64, _>("fee_micro_usd");
        let fee_refunded = row.get::<bool, _>("fee_refunded");
        if fee > 0 && !fee_refunded {
            let balance_after: i64 = sqlx::query_scalar(
                r#"
                UPDATE public.balances
                SET
                    balance_micro_usd = balance_micro_usd + $2,
                    withdrawable_micro_usd = withdrawable_micro_usd + $2,
                    updated_at = NOW()
                WHERE account_id = $1
                  AND balance_micro_usd <= 9223372036854775807 - $2
                  AND withdrawable_micro_usd <= 9223372036854775807 - $2
                RETURNING balance_micro_usd
                "#,
            )
            .bind(&account_id)
            .bind(fee)
            .fetch_one(transaction.connection())
            .await?;
            sqlx::query(
                r#"
                INSERT INTO public.ledger_entries (
                    account_id, entry_type, amount_micro_usd, balance_after, reference
                )
                VALUES ($1, 'refund', $2, $3, 'stripe_withdraw_fee:' || $4)
                "#,
            )
            .bind(&account_id)
            .bind(fee)
            .bind(balance_after)
            .bind(&payload.withdrawal_id)
            .execute(transaction.connection())
            .await?;
        }
        sqlx::query(
            r#"
            UPDATE public.stripe_withdrawals
            SET
                fee_refunded = TRUE,
                external_state = 'permanent_failure',
                failure_reason = $2,
                completed_at = NOW(),
                updated_at = NOW()
            WHERE id = $1
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(bounded_reason(reason))
        .execute(transaction.connection())
        .await?;
        self.record_failure(transaction.connection(), payload, lease, reason, false)
            .await?;
        complete_outbox(transaction.connection(), worker_id, lease, "failed", false).await?;
        transaction.commit().await?;
        Ok(WithdrawalRecoveryAction::Handled)
    }

    async fn record_failure(
        &self,
        connection: &mut sqlx::PgConnection,
        payload: &WithdrawalPayload,
        lease: &OutboxLease,
        reason: &str,
        refunded: bool,
    ) -> Result<(), WithdrawalRecoveryError> {
        sqlx::query(
            r#"
            UPDATE public.stripe_withdrawals
            SET
                status = CASE WHEN $5 THEN 'failed' ELSE status END,
                refunded = CASE WHEN $5 THEN TRUE ELSE refunded END,
                fee_refunded = TRUE,
                external_state = 'permanent_failure',
                failure_reason = $4,
                completed_at = NOW(),
                updated_at = NOW()
            WHERE id = $1 AND provenance = $2
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(SqlJson(&lease.payload))
        .bind(&payload.transfer_idempotency_key)
        .bind(bounded_reason(reason))
        .bind(refunded)
        .execute(&mut *connection)
        .await?;
        sqlx::query(
            r#"
            INSERT INTO public.stripe_withdrawal_failures (
                withdrawal_id, idempotency_key, account_id,
                amount_micro_usd, fee_micro_usd, reason, attempts
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (withdrawal_id) DO UPDATE SET
                reason = EXCLUDED.reason,
                attempts = GREATEST(
                    stripe_withdrawal_failures.attempts,
                    EXCLUDED.attempts
                )
            WHERE stripe_withdrawal_failures.idempotency_key =
                  EXCLUDED.idempotency_key
              AND stripe_withdrawal_failures.account_id = EXCLUDED.account_id
              AND stripe_withdrawal_failures.amount_micro_usd =
                  EXCLUDED.amount_micro_usd
              AND stripe_withdrawal_failures.fee_micro_usd =
                  EXCLUDED.fee_micro_usd
            "#,
        )
        .bind(&payload.withdrawal_id)
        .bind(&payload.transfer_idempotency_key)
        .bind(&payload.account_id)
        .bind(payload.gross_micro_usd)
        .bind(payload.fee_micro_usd)
        .bind(bounded_reason(reason))
        .bind(i32::try_from(lease.attempts).unwrap_or(i32::MAX))
        .execute(&mut *connection)
        .await?;
        Ok(())
    }

    async fn complete_existing(
        &self,
        worker_id: Uuid,
        lease: &OutboxLease,
        status: &str,
    ) -> Result<(), WithdrawalRecoveryError> {
        let mut transaction = self
            .store
            .begin("reconcile completed Stripe outbox")
            .await?;
        complete_outbox(
            transaction.connection(),
            worker_id,
            lease,
            status,
            status == "delivered",
        )
        .await?;
        transaction.commit().await?;
        Ok(())
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct WithdrawalPayload {
    withdrawal_id: String,
    account_id: String,
    stripe_account_id: String,
    gross_micro_usd: i64,
    fee_micro_usd: i64,
    net_micro_usd: i64,
    amount_cents: i64,
    method: String,
    transfer_idempotency_key: String,
    payout_idempotency_key: String,
}

impl WithdrawalPayload {
    fn validate(&self, lease: &OutboxLease) -> Result<(), WithdrawalRecoveryError> {
        let expected_operation = format!("withdrawal-call:{}", self.withdrawal_id);
        if lease.operation_key.as_str() != expected_operation
            || self.withdrawal_id.is_empty()
            || self.account_id.is_empty()
            || !self.stripe_account_id.starts_with("acct_")
            || self.gross_micro_usd <= 0
            || self.fee_micro_usd < 0
            || self.net_micro_usd <= 0
            || self.fee_micro_usd.checked_add(self.net_micro_usd) != Some(self.gross_micro_usd)
            || self.amount_cents <= 0
            || self.net_micro_usd / 10_000 != self.amount_cents
            || !matches!(self.method.as_str(), "standard" | "instant")
            || self.transfer_idempotency_key.is_empty()
            || self.transfer_idempotency_key.len() > 255
            || (self.method == "instant" && self.payout_idempotency_key.is_empty())
            || (self.method == "standard" && !self.payout_idempotency_key.is_empty())
        {
            return Err(WithdrawalRecoveryError::InvalidPayload);
        }
        Ok(())
    }
}

#[derive(Debug, FromRow)]
struct StoredWithdrawal {
    id: String,
    account_id: String,
    stripe_account_id: String,
    transfer_id: String,
    payout_id: String,
    amount_micro_usd: i64,
    fee_micro_usd: i64,
    net_micro_usd: i64,
    method: String,
    status: String,
    refunded: bool,
    idempotency_key: String,
    external_state: String,
    provenance: serde_json::Value,
}

impl StoredWithdrawal {
    fn validate(&self, payload: &WithdrawalPayload) -> Result<(), WithdrawalRecoveryError> {
        if self.id != payload.withdrawal_id
            || self.account_id != payload.account_id
            || self.stripe_account_id != payload.stripe_account_id
            || self.amount_micro_usd != payload.gross_micro_usd
            || self.fee_micro_usd != payload.fee_micro_usd
            || self.net_micro_usd != payload.net_micro_usd
            || self.method != payload.method
            || self.idempotency_key != payload.transfer_idempotency_key
            || self.provenance
                != serde_json::to_value(payload).expect("withdrawal payload serializes")
            || !matches!(
                self.status.as_str(),
                "pending" | "transferred" | "paid" | "failed" | "review_pending"
            )
            || !matches!(
                self.external_state.as_str(),
                "not_started"
                    | "submitted_unknown"
                    | "confirmed"
                    | "permanent_failure"
                    | "external_unknown"
            )
        {
            return Err(WithdrawalRecoveryError::InvalidPayload);
        }
        Ok(())
    }
}

async fn lock_withdrawal(
    connection: &mut sqlx::PgConnection,
    withdrawal_id: &str,
) -> Result<(), WithdrawalRecoveryError> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(format!("stripe-withdrawal:{withdrawal_id}"))
        .execute(connection)
        .await?;
    Ok(())
}

async fn complete_outbox(
    connection: &mut sqlx::PgConnection,
    worker_id: Uuid,
    lease: &OutboxLease,
    status: &str,
    delivered: bool,
) -> Result<(), WithdrawalRecoveryError> {
    let updated = sqlx::query(
        r#"
        UPDATE rust_coord.outbox
        SET
            status = $5,
            worker_owner = NULL,
            lease_until = NULL,
            version = version + 1,
            updated_at = NOW(),
            delivered_at = CASE WHEN $6 THEN NOW() ELSE delivered_at END
        WHERE outbox_id = $1
          AND worker_owner = $2
          AND version = $3
          AND status = 'processing'
          AND lease_until > NOW()
          AND kind = 'external_call'
          AND payload_digest = $4
        "#,
    )
    .bind(lease.outbox_id.as_uuid())
    .bind(worker_id)
    .bind(lease.version.as_i64())
    .bind(lease.payload_digest.as_bytes().as_slice())
    .bind(status)
    .bind(delivered)
    .execute(connection)
    .await?;
    if updated.rows_affected() != 1 {
        return Err(WithdrawalRecoveryError::StaleLease);
    }
    Ok(())
}

fn bounded_reason(reason: &str) -> &str {
    const MAXIMUM: usize = 512;
    if reason.len() <= MAXIMUM {
        return reason;
    }
    let mut boundary = MAXIMUM;
    while !reason.is_char_boundary(boundary) {
        boundary -= 1;
    }
    &reason[..boundary]
}

#[derive(Debug, thiserror::Error)]
pub enum WithdrawalRecoveryError {
    #[error("invalid or conflicting withdrawal recovery payload")]
    InvalidPayload,
    #[error("withdrawal recovery lease is stale")]
    StaleLease,
    #[error(transparent)]
    Ledger(#[from] crate::ledger::LedgerError),
    #[error(transparent)]
    Database(#[from] crate::database::DatabaseError),
    #[error(transparent)]
    Sql(#[from] sqlx::Error),
    #[error(transparent)]
    Billing(#[from] BillingError),
}
