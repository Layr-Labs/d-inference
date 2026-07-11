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
        .ok_or_else(unauthorized)?;
    pilot.authorize_consumer(token).ok_or_else(unauthorized)
}

fn unauthorized() -> ApiError {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "invalid_api_key",
        "authentication_error",
        "invalid pilot API key",
    )
}
