use std::sync::Arc;

use axum::{
    Json,
    extract::{Request, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};
use sqlx::Row;

use crate::ledger::{
    ExternalId, LedgerAmount, LedgerError, Operation, OperationId, OperationKey, OutboxId,
    WithdrawalId, WithdrawalRequest, WithdrawalStatus, WithdrawalTransition, canonical_json_digest,
};

use super::{
    auth::{idempotency_key, operation_suffix, privy_principal},
    body,
    checkout::{deterministic_uuid, event_operation_digest},
    connect::map_stripe,
    error::BillingError,
    money::{format_usd, parse_usd, withdrawal_amounts},
    state::BillingState,
    store::{BillingStore, validate_balance},
    stripe::{StripeOutcome, required_service_agreement},
    webhook::reconcile_recorded_transfer_reversals,
};

pub(super) async fn withdraw(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let principal = privy_principal(&request)?.clone();
    let idempotency = idempotency_key(request.headers(), true)?
        .expect("required idempotency key")
        .to_owned();
    let payload: Value = body::json(request).await?;
    let amount = parse_usd(body::required_string(&payload, "amount_usd")?)?;
    let method = body::optional_string(&payload, "method")
        .trim()
        .to_ascii_lowercase();
    let method = if method.is_empty() {
        "standard".to_owned()
    } else {
        method
    };
    if !matches!(method.as_str(), "standard" | "instant") {
        return Err(BillingError::bad_request(
            "method must be standard or instant",
        ));
    }
    let (fee, net, cents) = withdrawal_amounts(amount, method == "instant")?;
    let stripe = state
        .stripe
        .as_ref()
        .ok_or_else(|| BillingError::unavailable("Stripe Connect is not configured"))?
        .clone();
    let user = state.store.user(principal.account_id()).await?;
    if user.stripe_account_id.is_empty() || user.stripe_account_status != "ready" {
        return Err(BillingError::forbidden(
            "complete Stripe payout onboarding before withdrawing",
        ));
    }
    let account = stripe
        .account(&user.stripe_account_id)
        .await
        .map_err(map_stripe)?;
    if !account.payouts_enabled {
        return Err(BillingError::forbidden(
            "Stripe payout account is not ready",
        ));
    }
    let required_agreement =
        required_service_agreement(&stripe.settings().platform_country, &account.country);
    if account.service_agreement != required_agreement {
        return Err(BillingError::conflict(
            "stripe_account_recreate_required",
            "Stripe payout account has an incompatible service agreement",
        ));
    }
    if account.payout_interval == "manual" {
        stripe
            .ensure_automatic_schedule(&account.id, &account.country)
            .await
            .map_err(map_stripe)?;
    }
    if method == "instant" && !account.instant_eligible && !user.stripe_instant_eligible {
        return Err(BillingError::bad_request(
            "instant payouts require an eligible debit card",
        ));
    }
    let suffix = operation_suffix(principal.account_id(), &idempotency);
    let withdrawal_id = format!("wd_{suffix}");
    let transfer_key = format!("wd-tr-{suffix}");
    let payout_key = format!("wd-po-{suffix}");
    let external_payload = json!({
        "withdrawal_id": withdrawal_id,
        "account_id": principal.account_id(),
        "stripe_account_id": user.stripe_account_id,
        "gross_micro_usd": amount,
        "fee_micro_usd": fee,
        "net_micro_usd": net,
        "amount_cents": cents,
        "method": method,
        "transfer_idempotency_key": transfer_key,
        "payout_idempotency_key": if method == "instant" { payout_key.as_str() } else { "" },
    });
    let payload_digest = canonical_json_digest(&external_payload)
        .map_err(|error| BillingError::from_ledger("digest withdrawal intent", error))?;
    let operation_key = format!("withdrawal-intent:{suffix}");
    let create = WithdrawalRequest {
        operation: Operation {
            id: OperationId::random(),
            key: OperationKey::new(operation_key)
                .map_err(|error| BillingError::bad_request(error.to_string()))?,
            digest: event_operation_digest("withdrawal-intent", &suffix, payload_digest),
        },
        outbox_id: OutboxId::new(deterministic_uuid("withdrawal-outbox", &suffix))
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        withdrawal_id: WithdrawalId::new(withdrawal_id.clone())
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        account_id: crate::ledger::AccountId::new(principal.account_id())
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        stripe_account_id: ExternalId::new(user.stripe_account_id.as_str())
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        amount: LedgerAmount::from_i64(amount)
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        fee: LedgerAmount::from_i64(fee)
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        method: Arc::from(method.as_str()),
        payload_digest,
        external_payload,
    };
    if let Err(error) = state.store.ledger().create_withdrawal(&create).await {
        return match error {
            LedgerError::CommitOutcomeUnknown { .. } | LedgerError::Timeout => {
                Ok(external_unknown(
                    &withdrawal_id,
                    "withdrawal durable commit outcome is unknown",
                ))
            }
            error => Err(BillingError::from_ledger("create withdrawal", error)),
        };
    }
    let transfer = match stripe
        .create_transfer(&user.stripe_account_id, cents, &transfer_key)
        .await
    {
        Ok(transfer) => transfer,
        Err(error) if error.outcome == StripeOutcome::Unknown => {
            return Ok(external_unknown(
                &withdrawal_id,
                "Stripe transfer outcome is unknown; retry with the same Idempotency-Key",
            ));
        }
        Err(error) => {
            refund_definitive_transfer_failure(
                &state.store,
                &withdrawal_id,
                &suffix,
                &error.to_string(),
            )
            .await?;
            return Err(BillingError::stripe_unavailable(format!(
                "Stripe rejected the transfer; the withdrawal was refunded ({error})"
            )));
        }
    };
    let transferred = WithdrawalTransition {
        operation: transition_operation(
            "withdrawal-transfer",
            &suffix,
            &withdrawal_id,
            &transfer.id,
        )?,
        withdrawal_id: WithdrawalId::new(withdrawal_id.clone())
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        expected_status: WithdrawalStatus::Pending,
        transfer_id: Some(
            ExternalId::new(transfer.id.as_str())
                .map_err(|error| BillingError::bad_request(error.to_string()))?,
        ),
        payout_id: None,
        sweep_payout_id: None,
        failure_reason: None,
    };
    if let Err(error) = state
        .store
        .ledger()
        .mark_withdrawal(&transferred, WithdrawalStatus::Transferred)
        .await
    {
        return match error {
            LedgerError::CommitOutcomeUnknown { .. } | LedgerError::Timeout => {
                Ok(external_unknown(
                    &withdrawal_id,
                    "transfer succeeded but local status is unknown",
                ))
            }
            error => Err(BillingError::from_ledger("persist Stripe transfer", error)),
        };
    }
    if reconcile_recorded_transfer_reversals(&state.store, &transfer.id).await? {
        mark_outbox_delivered(&state.store, &withdrawal_id).await?;
        return Err(BillingError::stripe_unavailable(
            "Stripe reversed the transfer before payout submission; the withdrawal was refunded",
        ));
    }
    if method == "standard" {
        mark_outbox_delivered(&state.store, &withdrawal_id).await?;
        return Ok(Json(json!({
            "status": "transferred",
            "withdrawal_id": withdrawal_id,
            "transfer_id": transfer.id,
            "amount_usd": format_usd(amount),
            "fee_usd": format_usd(fee),
            "net_usd": format_usd(net),
            "method": method,
            "message": "funds were transferred to Stripe and will be delivered by the automatic payout schedule",
            "balance": state.store.balance(principal.account_id()).await?,
        }))
        .into_response());
    }
    let payout = match stripe
        .create_payout(&user.stripe_account_id, cents, &payout_key)
        .await
    {
        Ok(payout) => payout,
        Err(error) if error.outcome == StripeOutcome::Unknown => {
            return Ok(external_unknown(
                &withdrawal_id,
                "Stripe instant payout outcome is unknown; no fee was refunded",
            ));
        }
        Err(error) => {
            refund_instant_fee(&state.store, &withdrawal_id, &error.to_string()).await?;
            mark_outbox_delivered(&state.store, &withdrawal_id).await?;
            return Ok((
                StatusCode::ACCEPTED,
                Json(json!({
                    "status": "transferred",
                    "withdrawal_id": withdrawal_id,
                    "transfer_id": transfer.id,
                    "method": method,
                    "message": "instant payout was rejected; its fee was refunded and the automatic payout schedule will deliver the funds",
                    "balance": state.store.balance(principal.account_id()).await?,
                })),
            )
                .into_response());
        }
    };
    attach_payout(&state.store, &withdrawal_id, &transfer.id, &payout.id).await?;
    mark_outbox_delivered(&state.store, &withdrawal_id).await?;
    Ok(Json(json!({
        "status": "submitted",
        "withdrawal_id": withdrawal_id,
        "transfer_id": transfer.id,
        "payout_id": payout.id,
        "payout_status": payout.status,
        "arrival_unix": payout.arrival_date,
        "amount_usd": format_usd(amount),
        "fee_usd": format_usd(fee),
        "net_usd": format_usd(net),
        "method": method,
        "balance": state.store.balance(principal.account_id()).await?,
    }))
    .into_response())
}

async fn refund_definitive_transfer_failure(
    store: &BillingStore,
    withdrawal_id: &str,
    suffix: &str,
    reason: &str,
) -> Result<(), BillingError> {
    let transition = WithdrawalTransition {
        operation: transition_operation(
            "withdrawal-transfer-rejected",
            suffix,
            withdrawal_id,
            reason,
        )?,
        withdrawal_id: WithdrawalId::new(withdrawal_id)
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        expected_status: WithdrawalStatus::Pending,
        transfer_id: None,
        payout_id: None,
        sweep_payout_id: None,
        failure_reason: Some(Arc::from(reason)),
    };
    store
        .ledger()
        .reverse_withdrawal(&transition)
        .await
        .map_err(|error| BillingError::from_ledger("refund rejected Stripe transfer", error))?;
    Ok(())
}

fn transition_operation(
    domain: &str,
    suffix: &str,
    withdrawal_id: &str,
    external_fact: &str,
) -> Result<Operation, BillingError> {
    let payload = json!({
        "withdrawal_id": withdrawal_id,
        "external_fact": external_fact,
    });
    let payload_digest = canonical_json_digest(&payload)
        .map_err(|error| BillingError::from_ledger("digest withdrawal transition", error))?;
    Ok(Operation {
        id: OperationId::random(),
        key: OperationKey::new(format!("{domain}:{suffix}"))
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        digest: event_operation_digest(domain, suffix, payload_digest),
    })
}

pub(super) async fn attach_payout(
    store: &BillingStore,
    withdrawal_id: &str,
    transfer_id: &str,
    payout_id: &str,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("attach Stripe payout").await?;
    let attached = sqlx::query(
        r#"
        UPDATE public.stripe_withdrawals
        SET payout_id = $3, updated_at = NOW()
        WHERE id = $1
          AND transfer_id = $2
          AND status = 'transferred'
          AND refunded = FALSE
          AND (payout_id = '' OR payout_id = $3)
        RETURNING id
        "#,
    )
    .bind(withdrawal_id)
    .bind(transfer_id)
    .bind(payout_id)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("attach Stripe payout", error))?;
    if attached.is_none() {
        return Err(BillingError::conflict(
            "withdrawal_state_conflict",
            "withdrawal was terminalized before its payout could be attached",
        ));
    }
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

pub(super) async fn refund_instant_fee(
    store: &BillingStore,
    withdrawal_id: &str,
    failure_reason: &str,
) -> Result<bool, BillingError> {
    let mut transaction = store.begin("refund instant payout fee").await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(format!("stripe-withdrawal:{withdrawal_id}"))
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("lock instant fee refund", error))?;
    let withdrawal = sqlx::query(
        r#"
        SELECT
            account_id, fee_micro_usd, status, refunded, fee_refunded,
            amount_micro_usd, net_micro_usd
        FROM public.stripe_withdrawals
        WHERE id = $1
        FOR UPDATE
        "#,
    )
    .bind(withdrawal_id)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("read instant fee refund", error))?
    .ok_or_else(|| BillingError::not_found("withdrawal was not found"))?;
    if withdrawal.get::<bool, _>("refunded")
        || withdrawal.get::<bool, _>("fee_refunded")
        || withdrawal.get::<i64, _>("fee_micro_usd") == 0
    {
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish instant fee replay", error))?;
        return Ok(false);
    }
    if withdrawal.get::<String, _>("status") != "transferred" {
        return Err(BillingError::conflict(
            "withdrawal_state_conflict",
            "instant fee can be refunded only while funds remain at Stripe",
        ));
    }
    let account_id = withdrawal.get::<String, _>("account_id");
    let fee = withdrawal.get::<i64, _>("fee_micro_usd");
    let amount = withdrawal.get::<i64, _>("amount_micro_usd");
    let net = withdrawal.get::<i64, _>("net_micro_usd");
    if fee <= 0 || net < 0 || fee.checked_add(net) != Some(amount) {
        return Err(BillingError::internal(
            "refund instant payout fee",
            "withdrawal fee provenance is invalid",
        ));
    }
    let balance = sqlx::query(
        r#"
        SELECT balance_micro_usd, withdrawable_micro_usd
        FROM public.balances
        WHERE account_id = $1
        FOR UPDATE
        "#,
    )
    .bind(&account_id)
    .fetch_one(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("lock instant fee balance", error))?;
    let total = balance.get::<i64, _>("balance_micro_usd");
    let withdrawable = balance.get::<i64, _>("withdrawable_micro_usd");
    validate_balance(total, withdrawable)?;
    let next_total = total
        .checked_add(fee)
        .ok_or_else(|| BillingError::bad_request("instant fee refund overflows balance"))?;
    let next_withdrawable = withdrawable.checked_add(fee).ok_or_else(|| {
        BillingError::bad_request("instant fee refund overflows withdrawable balance")
    })?;
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
    .bind(&account_id)
    .bind(next_total)
    .bind(next_withdrawable)
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("apply instant fee refund", error))?;
    sqlx::query(
        r#"
        INSERT INTO public.ledger_entries (
            account_id, entry_type, amount_micro_usd, balance_after, reference
        )
        VALUES ($1, 'refund', $2, $3, $4)
        "#,
    )
    .bind(&account_id)
    .bind(fee)
    .bind(next_total)
    .bind(format!("stripe_withdraw_fee:{withdrawal_id}"))
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("record instant fee refund", error))?;
    sqlx::query(
        r#"
        UPDATE public.stripe_withdrawals
        SET fee_refunded = TRUE,
            payout_id = '',
            failure_reason = $2,
            updated_at = NOW()
        WHERE id = $1 AND status = 'transferred' AND refunded = FALSE
        "#,
    )
    .bind(withdrawal_id)
    .bind(failure_reason)
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("finish instant fee refund", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))?;
    Ok(true)
}

pub(super) async fn mark_outbox_delivered(
    store: &BillingStore,
    withdrawal_id: &str,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("complete Stripe external operation").await?;
    sqlx::query(
        r#"
        UPDATE rust_coord.outbox
        SET status = 'delivered', delivered_at = NOW(), updated_at = NOW()
        WHERE operation_key = 'withdrawal-call:' || $1
          AND status IN ('pending', 'processing', 'delivered')
        "#,
    )
    .bind(withdrawal_id)
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("complete Stripe external operation", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

fn external_unknown(withdrawal_id: &str, message: &str) -> Response {
    (
        StatusCode::ACCEPTED,
        Json(json!({
            "error": {
                "type": "server_error",
                "code": "external_unknown",
                "message": message,
            },
            "withdrawal_id": withdrawal_id,
        })),
    )
        .into_response()
}
