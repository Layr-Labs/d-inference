use std::sync::Arc;

use axum::{
    Json,
    extract::{Request, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use darkbloom_coordinator_core::ids::Digest;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use sqlx::{Row, types::Json as SqlJson};
use uuid::Uuid;

use crate::ledger::{
    ExternalEventId, ExternalId, LedgerAmount, LedgerError, MutationDisposition, Operation,
    OperationId, OperationKey, StripeDeposit, canonical_json_digest,
};

use super::{
    auth::{idempotency_key, operation_suffix, principal, validate_identifier},
    body,
    error::BillingError,
    money::{deposit_cents, format_usd, parse_usd},
    state::BillingState,
    store::{BillingStore, ensure_balance_row, query_parameter},
};

pub(super) async fn create_session(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let principal = principal(&request)?.clone();
    let idempotency = idempotency_key(request.headers(), true)?
        .expect("required idempotency key")
        .to_owned();
    let payload: Value = body::json(request).await?;
    let amount_text = body::required_string(&payload, "amount_usd")?;
    let amount = parse_usd(amount_text)?;
    let cents = deposit_cents(amount)?;
    let referral_code = body::optional_string(&payload, "referral_code")
        .trim()
        .to_ascii_uppercase();
    let email = payload
        .get("email")
        .and_then(Value::as_str)
        .unwrap_or_else(|| principal.email())
        .trim()
        .to_owned();
    if email.len() > 256 || email.chars().any(char::is_control) {
        return Err(BillingError::bad_request("email is invalid"));
    }
    let session_id = deterministic_uuid(
        "checkout-session",
        &format!("{}:{idempotency}", principal.account_id()),
    )
    .to_string();
    create_local_session(
        &state.store,
        &session_id,
        principal.account_id(),
        amount,
        &referral_code,
    )
    .await?;
    let stripe = state
        .stripe
        .as_ref()
        .ok_or_else(|| BillingError::unavailable("Stripe deposits are not configured"))?;
    let stripe_idempotency = format!(
        "checkout-{}",
        operation_suffix(principal.account_id(), &idempotency)
    );
    let checkout = stripe
        .create_checkout(
            cents,
            &email,
            &session_id,
            principal.account_id(),
            &referral_code,
            &stripe_idempotency,
        )
        .await
        .map_err(|error| match error.outcome {
            super::stripe::StripeOutcome::Definitive => {
                BillingError::stripe_unavailable(error.to_string())
            }
            super::stripe::StripeOutcome::Unknown => BillingError::stripe_unknown(format!(
                "Stripe checkout outcome is unknown; retry with the same Idempotency-Key ({error})"
            )),
        })?;
    bind_checkout_session(&state.store, &session_id, &checkout.id).await?;
    Ok(Json(json!({
        "session_id": session_id,
        "stripe_session": checkout.id,
        "url": checkout.url,
        "amount_usd": format_usd(amount),
        "amount_micro_usd": amount,
    }))
    .into_response())
}

pub(super) async fn webhook(
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
        .ok_or_else(|| BillingError::unavailable("Stripe deposits are not configured"))?
        .clone();
    let raw = body::raw(request).await?;
    let event = stripe.verify_checkout(&raw, &signature)?;
    let event_id = required_event_string(&event, "id")?.to_owned();
    let event_type = required_event_string(&event, "type")?.to_owned();
    if event_type != "checkout.session.completed" {
        record_external_event(
            &state.store,
            "stripe",
            &event_id,
            &event_type,
            &event,
            "ignored",
        )
        .await?;
        return Ok(StatusCode::OK.into_response());
    }
    let session = event
        .pointer("/data/object")
        .and_then(Value::as_object)
        .ok_or_else(|| BillingError::bad_request("Stripe checkout event omitted data.object"))?;
    if session.get("payment_status").and_then(Value::as_str) != Some("paid") {
        return Err(BillingError::bad_request(
            "Stripe checkout event is not paid",
        ));
    }
    let checkout_session_id = session
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| BillingError::bad_request("Stripe checkout event omitted session id"))?
        .to_owned();
    let billing_session_id = session
        .get("metadata")
        .and_then(Value::as_object)
        .and_then(|metadata| metadata.get("billing_session_id"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            BillingError::bad_request("Stripe checkout event omitted billing_session_id metadata")
        })?
        .to_owned();
    let amount_cents = session
        .get("amount_total")
        .and_then(Value::as_i64)
        .filter(|amount| *amount > 0)
        .ok_or_else(|| BillingError::bad_request("Stripe checkout amount is invalid"))?;
    let amount = amount_cents
        .checked_mul(10_000)
        .ok_or_else(|| BillingError::bad_request("Stripe checkout amount overflows micro-USD"))?;
    let currency = session
        .get("currency")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let payload_digest = canonical_json_digest(&event)
        .map_err(|error| BillingError::from_ledger("digest Stripe event", error))?;
    let operation_digest = event_operation_digest("stripe-checkout", &event_id, payload_digest);
    let deposit = StripeDeposit {
        operation: Operation {
            id: OperationId::random(),
            key: OperationKey::new(format!("stripe-checkout:{event_id}"))
                .map_err(|error| BillingError::bad_request(error.to_string()))?,
            digest: operation_digest,
        },
        external_event_id: ExternalEventId::new(deterministic_uuid("stripe-event", &event_id))
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        event_id: ExternalId::new(event_id.clone())
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        checkout_session_id: ExternalId::new(checkout_session_id.clone())
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        billing_session_id: ExternalId::new(billing_session_id.clone())
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
        payload_digest,
        payload: event,
        currency: Arc::from(currency),
        amount: LedgerAmount::from_i64(amount)
            .map_err(|error| BillingError::bad_request(error.to_string()))?,
    };
    match state.store.ledger().deposit(&deposit).await {
        Ok(result) => {
            let replayed = result.disposition == MutationDisposition::Replayed;
            Ok(Json(json!({
                "received": true,
                "replayed": replayed,
                "account_id": result.account_id.as_str(),
                "amount_micro_usd": result.amount.as_i64(),
            }))
            .into_response())
        }
        Err(LedgerError::OperationConflict | LedgerError::NotFound) => {
            tracing::warn!(
                event_id,
                billing_session_id,
                checkout_session_id,
                "Stripe deposit was rejected without credit"
            );
            Ok(Json(json!({"received": true, "rejected": true})).into_response())
        }
        Err(error) => Err(BillingError::from_ledger("apply Stripe deposit", error)),
    }
}

pub(super) async fn session_status(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let principal = principal(&request)?;
    let session_id = query_parameter(request.uri().query(), "id")
        .ok_or_else(|| BillingError::bad_request("id query parameter is required"))?;
    validate_identifier(&session_id, "billing session id")?;
    Ok(Json(
        state
            .store
            .session(&session_id, principal.account_id(), principal.is_admin())
            .await?,
    )
    .into_response())
}

async fn create_local_session(
    store: &BillingStore,
    session_id: &str,
    account_id: &str,
    amount: i64,
    referral_code: &str,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("create billing session").await?;
    if !referral_code.is_empty() {
        let valid: bool =
            sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM public.referrers WHERE code = $1)")
                .bind(referral_code)
                .fetch_one(transaction.connection())
                .await
                .map_err(|error| BillingError::internal("validate checkout referral", error))?;
        if !valid {
            return Err(BillingError::bad_request("invalid referral code"));
        }
    }
    ensure_balance_row(transaction.connection(), account_id).await?;
    let existing = sqlx::query(
        r#"
        SELECT account_id, amount_micro_usd, referral_code, payment_method, currency
        FROM public.billing_sessions
        WHERE id = $1
        FOR UPDATE
        "#,
    )
    .bind(session_id)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("reconcile billing session", error))?;
    if let Some(existing) = existing {
        let matches = existing.get::<String, _>("account_id") == account_id
            && existing.get::<i64, _>("amount_micro_usd") == amount
            && existing.get::<String, _>("referral_code") == referral_code
            && existing.get::<String, _>("payment_method") == "stripe"
            && existing
                .get::<String, _>("currency")
                .eq_ignore_ascii_case("usd");
        if !matches {
            return Err(BillingError::conflict(
                "idempotency_conflict",
                "Idempotency-Key was already used with different checkout terms",
            ));
        }
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish checkout replay", error))?;
        return Ok(());
    }
    sqlx::query(
        r#"
        INSERT INTO public.billing_sessions (
            id, account_id, payment_method, currency, amount_micro_usd,
            status, referral_code
        )
        VALUES ($1, $2, 'stripe', 'usd', $3, 'pending', $4)
        "#,
    )
    .bind(session_id)
    .bind(account_id)
    .bind(amount)
    .bind(referral_code)
    .execute(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("create billing session", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

async fn bind_checkout_session(
    store: &BillingStore,
    session_id: &str,
    external_id: &str,
) -> Result<(), BillingError> {
    validate_identifier(external_id, "Stripe checkout session id")?;
    let mut transaction = store.begin("bind Stripe checkout session").await?;
    let row = sqlx::query(
        r#"
        UPDATE public.billing_sessions
        SET external_id = $2
        WHERE id = $1 AND (external_id = '' OR external_id = $2)
        RETURNING external_id
        "#,
    )
    .bind(session_id)
    .bind(external_id)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| {
        if is_unique_violation(&error) {
            BillingError::conflict(
                "stripe_session_conflict",
                "Stripe checkout session is already bound to another local session",
            )
        } else {
            BillingError::internal("bind Stripe checkout session", error)
        }
    })?;
    if row.is_none() {
        return Err(BillingError::conflict(
            "stripe_session_conflict",
            "billing session is already bound to a different Stripe session",
        ));
    }
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

pub(super) async fn record_external_event(
    store: &BillingStore,
    source: &str,
    event_id: &str,
    event_kind: &str,
    payload: &Value,
    status: &str,
) -> Result<bool, BillingError> {
    validate_identifier(event_id, "external event id")?;
    validate_identifier(event_kind, "external event kind")?;
    let payload_digest = canonical_json_digest(payload)
        .map_err(|error| BillingError::from_ledger("digest external event", error))?;
    let mut transaction = store.begin("record external event").await?;
    let owner_epoch = transaction.context().epoch();
    let inserted = sqlx::query(
        r#"
        INSERT INTO rust_coord.external_events (
            external_event_id, source, event_id, event_kind, payload_digest,
            payload, status, owner_epoch, processed_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
        ON CONFLICT (source, event_id) DO NOTHING
        RETURNING external_event_id
        "#,
    )
    .bind(deterministic_uuid(source, event_id))
    .bind(source)
    .bind(event_id)
    .bind(event_kind)
    .bind(payload_digest.as_bytes().as_slice())
    .bind(SqlJson(payload))
    .bind(status)
    .bind(owner_epoch)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("record external event", error))?;
    if inserted.is_none() {
        let existing = sqlx::query(
            r#"
            SELECT event_kind, payload_digest, payload, status
            FROM rust_coord.external_events
            WHERE source = $1 AND event_id = $2
            FOR UPDATE
            "#,
        )
        .bind(source)
        .bind(event_id)
        .fetch_one(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("reconcile external event", error))?;
        let digest: Vec<u8> = existing.get("payload_digest");
        let existing_payload = existing.get::<SqlJson<Value>, _>("payload").0;
        if existing.get::<String, _>("event_kind") != event_kind
            || digest.as_slice() != payload_digest.as_bytes()
            || existing_payload != *payload
        {
            return Err(BillingError::conflict(
                "external_event_conflict",
                "external event id was replayed with different immutable payload",
            ));
        }
        transaction
            .rollback()
            .await
            .map_err(|error| BillingError::internal("finish external event replay", error))?;
        return Ok(false);
    }
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))?;
    Ok(true)
}

pub(super) fn deterministic_uuid(domain: &str, value: &str) -> Uuid {
    let mut digest = Sha256::new();
    digest.update(b"darkbloom.billing.uuid.v1\0");
    digest.update((domain.len() as u64).to_be_bytes());
    digest.update(domain.as_bytes());
    digest.update((value.len() as u64).to_be_bytes());
    digest.update(value.as_bytes());
    let digest = digest.finalize();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

pub(super) fn event_operation_digest(
    domain: &str,
    event_id: &str,
    payload_digest: Digest,
) -> Digest {
    let mut digest = Sha256::new();
    digest.update(b"darkbloom.billing.external-operation.v1\0");
    digest.update((domain.len() as u64).to_be_bytes());
    digest.update(domain.as_bytes());
    digest.update((event_id.len() as u64).to_be_bytes());
    digest.update(event_id.as_bytes());
    digest.update(payload_digest.as_bytes());
    Digest::new(digest.finalize().into())
}

pub(super) fn required_event_string<'a>(
    event: &'a Value,
    field: &'static str,
) -> Result<&'a str, BillingError> {
    event
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| BillingError::bad_request(format!("Stripe event omitted {field}")))
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .is_some_and(|code| code == "23505")
}
