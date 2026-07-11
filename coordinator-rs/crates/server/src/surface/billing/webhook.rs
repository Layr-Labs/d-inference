use std::sync::Arc;

use axum::{
    Json,
    extract::{Request, State},
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};
use sqlx::{Row, types::Json as SqlJson};

use crate::ledger::{
    ExternalId, LedgerError, Operation, OperationId, OperationKey, WithdrawalId, WithdrawalStatus,
    WithdrawalTransition, canonical_json_digest,
};

use super::{
    body,
    checkout::{deterministic_uuid, event_operation_digest, required_event_string},
    connect::persist_account,
    error::BillingError,
    state::BillingState,
    store::{BillingStore, validate_balance},
    stripe::{StripeAccount, StripeOutcome, required_service_agreement},
};

const RECIPIENT_TRANSFER_DELAY_SECONDS: i64 = 24 * 60 * 60;

pub(super) async fn connect_webhook(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let signature = request
        .headers()
        .get("stripe-signature")
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| BillingError::bad_request("Stripe-Signature header is required"))?
        .to_owned();
    let stripe = state
        .stripe
        .as_ref()
        .ok_or_else(|| BillingError::unavailable("Stripe Connect is not configured"))?
        .clone();
    let raw = body::raw(request).await?;
    let event = stripe.verify_connect(&raw, &signature)?;
    let event_id = required_event_string(&event, "id")?.to_owned();
    let event_type = required_event_string(&event, "type")?.to_owned();
    let claim = claim_event(&state.store, &event_id, &event_type, &event).await?;
    if claim == EventClaim::Terminal {
        return Ok(Json(json!({"received": true, "replayed": true})).into_response());
    }
    let outcome = match event_type.as_str() {
        "account.updated" => handle_account_updated(&state.store, &event).await,
        "payout.paid" => handle_payout(&state, &event_id, &event, PayoutDisposition::Paid).await,
        "payout.failed" | "payout.canceled" => {
            handle_payout(&state, &event_id, &event, PayoutDisposition::Failed).await
        }
        "transfer.reversed" => handle_transfer_reversal(&state.store, &event_id, &event).await,
        _ => {
            finish_event(&state.store, &event_id, "ignored").await?;
            return Ok(Json(json!({"received": true, "ignored": true})).into_response());
        }
    };
    match outcome {
        Ok(()) => {
            finish_event(&state.store, &event_id, "applied").await?;
            Ok(Json(json!({"received": true})).into_response())
        }
        Err(error) if error.is_external_unknown() => Err(BillingError::retryable(
            "process Stripe Connect event",
            error,
        )),
        Err(error) => Err(error),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EventClaim {
    New,
    Retry,
    Terminal,
}

async fn claim_event(
    store: &BillingStore,
    event_id: &str,
    event_kind: &str,
    payload: &Value,
) -> Result<EventClaim, BillingError> {
    let digest = canonical_json_digest(payload)
        .map_err(|error| BillingError::from_ledger("digest Stripe Connect event", error))?;
    let mut transaction = store.begin("claim Stripe Connect event").await?;
    let owner_epoch = transaction.context().epoch();
    let inserted = sqlx::query(
        r#"
        INSERT INTO rust_coord.external_events (
            external_event_id, source, event_id, event_kind, payload_digest,
            payload, status, owner_epoch
        )
        VALUES ($1, 'stripe_connect', $2, $3, $4, $5, 'processing', $6)
        ON CONFLICT (source, event_id) DO NOTHING
        RETURNING external_event_id
        "#,
    )
    .bind(deterministic_uuid("stripe-connect-event", event_id))
    .bind(event_id)
    .bind(event_kind)
    .bind(digest.as_bytes().as_slice())
    .bind(SqlJson(payload))
    .bind(owner_epoch)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("claim Stripe Connect event", error))?;
    let disposition = if inserted.is_some() {
        EventClaim::New
    } else {
        let row = sqlx::query(
            r#"
            SELECT event_kind, payload_digest, payload, status
            FROM rust_coord.external_events
            WHERE source = 'stripe_connect' AND event_id = $1
            FOR UPDATE
            "#,
        )
        .bind(event_id)
        .fetch_one(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("reconcile Stripe Connect event", error))?;
        let persisted_digest: Vec<u8> = row.get("payload_digest");
        let persisted_payload = row.get::<SqlJson<Value>, _>("payload").0;
        if row.get::<String, _>("event_kind") != event_kind
            || persisted_digest.as_slice() != digest.as_bytes()
            || persisted_payload != *payload
        {
            return Err(BillingError::conflict(
                "external_event_conflict",
                "Stripe event id was replayed with different immutable payload",
            ));
        }
        match row.get::<String, _>("status").as_str() {
            "applied" | "ignored" | "rejected" => EventClaim::Terminal,
            "processing" | "failed" | "pending" => EventClaim::Retry,
            _ => {
                return Err(BillingError::internal(
                    "reconcile Stripe Connect event",
                    "invalid persisted event status",
                ));
            }
        }
    };
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))?;
    Ok(disposition)
}

async fn finish_event(
    store: &BillingStore,
    event_id: &str,
    status: &str,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("finish Stripe Connect event").await?;
    let updated = sqlx::query(
        r#"
        UPDATE rust_coord.external_events
        SET status = $2, processed_at = NOW(), updated_at = NOW(), version = version + 1
        WHERE source = 'stripe_connect'
          AND event_id = $1
          AND status IN ('pending', 'processing', 'failed', $2)
        RETURNING external_event_id
        "#,
    )
    .bind(event_id)
    .bind(status)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("finish Stripe Connect event", error))?;
    if updated.is_none() {
        return Err(BillingError::conflict(
            "external_event_conflict",
            "Stripe event reached an incompatible terminal state",
        ));
    }
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

async fn handle_account_updated(store: &BillingStore, event: &Value) -> Result<(), BillingError> {
    let account = StripeAccount::parse(
        event
            .pointer("/data/object")
            .ok_or_else(|| BillingError::bad_request("account.updated omitted data.object"))?,
    )
    .map_err(|error| BillingError::bad_request(error.to_string()))?;
    let owner: Option<String> =
        sqlx::query_scalar("SELECT account_id FROM public.users WHERE stripe_account_id = $1")
            .bind(&account.id)
            .fetch_optional(store.pool())
            .await
            .map_err(|error| BillingError::internal("find Stripe account owner", error))?;
    if let Some(owner) = owner {
        persist_account(store, &owner, &account.id, &account).await?;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PayoutDisposition {
    Paid,
    Failed,
}

#[derive(Debug)]
struct PayoutEvent {
    id: String,
    account: String,
    automatic: bool,
    created: i64,
    failure: String,
}

impl PayoutEvent {
    fn parse(event: &Value) -> Result<Self, BillingError> {
        let object = event
            .pointer("/data/object")
            .and_then(Value::as_object)
            .ok_or_else(|| BillingError::bad_request("payout event omitted data.object"))?;
        let id = object
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| BillingError::bad_request("payout event omitted id"))?
            .to_owned();
        Ok(Self {
            id,
            account: event
                .get("account")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            automatic: object
                .get("automatic")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            created: object.get("created").and_then(Value::as_i64).unwrap_or(0),
            failure: format!(
                "{}: {}",
                object
                    .get("failure_code")
                    .and_then(Value::as_str)
                    .unwrap_or("payout_failed"),
                object
                    .get("failure_message")
                    .and_then(Value::as_str)
                    .unwrap_or("Stripe payout failed")
            ),
        })
    }
}

async fn handle_payout(
    state: &BillingState,
    event_id: &str,
    event: &Value,
    disposition: PayoutDisposition,
) -> Result<(), BillingError> {
    let payout = PayoutEvent::parse(event)?;
    let known = sqlx::query(
        r#"
        SELECT id, status, refunded, payout_id
        FROM public.stripe_withdrawals
        WHERE payout_id = $1
        "#,
    )
    .bind(&payout.id)
    .fetch_optional(state.store.pool())
    .await
    .map_err(|error| BillingError::internal("find payout withdrawal", error))?;
    if let Some(known) = known {
        let withdrawal_id = known.get::<String, _>("id");
        return match disposition {
            PayoutDisposition::Paid => {
                mark_known_payout_paid(
                    &state.store,
                    event_id,
                    &withdrawal_id,
                    &payout.id,
                    &known.get::<String, _>("status"),
                    known.get("refunded"),
                )
                .await
            }
            PayoutDisposition::Failed => {
                reopen_known_payout_failure(
                    &state.store,
                    &withdrawal_id,
                    &payout.id,
                    &payout.failure,
                )
                .await
            }
        };
    }
    if payout.automatic {
        return match disposition {
            PayoutDisposition::Paid => mark_automatic_sweep_paid(state, event_id, &payout).await,
            PayoutDisposition::Failed => {
                reopen_automatic_sweep(&state.store, event_id, &payout).await
            }
        };
    }
    let possibly_racing: bool = sqlx::query_scalar(
        r#"
        SELECT EXISTS (
            SELECT 1
            FROM public.stripe_withdrawals
            WHERE stripe_account_id = $1
              AND method = 'instant'
              AND status = 'transferred'
              AND payout_id = ''
              AND refunded = FALSE
              AND updated_at >= NOW() - INTERVAL '10 minutes'
        )
        "#,
    )
    .bind(&payout.account)
    .fetch_one(state.store.pool())
    .await
    .map_err(|error| BillingError::internal("reconcile unknown payout", error))?;
    if possibly_racing {
        return Err(BillingError::external_unknown(
            "payout may be racing local attachment; request webhook redelivery",
        ));
    }
    Ok(())
}

async fn mark_known_payout_paid(
    store: &BillingStore,
    event_id: &str,
    withdrawal_id: &str,
    payout_id: &str,
    status: &str,
    refunded: bool,
) -> Result<(), BillingError> {
    if status == "paid" {
        return Ok(());
    }
    if refunded || !matches!(status, "pending" | "transferred") {
        tracing::error!(
            withdrawal_id,
            payout_id,
            status,
            refunded,
            "payout paid after withdrawal terminalization; reversal wins"
        );
        return Ok(());
    }
    let expected = if status == "pending" {
        WithdrawalStatus::Pending
    } else {
        WithdrawalStatus::Transferred
    };
    let transition = payout_transition(
        "stripe-payout-paid",
        event_id,
        withdrawal_id,
        expected,
        Some(payout_id),
        None,
        None,
    )?;
    match store
        .ledger()
        .mark_withdrawal(&transition, WithdrawalStatus::Paid)
        .await
    {
        Ok(_) | Err(LedgerError::StaleVersion) => Ok(()),
        Err(error) => Err(BillingError::from_ledger("mark Stripe payout paid", error)),
    }
}

async fn mark_automatic_sweep_paid(
    state: &BillingState,
    event_id: &str,
    payout: &PayoutEvent,
) -> Result<(), BillingError> {
    if payout.account.is_empty() {
        return Ok(());
    }
    let stripe = state
        .stripe
        .as_ref()
        .expect("Stripe client exists while handling signed event");
    let live = stripe
        .payout(&payout.account, &payout.id)
        .await
        .map_err(|error| match error.outcome {
            StripeOutcome::Definitive => BillingError::stripe_unavailable(error.to_string()),
            StripeOutcome::Unknown => BillingError::external_unknown(error.to_string()),
        })?;
    if live.status != "paid" {
        return Ok(());
    }
    let account = stripe
        .account(&payout.account)
        .await
        .map_err(|error| match error.outcome {
            StripeOutcome::Definitive => BillingError::stripe_unavailable(error.to_string()),
            StripeOutcome::Unknown => BillingError::external_unknown(error.to_string()),
        })?;
    let delay = if account.service_agreement
        == required_service_agreement(&stripe.settings().platform_country, &account.country)
        && account.service_agreement == "recipient"
    {
        RECIPIENT_TRANSFER_DELAY_SECONDS
    } else {
        0
    };
    let created = if payout.created > 0 {
        payout.created
    } else {
        i64::MAX
    };
    let rows = sqlx::query(
        r#"
        SELECT id
        FROM public.stripe_withdrawals
        WHERE stripe_account_id = $1
          AND status = 'transferred'
          AND payout_id = ''
          AND refunded = FALSE
          AND updated_at <= to_timestamp($2) - make_interval(secs => $3::DOUBLE PRECISION)
        ORDER BY updated_at, id
        LIMIT 1000
        "#,
    )
    .bind(&payout.account)
    .bind(created)
    .bind(delay)
    .fetch_all(state.store.pool())
    .await
    .map_err(|error| BillingError::internal("list automatic sweep withdrawals", error))?;
    for row in rows {
        let withdrawal_id = row.get::<String, _>("id");
        let transition = payout_transition(
            "stripe-sweep-paid",
            event_id,
            &withdrawal_id,
            WithdrawalStatus::Transferred,
            None,
            Some(&payout.id),
            None,
        )?;
        match state.store.ledger().mark_sweep_paid(&transition).await {
            Ok(_) | Err(LedgerError::StaleVersion | LedgerError::OperationConflict) => {}
            Err(error) => {
                return Err(BillingError::from_ledger(
                    "mark automatic Stripe sweep paid",
                    error,
                ));
            }
        }
    }
    Ok(())
}

async fn reopen_automatic_sweep(
    store: &BillingStore,
    event_id: &str,
    payout: &PayoutEvent,
) -> Result<(), BillingError> {
    record_sweep_tombstone(store, &payout.id, &payout.failure).await?;
    let rows = sqlx::query(
        r#"
        SELECT id
        FROM public.stripe_withdrawals
        WHERE sweep_payout_id = $1 AND status = 'paid' AND refunded = FALSE
        ORDER BY id
        "#,
    )
    .bind(&payout.id)
    .fetch_all(store.pool())
    .await
    .map_err(|error| BillingError::internal("list bounced sweep withdrawals", error))?;
    for row in rows {
        let withdrawal_id = row.get::<String, _>("id");
        let transition = payout_transition(
            "stripe-sweep-failed",
            event_id,
            &withdrawal_id,
            WithdrawalStatus::Paid,
            None,
            Some(&payout.id),
            Some(&payout.failure),
        )?;
        match store.ledger().reopen_failed_sweep(&transition).await {
            Ok(_) | Err(LedgerError::StaleVersion) => {}
            Err(error) => {
                return Err(BillingError::from_ledger(
                    "reopen bounced Stripe sweep",
                    error,
                ));
            }
        }
    }
    Ok(())
}

async fn record_sweep_tombstone(
    store: &BillingStore,
    payout_id: &str,
    failure: &str,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("record Stripe sweep failure").await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(format!("stripe-sweep:{payout_id}"))
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("lock Stripe sweep failure", error))?;
    sqlx::query(
        r#"
        INSERT INTO public.stripe_sweep_failures (payout_id, failure_reason)
        VALUES ($1, $2)
        ON CONFLICT (payout_id) DO UPDATE
        SET failure_reason = EXCLUDED.failure_reason
        "#,
    )
    .bind(payout_id)
    .bind(failure)
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("record Stripe sweep failure", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

async fn reopen_known_payout_failure(
    store: &BillingStore,
    withdrawal_id: &str,
    payout_id: &str,
    failure: &str,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("reopen failed Stripe payout").await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(format!("stripe-withdrawal:{withdrawal_id}"))
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("lock failed Stripe payout", error))?;
    let row = sqlx::query(
        r#"
        SELECT
            account_id, status, refunded, fee_refunded, fee_micro_usd,
            amount_micro_usd, net_micro_usd
        FROM public.stripe_withdrawals
        WHERE id = $1 AND payout_id = $2
        FOR UPDATE
        "#,
    )
    .bind(withdrawal_id)
    .bind(payout_id)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("read failed Stripe payout", error))?;
    let Some(row) = row else {
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish stale payout failure", error))?;
        return Ok(());
    };
    if row.get::<bool, _>("refunded") {
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish refunded payout failure", error))?;
        return Ok(());
    }
    let status = row.get::<String, _>("status");
    if !matches!(status.as_str(), "transferred" | "paid") {
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish terminal payout failure", error))?;
        return Ok(());
    }
    let fee = row.get::<i64, _>("fee_micro_usd");
    let fee_refunded = row.get::<bool, _>("fee_refunded");
    if fee > 0 && !fee_refunded {
        credit_withdrawable_in_transaction(
            transaction.connection(),
            &row.get::<String, _>("account_id"),
            fee,
            "refund",
            &format!("stripe_withdraw_fee:{withdrawal_id}"),
        )
        .await?;
    }
    sqlx::query(
        r#"
        UPDATE public.stripe_withdrawals
        SET status = 'transferred',
            payout_id = '',
            fee_refunded = fee_refunded OR fee_micro_usd > 0,
            failure_reason = $3,
            updated_at = NOW()
        WHERE id = $1 AND payout_id = $2 AND refunded = FALSE
        "#,
    )
    .bind(withdrawal_id)
    .bind(payout_id)
    .bind(failure)
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("reopen failed Stripe payout", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

async fn handle_transfer_reversal(
    store: &BillingStore,
    event_id: &str,
    event: &Value,
) -> Result<(), BillingError> {
    let object = event
        .pointer("/data/object")
        .and_then(Value::as_object)
        .ok_or_else(|| BillingError::bad_request("transfer event omitted data.object"))?;
    let transfer_id = object
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| BillingError::bad_request("transfer event omitted id"))?;
    let fully_reversed = object
        .get("reversed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let amount = object.get("amount").and_then(Value::as_i64).unwrap_or(0);
    let amount_reversed = object
        .get("amount_reversed")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    reverse_transfer(
        store,
        event_id,
        transfer_id,
        fully_reversed && amount > 0 && amount_reversed == amount,
    )
    .await
}

pub(super) async fn reconcile_recorded_transfer_reversals(
    store: &BillingStore,
    transfer_id: &str,
) -> Result<bool, BillingError> {
    let events = sqlx::query(
        r#"
        SELECT event_id, payload
        FROM rust_coord.external_events
        WHERE source = 'stripe_connect'
          AND event_kind = 'transfer.reversed'
          AND payload #>> '{data,object,id}' = $1
        ORDER BY received_at, event_id
        "#,
    )
    .bind(transfer_id)
    .fetch_all(store.pool())
    .await
    .map_err(|error| BillingError::internal("reconcile early transfer reversal", error))?;
    for event in events {
        handle_transfer_reversal(
            store,
            &event.get::<String, _>("event_id"),
            &event.get::<SqlJson<Value>, _>("payload").0,
        )
        .await?;
    }
    let terminal: Option<(String, bool)> = sqlx::query_as(
        r#"
        SELECT status, refunded
        FROM public.stripe_withdrawals
        WHERE transfer_id = $1
        "#,
    )
    .bind(transfer_id)
    .fetch_optional(store.pool())
    .await
    .map_err(|error| BillingError::internal("read reconciled transfer status", error))?;
    Ok(terminal.is_some_and(|(status, refunded)| {
        refunded || !matches!(status.as_str(), "pending" | "transferred")
    }))
}

async fn reverse_transfer(
    store: &BillingStore,
    event_id: &str,
    transfer_id: &str,
    fully_reversed: bool,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("reverse Stripe transfer").await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(format!("stripe-transfer:{transfer_id}"))
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("lock Stripe transfer reversal", error))?;
    let row = sqlx::query(
        r#"
        SELECT
            id, account_id, status, refunded, fee_refunded,
            amount_micro_usd, fee_micro_usd, net_micro_usd
        FROM public.stripe_withdrawals
        WHERE transfer_id = $1
        FOR UPDATE
        "#,
    )
    .bind(transfer_id)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("find reversed Stripe transfer", error))?;
    let Some(row) = row else {
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish unknown transfer reversal", error))?;
        return Ok(());
    };
    let withdrawal_id = row.get::<String, _>("id");
    if row.get::<bool, _>("refunded") {
        sqlx::query(
            "UPDATE public.stripe_withdrawals SET status = 'failed', updated_at = NOW() WHERE id = $1",
        )
        .bind(&withdrawal_id)
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("terminalize refunded withdrawal", error))?;
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        return Ok(());
    }
    let status = row.get::<String, _>("status");
    if !fully_reversed || status == "paid" {
        sqlx::query(
            r#"
            UPDATE public.stripe_withdrawals
            SET status = 'review_pending',
                failure_reason = $2,
                updated_at = NOW()
            WHERE id = $1 AND refunded = FALSE
            "#,
        )
        .bind(&withdrawal_id)
        .bind(if fully_reversed {
            "transfer_reversed_after_paid"
        } else {
            "partial_transfer_reversal"
        })
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("mark reversal for review", error))?;
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        return Ok(());
    }
    if !matches!(status.as_str(), "pending" | "transferred") {
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish terminal reversal", error))?;
        return Ok(());
    }
    let amount = row.get::<i64, _>("amount_micro_usd");
    let fee = row.get::<i64, _>("fee_micro_usd");
    let net = row.get::<i64, _>("net_micro_usd");
    let fee_refunded = row.get::<bool, _>("fee_refunded");
    if amount <= 0 || fee < 0 || net < 0 || fee.checked_add(net) != Some(amount) {
        return Err(BillingError::internal(
            "reverse Stripe transfer",
            "withdrawal amount provenance is invalid",
        ));
    }
    let account_id = row.get::<String, _>("account_id");
    credit_withdrawable_in_transaction(
        transaction.connection(),
        &account_id,
        net,
        "refund",
        &format!("stripe_withdraw_principal:{withdrawal_id}:{event_id}"),
    )
    .await?;
    if fee > 0 && !fee_refunded {
        credit_withdrawable_in_transaction(
            transaction.connection(),
            &account_id,
            fee,
            "refund",
            &format!("stripe_withdraw_fee:{withdrawal_id}"),
        )
        .await?;
    }
    sqlx::query(
        r#"
        UPDATE public.stripe_withdrawals
        SET status = 'failed',
            refunded = TRUE,
            fee_refunded = TRUE,
            failure_reason = 'transfer_reversed',
            updated_at = NOW()
        WHERE id = $1 AND refunded = FALSE
        "#,
    )
    .bind(&withdrawal_id)
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("terminalize reversed transfer", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

async fn credit_withdrawable_in_transaction(
    connection: &mut sqlx::PgConnection,
    account_id: &str,
    amount: i64,
    entry_type: &str,
    reference: &str,
) -> Result<(), BillingError> {
    if amount == 0 {
        return Ok(());
    }
    if amount < 0 {
        return Err(BillingError::internal(
            "credit withdrawal reversal",
            "negative reversal credit",
        ));
    }
    let existing: bool = sqlx::query_scalar(
        r#"
        SELECT EXISTS (
            SELECT 1 FROM public.ledger_entries
            WHERE account_id = $1 AND entry_type = $2 AND reference = $3
        )
        "#,
    )
    .bind(account_id)
    .bind(entry_type)
    .bind(reference)
    .fetch_one(&mut *connection)
    .await
    .map_err(|error| BillingError::internal("reconcile reversal credit", error))?;
    if existing {
        return Ok(());
    }
    let balance = sqlx::query(
        r#"
        SELECT balance_micro_usd, withdrawable_micro_usd
        FROM public.balances
        WHERE account_id = $1
        FOR UPDATE
        "#,
    )
    .bind(account_id)
    .fetch_one(&mut *connection)
    .await
    .map_err(|error| BillingError::internal("lock reversal balance", error))?;
    let total = balance.get::<i64, _>("balance_micro_usd");
    let withdrawable = balance.get::<i64, _>("withdrawable_micro_usd");
    validate_balance(total, withdrawable)?;
    let next_total = total
        .checked_add(amount)
        .ok_or_else(|| BillingError::bad_request("reversal credit overflows balance"))?;
    let next_withdrawable = withdrawable
        .checked_add(amount)
        .ok_or_else(|| BillingError::bad_request("reversal credit overflows balance"))?;
    validate_balance(next_total, next_withdrawable)?;
    sqlx::query(
        r#"
        UPDATE public.balances
        SET balance_micro_usd = $2,
            withdrawable_micro_usd = $3,
            updated_at = NOW()
        WHERE account_id = $1
        "#,
    )
    .bind(account_id)
    .bind(next_total)
    .bind(next_withdrawable)
    .execute(&mut *connection)
    .await
    .map_err(|error| BillingError::internal("apply reversal credit", error))?;
    sqlx::query(
        r#"
        INSERT INTO public.ledger_entries (
            account_id, entry_type, amount_micro_usd, balance_after, reference
        )
        VALUES ($1, $2, $3, $4, $5)
        "#,
    )
    .bind(account_id)
    .bind(entry_type)
    .bind(amount)
    .bind(next_total)
    .bind(reference)
    .execute(&mut *connection)
    .await
    .map_err(|error| BillingError::internal("record reversal credit", error))?;
    Ok(())
}

fn payout_transition(
    domain: &str,
    event_id: &str,
    withdrawal_id: &str,
    expected_status: WithdrawalStatus,
    payout_id: Option<&str>,
    sweep_payout_id: Option<&str>,
    failure_reason: Option<&str>,
) -> Result<WithdrawalTransition, BillingError> {
    let payload = json!({
        "event_id": event_id,
        "withdrawal_id": withdrawal_id,
        "payout_id": payout_id,
        "sweep_payout_id": sweep_payout_id,
        "failure_reason": failure_reason,
    });
    let digest = canonical_json_digest(&payload)
        .map_err(|error| BillingError::from_ledger("digest payout transition", error))?;
    let suffix = super::auth::operation_suffix(withdrawal_id, event_id);
    Ok(WithdrawalTransition {
        operation: Operation {
            id: OperationId::random(),
            key: OperationKey::new(format!("{domain}:{suffix}"))
                .map_err(|error| BillingError::bad_request(error.to_string()))?,
            digest: event_operation_digest(domain, event_id, digest),
        },
        withdrawal_id: WithdrawalId::new(withdrawal_id)
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        expected_status,
        transfer_id: None,
        payout_id: payout_id
            .map(ExternalId::new)
            .transpose()
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        sweep_payout_id: sweep_payout_id
            .map(ExternalId::new)
            .transpose()
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        failure_reason: failure_reason.map(Arc::from),
    })
}
