use axum::{body, extract::Request};
use serde::de::DeserializeOwned;
use serde_json::Value;

use super::error::BillingError;

pub(super) const MAX_BODY_BYTES: usize = 1024 * 1024;

pub(super) async fn json<T: DeserializeOwned>(request: Request) -> Result<T, BillingError> {
    let bytes = body::to_bytes(request.into_body(), MAX_BODY_BYTES)
        .await
        .map_err(|_| BillingError::payload_too_large())?;
    serde_json::from_slice(&bytes)
        .map_err(|_| BillingError::bad_request("request body must be valid JSON"))
}

pub(super) async fn raw(request: Request) -> Result<Vec<u8>, BillingError> {
    body::to_bytes(request.into_body(), MAX_BODY_BYTES)
        .await
        .map(|bytes| bytes.to_vec())
        .map_err(|_| BillingError::payload_too_large())
}

pub(super) fn required_string<'a>(
    value: &'a Value,
    field: &'static str,
) -> Result<&'a str, BillingError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| BillingError::bad_request(format!("{field} is required")))
}

pub(super) fn optional_string<'a>(value: &'a Value, field: &str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or_default()
}
