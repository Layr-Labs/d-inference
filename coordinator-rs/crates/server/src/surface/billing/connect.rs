use axum::{
    Json,
    extract::{Request, State},
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};
use url::Url;

use super::{
    auth::{idempotency_key, operation_suffix, privy_principal},
    body,
    error::BillingError,
    state::BillingState,
    store::{BillingStore, bounded_limit, query_parameter},
    stripe::{StripeAccount, StripeOutcome, required_service_agreement},
};

pub(super) async fn onboard(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let principal = privy_principal(&request)?.clone();
    let idempotency = idempotency_key(request.headers(), true)?
        .expect("required idempotency key")
        .to_owned();
    let payload: Value = body::json(request).await?;
    let stripe = state
        .stripe
        .as_ref()
        .ok_or_else(|| BillingError::unavailable("Stripe Connect is not configured"))?
        .clone();
    let configured_return = stripe.settings().connect_return_url.as_ref();
    let configured_refresh = stripe.settings().connect_refresh_url.as_ref();
    let return_url = nonempty_string(&payload, "return_url").unwrap_or(configured_return);
    let refresh_url = nonempty_string(&payload, "refresh_url")
        .or((!configured_refresh.is_empty()).then_some(configured_refresh))
        .unwrap_or(return_url);
    validate_redirect(return_url, configured_return)?;
    validate_redirect(refresh_url, configured_return)?;
    let requested_country = nonempty_string(&payload, "country")
        .unwrap_or_default()
        .trim()
        .to_ascii_uppercase();
    if !requested_country.is_empty() && !valid_country(&requested_country) {
        return Err(BillingError::bad_request(
            "country must be a two-letter ISO country code",
        ));
    }
    let mut user = state.store.user(principal.account_id()).await?;
    let mut account_id = user.stripe_account_id.clone();
    let mut account_snapshot = None;
    let mut create_new = account_id.is_empty();
    if !account_id.is_empty() {
        match stripe.account(&account_id).await {
            Ok(account) => {
                let country_changed = !requested_country.is_empty()
                    && !account.country.eq_ignore_ascii_case(&requested_country);
                let agreement_changed = account.service_agreement
                    != required_service_agreement(
                        &stripe.settings().platform_country,
                        &account.country,
                    );
                create_new = country_changed || agreement_changed;
                if !create_new {
                    if account.payout_interval == "manual" {
                        stripe
                            .ensure_automatic_schedule(&account_id, &account.country)
                            .await
                            .map_err(map_stripe)?;
                    }
                    account_snapshot = Some(account);
                }
            }
            Err(error) if error.account_gone() => {
                create_new = true;
            }
            Err(error) => return Err(map_stripe(error)),
        }
    }
    if create_new {
        let country = if requested_country.is_empty() {
            if user.stripe_account_country.is_empty() {
                stripe.settings().platform_country.to_string()
            } else {
                user.stripe_account_country.clone()
            }
        } else {
            requested_country
        };
        if !valid_country(&country) {
            return Err(BillingError::bad_request(
                "country is required before creating a Stripe payout account",
            ));
        }
        let operation_key = format!(
            "onboard-account-{}",
            operation_suffix(principal.account_id(), &idempotency)
        );
        let account = stripe
            .create_account(principal.email(), &country, &operation_key)
            .await
            .map_err(map_stripe)?;
        persist_account(
            &state.store,
            principal.account_id(),
            &user.stripe_account_id,
            &account,
        )
        .await?;
        account_id = account.id.clone();
        user.stripe_account_id.clone_from(&account_id);
        user.stripe_account_status = account.status().to_owned();
        account_snapshot = Some(account);
    }
    let link_key = format!(
        "onboard-link-{}",
        operation_suffix(
            &account_id,
            &format!("{idempotency}:{return_url}:{refresh_url}")
        )
    );
    let link = stripe
        .account_link(&account_id, return_url, refresh_url, &link_key)
        .await
        .map_err(map_stripe)?;
    let status = account_snapshot.as_ref().map_or_else(
        || user.stripe_account_status.clone(),
        |account| account.status().to_owned(),
    );
    Ok(Json(json!({
        "url": link,
        "stripe_account_id": account_id,
        "status": status,
    }))
    .into_response())
}

pub(super) async fn status(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let principal = privy_principal(&request)?.clone();
    let mut user = state.store.user(principal.account_id()).await?;
    let Some(stripe) = state.stripe.as_ref() else {
        return Ok(Json(user.status_json(false)).into_response());
    };
    if !user.stripe_account_id.is_empty()
        && query_parameter(request.uri().query(), "refresh").as_deref() == Some("1")
    {
        match stripe.account(&user.stripe_account_id).await {
            Ok(account) => {
                if account.payout_interval == "manual" {
                    stripe
                        .ensure_automatic_schedule(&account.id, &account.country)
                        .await
                        .map_err(map_stripe)?;
                }
                persist_account(
                    &state.store,
                    principal.account_id(),
                    &user.stripe_account_id,
                    &account,
                )
                .await?;
                user.stripe_account_status = account.status().to_owned();
                user.stripe_account_country = account.country;
                user.stripe_destination_type = account.destination_type;
                user.stripe_destination_last4 = account.destination_last4;
                user.stripe_instant_eligible = account.instant_eligible;
            }
            Err(error) if error.account_gone() => {
                clear_account(
                    &state.store,
                    principal.account_id(),
                    &user.stripe_account_id,
                )
                .await?;
                user.stripe_account_id.clear();
                user.stripe_account_status.clear();
                user.stripe_account_country.clear();
                user.stripe_destination_type.clear();
                user.stripe_destination_last4.clear();
                user.stripe_instant_eligible = false;
            }
            Err(error) => return Err(map_stripe(error)),
        }
    }
    let mut response = user.status_json(true);
    if let Some(object) = response.as_object_mut() {
        object.insert("min_withdraw_micro_usd".to_owned(), json!(1_000_000));
        object.insert("instant_fee_bps".to_owned(), json!(150));
        object.insert("instant_fee_min_micro_usd".to_owned(), json!(500_000));
    }
    Ok(Json(response).into_response())
}

pub(super) async fn withdrawals(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let principal = privy_principal(&request)?;
    let limit = bounded_limit(
        query_parameter(request.uri().query(), "limit").as_deref(),
        50,
        200,
    );
    Ok(Json(json!({
        "withdrawals": state.store.withdrawals(principal.account_id(), limit).await?
    }))
    .into_response())
}

pub(super) async fn unlink(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let principal = privy_principal(&request)?;
    let user = state.store.user(principal.account_id()).await?;
    if user.stripe_account_id.is_empty() {
        return Ok(Json(json!({"unlinked": false})).into_response());
    }
    clear_account(
        &state.store,
        principal.account_id(),
        &user.stripe_account_id,
    )
    .await?;
    Ok(Json(json!({"unlinked": true})).into_response())
}

pub(super) async fn persist_account(
    store: &BillingStore,
    account_id: &str,
    expected_stripe_account_id: &str,
    account: &StripeAccount,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("persist Stripe account").await?;
    let updated = sqlx::query(
        r#"
        UPDATE public.users
        SET stripe_account_id = $3,
            stripe_account_status = $4,
            stripe_account_country = $5,
            stripe_destination_type = $6,
            stripe_destination_last4 = $7,
            stripe_instant_eligible = $8
        WHERE account_id = $1
          AND (stripe_account_id = $2 OR stripe_account_id = $3)
        RETURNING account_id
        "#,
    )
    .bind(account_id)
    .bind(expected_stripe_account_id)
    .bind(&account.id)
    .bind(account.status())
    .bind(&account.country)
    .bind(&account.destination_type)
    .bind(&account.destination_last4)
    .bind(account.instant_eligible)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("persist Stripe account", error))?;
    if updated.is_none() {
        return Err(BillingError::conflict(
            "stripe_account_conflict",
            "Stripe account changed concurrently",
        ));
    }
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

pub(super) async fn clear_account(
    store: &BillingStore,
    account_id: &str,
    expected_stripe_account_id: &str,
) -> Result<(), BillingError> {
    let mut transaction = store.begin("unlink Stripe account").await?;
    let updated = sqlx::query(
        r#"
        UPDATE public.users
        SET stripe_account_id = '',
            stripe_account_status = '',
            stripe_account_country = '',
            stripe_destination_type = '',
            stripe_destination_last4 = '',
            stripe_instant_eligible = FALSE
        WHERE account_id = $1
          AND (stripe_account_id = $2 OR stripe_account_id = '')
        RETURNING account_id
        "#,
    )
    .bind(account_id)
    .bind(expected_stripe_account_id)
    .fetch_optional(transaction.connection())
    .await
    .map_err(|error| BillingError::internal("unlink Stripe account", error))?;
    if updated.is_none() {
        return Err(BillingError::conflict(
            "stripe_account_conflict",
            "Stripe account changed concurrently",
        ));
    }
    transaction
        .commit()
        .await
        .map_err(|error| BillingError::external_unknown(error.to_string()))
}

fn nonempty_string<'a>(value: &'a Value, field: &str) -> Option<&'a str> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn valid_country(country: &str) -> bool {
    country.len() == 2 && country.bytes().all(|byte| byte.is_ascii_uppercase())
}

fn validate_redirect(candidate: &str, configured: &str) -> Result<(), BillingError> {
    let candidate = Url::parse(candidate)
        .map_err(|_| BillingError::bad_request("Stripe redirect URL is invalid"))?;
    if !matches!(candidate.scheme(), "http" | "https") || candidate.host_str().is_none() {
        return Err(BillingError::bad_request(
            "Stripe redirect URL must use HTTP or HTTPS and include a hostname",
        ));
    }
    let local = matches!(
        candidate.host_str(),
        Some("localhost" | "127.0.0.1" | "::1")
    );
    if local {
        return Ok(());
    }
    if configured.is_empty() {
        if candidate.scheme() != "https" {
            return Err(BillingError::bad_request(
                "Stripe redirect URL must use HTTPS",
            ));
        }
        return Ok(());
    }
    let configured = Url::parse(configured)
        .map_err(|_| BillingError::unavailable("configured Stripe return URL is invalid"))?;
    if candidate.host_str() != configured.host_str()
        || candidate.port_or_known_default() != configured.port_or_known_default()
    {
        return Err(BillingError::bad_request(
            "Stripe redirect URL origin is not allowed",
        ));
    }
    Ok(())
}

pub(super) fn map_stripe(error: super::stripe::StripeError) -> BillingError {
    match error.outcome {
        StripeOutcome::Definitive => BillingError::stripe_unavailable(error.to_string()),
        StripeOutcome::Unknown => BillingError::stripe_unknown(format!(
            "Stripe operation outcome is unknown; retry with the same Idempotency-Key ({error})"
        )),
    }
}
