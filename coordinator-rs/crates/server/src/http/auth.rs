use axum::http::{HeaderMap, StatusCode, header};

use crate::pilot::{BillingContext, PilotHandle};

use super::error::ApiError;

pub fn authenticate_consumer(
    headers: &HeaderMap,
    pilot: &PilotHandle,
) -> Result<BillingContext, ApiError> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
        .ok_or_else(missing_credentials)?;
    pilot.authorize_consumer(token).ok_or_else(invalid_api_key)
}

fn missing_credentials() -> ApiError {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "authentication_error",
        "authentication_error",
        "missing credentials — use Authorization: Bearer <token>",
    )
}

fn invalid_api_key() -> ApiError {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "authentication_error",
        "authentication_error",
        "invalid API key",
    )
}
