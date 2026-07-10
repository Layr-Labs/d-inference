//! Catalog reads, encryption-key publication, and liveness probes
//! (pilot scope, plan §23.2).

use axum::extract::{Path, State};
use axum::http::{header, HeaderValue};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::{json, Value};

use darkbloom_core::money::MicroUsd;
use darkbloom_protocol::crypto::sealed_sender;

use crate::contracts::{AppState, CatalogSnapshot, PriceCard};
use crate::http::errors::ApiError;

/// Formats micro-USD per token as an exact decimal USD string (the Go
/// pricing block uses strings to avoid float precision drift).
fn usd_string(micro: MicroUsd) -> String {
    let value = micro.get();
    let sign = if value < 0 { "-" } else { "" };
    let magnitude = value.unsigned_abs();
    let whole = magnitude / 1_000_000;
    let frac = magnitude % 1_000_000;
    if frac == 0 {
        return format!("{sign}{whole}");
    }
    let frac = format!("{frac:06}");
    let frac = frac.trim_end_matches('0');
    format!("{sign}{whole}.{frac}")
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
            "prompt": usd_string(price.prompt_micro_per_token),
            "completion": usd_string(price.completion_micro_per_token),
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

pub async fn readyz() -> &'static str {
    "ok"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usd_strings_are_exact() {
        assert_eq!(usd_string(MicroUsd::new(0)), "0");
        assert_eq!(usd_string(MicroUsd::new(2)), "0.000002");
        assert_eq!(usd_string(MicroUsd::new(1_500_000)), "1.5");
        assert_eq!(usd_string(MicroUsd::new(1_000_000)), "1");
    }
}
