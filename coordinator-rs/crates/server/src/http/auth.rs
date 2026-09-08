//! API-key bearer authentication (plan §7.1, pilot scope §23.2).

use axum::http::HeaderMap;

use crate::contracts::{ApiKeyRecord, ApiKeyStore};
use crate::http::errors::ApiError;

/// Extracts `Authorization: Bearer <token>` (Go `extractBearerToken`).
pub fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let value = headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?;
    let rest = value
        .strip_prefix("Bearer ")
        .or_else(|| value.strip_prefix("bearer "))?;
    let token = rest.trim();
    (!token.is_empty()).then_some(token)
}

/// Validates the bearer token against the key store. Disabled keys are
/// rejected exactly like unknown ones (no oracle).
pub async fn authenticate(
    store: &dyn ApiKeyStore,
    headers: &HeaderMap,
) -> Result<ApiKeyRecord, ApiError> {
    let token = bearer_token(headers).ok_or(ApiError::Unauthorized)?;
    match store.validate(token).await {
        Some(record) if !record.disabled => Ok(record),
        _ => Err(ApiError::Unauthorized),
    }
}
