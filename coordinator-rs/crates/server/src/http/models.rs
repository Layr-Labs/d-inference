//! Catalog reads, encryption-key publication, and liveness probes
//! (pilot scope, plan §23.2).

use axum::extract::{Path, State};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::{json, Value};

use darkbloom_core::settlement::MicroUsdPerMTokens;
use darkbloom_protocol::crypto::sealed_sender;

use crate::contracts::{AppState, CatalogSnapshot, PriceCard};
use crate::http::errors::ApiError;
use crate::http::HttpState;

/// Formats an exact per-MTok micro-USD rate as the USD-per-token decimal
/// string the Go pricing block publishes (strings avoid float drift).
/// 1 USD = 10^6 µUSD and 1 MTok = 10^6 tokens, so the per-token USD value
/// is `rate / 10^12`, printed exactly with trailing zeros trimmed.
fn usd_per_token_string(rate: MicroUsdPerMTokens) -> String {
    let value = rate.get();
    debug_assert!(value >= 0, "MicroUsdPerMTokens is non-negative");
    let magnitude = value.unsigned_abs();
    let whole = magnitude / 1_000_000_000_000;
    let frac = magnitude % 1_000_000_000_000;
    if frac == 0 {
        return format!("{whole}");
    }
    let frac = format!("{frac:012}");
    let frac = frac.trim_end_matches('0');
    format!("{whole}.{frac}")
}

fn model_entry(public_id: &str, price: Option<&PriceCard>) -> Value {
    let mut entry = json!({
        "id": public_id,
        "object": "model",
        "created": 0,
        "owned_by": "darkbloom",
    });
    if let Some(price) = price {
        entry["pricing"] = json!({
            "prompt": usd_per_token_string(price.prompt_micro_per_mtok),
            "completion": usd_per_token_string(price.completion_micro_per_mtok),
            "image": "0",
            "request": "0",
            "input_cache_read": "0",
        });
    }
    entry
}

fn entries(catalog: &CatalogSnapshot) -> Vec<(String, Value)> {
    let mut out: Vec<(String, Value)> = catalog
        .aliases
        .iter()
        .map(|(public, concrete)| {
            (
                public.clone(),
                model_entry(public, catalog.prices.get(concrete)),
            )
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

pub async fn list_models(State(state): State<AppState>) -> Json<Value> {
    let catalog = state.catalog.load();
    let data: Vec<Value> = entries(&catalog).into_iter().map(|(_, v)| v).collect();
    Json(json!({ "object": "list", "data": data }))
}

pub async fn get_model(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let catalog = state.catalog.load();
    if let Some(concrete) = catalog.aliases.get(&id) {
        return Ok(Json(model_entry(&id, catalog.prices.get(concrete))));
    }
    // A raw build id known to the price table also resolves (Go parity:
    // raw build ids pass through alias resolution unchanged).
    if let Some(price) = catalog.prices.get(&id) {
        return Ok(Json(model_entry(&id, Some(price))));
    }
    Err(ApiError::ModelNotFound(id))
}

/// `GET /v1/encryption-key` (Go `handleEncryptionKey`): the coordinator's
/// X25519 public key plus the rotation `kid`. Public, no auth.
pub async fn encryption_key(State(state): State<AppState>) -> Response {
    let kid = sealed_sender::derive_kid(&state.encryption.x25519_secret.public_key());
    let mut response = Json(json!({
        "kid": kid,
        "public_key": state.encryption.x25519_public_b64,
        "algorithm": "x25519-nacl-box",
    }))
    .into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=300"),
    );
    response
}

pub async fn healthz() -> &'static str {
    "ok"
}

/// The ONE readiness implementation (plan §20): ownership health AND
/// admission open AND fleet mailbox accepting. The schema gate passed at
/// startup or this process would not be serving.
pub async fn readyz(State(state): State<HttpState>) -> Response {
    let ownership = *state.readiness.ownership_healthy.borrow();
    let admission = *state.readiness.admission_open.borrow();
    let fleet_mailbox = !state.app.fleet.commands.is_closed();
    let ready = ownership && admission && fleet_mailbox;
    let status = if ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (
        status,
        Json(json!({
            "ready": ready,
            "ownership": ownership,
            "admission": admission,
            "fleet_mailbox": fleet_mailbox,
            "schema": true,
        })),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usd_per_token_strings_are_exact() {
        let rate = |v: i64| MicroUsdPerMTokens::new(v).expect("rate");
        assert_eq!(usd_per_token_string(rate(0)), "0");
        // The Go default input price: $0.05 per MTok.
        assert_eq!(usd_per_token_string(rate(50_000)), "0.00000005");
        assert_eq!(usd_per_token_string(rate(2_000_000)), "0.000002");
        assert_eq!(usd_per_token_string(rate(1_500_000_000_000)), "1.5");
        assert_eq!(usd_per_token_string(rate(1_000_000_000_000)), "1");
    }
}
