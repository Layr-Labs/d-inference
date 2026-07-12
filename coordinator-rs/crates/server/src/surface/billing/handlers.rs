use axum::{
    Json,
    extract::{Request, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::{Value, json};

use super::{
    auth::{idempotency_key, operation_suffix, principal, privy_principal, require_admin},
    body,
    error::BillingError,
    invite::InviteService,
    money::{format_usd, parse_usd},
    pricing::PricingService,
    state::BillingState,
    store::{bounded_limit, query_parameter},
};

pub(super) async fn balance(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = principal(&request)?.account_id().to_owned();
    Ok(Json(state.store.balance(&account_id).await?).into_response())
}

pub(super) async fn usage(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = principal(&request)?.account_id().to_owned();
    let limit = bounded_limit(
        query_parameter(request.uri().query(), "limit").as_deref(),
        100,
        1_000,
    );
    Ok(Json(json!({
        "usage": state.store.usage(&account_id, limit).await?
    }))
    .into_response())
}

pub(super) async fn provider_earnings(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let wallet = query_parameter(request.uri().query(), "wallet")
        .or_else(|| {
            request
                .headers()
                .get("x-provider-wallet")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned)
        })
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            BillingError::bad_request(
                "wallet address required (query param ?wallet=0x... or X-Provider-Wallet header)",
            )
        })?;
    Ok(Json(state.store.public_provider_earnings(&wallet).await?).into_response())
}

pub(super) async fn account_earnings(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = principal(&request)?.account_id().to_owned();
    let limit = bounded_limit(
        query_parameter(request.uri().query(), "limit").as_deref(),
        50,
        1_000,
    );
    Ok(Json(state.store.account_earnings(&account_id, limit).await?).into_response())
}

pub(super) async fn methods(State(state): State<BillingState>) -> Result<Response, BillingError> {
    let methods: Vec<Value> = if state.stripe_configured() {
        vec![
            json!({
                "id": "stripe",
                "name": "Credit or debit card",
                "currencies": ["usd"],
                "minimum_usd": "0.50"
            }),
            json!({
                "id": "stripe_connect",
                "name": "Stripe Connect payout",
                "currencies": ["usd"],
                "minimum_usd": "1.00"
            }),
        ]
    } else {
        Vec::new()
    };
    let referral_share_percent = state.referral.share_percent().await?;
    Ok(Json(json!({
        "methods": methods,
        "referral": {
            "enabled": true,
            "share_percent": referral_share_percent
        }
    }))
    .into_response())
}

pub(super) async fn pricing_get(
    State(state): State<BillingState>,
) -> Result<Response, BillingError> {
    Ok(Json(PricingService::new(state.store).list_platform().await?).into_response())
}

pub(super) async fn pricing_put(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = privy_principal(&request)?.account_id().to_owned();
    let payload: Value = body::json(request).await?;
    let model = body::required_string(&payload, "model")?;
    let input = positive_i64(&payload, "input_price")?;
    let output = positive_i64(&payload, "output_price")?;
    let price = PricingService::new(state.store)
        .set(&account_id, model, input, output)
        .await?;
    Ok(Json(json!({"status": "updated", "price": price})).into_response())
}

pub(super) async fn pricing_delete(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = privy_principal(&request)?.account_id().to_owned();
    let payload: Value = body::json(request).await?;
    let model = body::required_string(&payload, "model")?;
    let deleted = PricingService::new(state.store)
        .delete(&account_id, model)
        .await?;
    Ok(Json(json!({"status": "deleted", "model": deleted})).into_response())
}

pub(super) async fn admin_pricing_put(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    require_admin(&request, state.admin_key_digest.as_ref())?;
    let payload: Value = body::json(request).await?;
    let model = body::required_string(&payload, "model")?;
    let input = positive_i64(&payload, "input_price")?;
    let output = positive_i64(&payload, "output_price")?;
    let price = PricingService::new(state.store)
        .set("platform", model, input, output)
        .await?;
    Ok(Json(json!({"status": "platform_default_updated", "price": price})).into_response())
}

pub(super) async fn referral_register(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = privy_principal(&request)?.account_id().to_owned();
    let payload: Value = body::json(request).await?;
    let code = body::required_string(&payload, "code")?;
    Ok(Json(state.referral.register(&account_id, code).await?).into_response())
}

pub(super) async fn referral_apply(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = privy_principal(&request)?.account_id().to_owned();
    let payload: Value = body::json(request).await?;
    let code = body::required_string(&payload, "code")?;
    let code = state.referral.apply(&account_id, code).await?;
    Ok(Json(json!({"status": "applied", "code": code})).into_response())
}

pub(super) async fn referral_stats(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = principal(&request)?.account_id().to_owned();
    Ok(Json(state.referral.stats(&account_id).await?).into_response())
}

pub(super) async fn referral_info(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = principal(&request)?.account_id().to_owned();
    Ok(Json(state.referral.info(&account_id).await?).into_response())
}

pub(super) async fn admin_invite_create(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    require_admin(&request, state.admin_key_digest.as_ref())?;
    let payload: Value = body::json(request).await?;
    let amount = parse_usd(amount_string(&payload, "amount_usd")?)?;
    let max_uses = payload.get("max_uses").and_then(Value::as_i64).unwrap_or(1);
    let max_uses = i32::try_from(max_uses)
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| BillingError::bad_request("max_uses must be a positive 32-bit integer"))?;
    let invite = InviteService::new(state.store)
        .create(
            body::optional_string(&payload, "code"),
            amount,
            max_uses,
            payload.get("expires_at").and_then(Value::as_str),
        )
        .await?;
    Ok((StatusCode::CREATED, Json(invite)).into_response())
}

pub(super) async fn admin_invite_list(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    require_admin(&request, state.admin_key_digest.as_ref())?;
    Ok(Json(json!({
        "invite_codes": InviteService::new(state.store).list().await?
    }))
    .into_response())
}

pub(super) async fn admin_invite_delete(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    require_admin(&request, state.admin_key_digest.as_ref())?;
    let payload: Value = body::json(request).await?;
    let code = body::required_string(&payload, "code")?;
    InviteService::new(state.store).deactivate(code).await?;
    Ok(Json(json!({"status": "deactivated"})).into_response())
}

pub(super) async fn invite_redeem(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    let account_id = principal(&request)?.account_id().to_owned();
    let payload: Value = body::json(request).await?;
    let code = body::required_string(&payload, "code")?;
    Ok(Json(
        InviteService::new(state.store)
            .redeem(code, &account_id)
            .await?,
    )
    .into_response())
}

pub(super) async fn admin_credit(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    admin_credit_or_reward(state, request, false).await
}

pub(super) async fn admin_reward(
    State(state): State<BillingState>,
    request: Request,
) -> Result<Response, BillingError> {
    admin_credit_or_reward(state, request, true).await
}

async fn admin_credit_or_reward(
    state: BillingState,
    request: Request,
    reward: bool,
) -> Result<Response, BillingError> {
    require_admin(&request, state.admin_key_digest.as_ref())?;
    let idempotency = idempotency_key(request.headers(), true)?
        .expect("required idempotency key")
        .to_owned();
    let payload: Value = body::json(request).await?;
    let email = body::required_string(&payload, "email")?;
    let amount = parse_usd(amount_string(&payload, "amount_usd")?)?;
    if amount <= 0 {
        return Err(BillingError::bad_request("credit amount must be positive"));
    }
    let user = state.store.user_by_email(email).await?;
    let operation_kind = if reward {
        "admin-reward"
    } else {
        "admin-credit"
    };
    let reference = format!(
        "{operation_kind}:{}",
        operation_suffix(operation_kind, &idempotency)
    );
    let balance = state
        .store
        .credit_once(
            &user.account_id,
            amount,
            reward,
            if reward {
                "admin_reward"
            } else {
                "admin_credit"
            },
            &reference,
        )
        .await?;
    Ok(Json(json!({
        "ok": true,
        "account_id": user.account_id,
        "email": user.email,
        "amount_micro_usd": amount,
        "amount_usd": format_usd(amount),
        "withdrawable": reward,
        "balance": balance,
    }))
    .into_response())
}

fn positive_i64(payload: &Value, field: &'static str) -> Result<i64, BillingError> {
    payload
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| BillingError::bad_request(format!("{field} must be a positive integer")))
}

fn amount_string<'a>(payload: &'a Value, field: &'static str) -> Result<&'a str, BillingError> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| BillingError::bad_request(format!("{field} must be a decimal string")))
}
