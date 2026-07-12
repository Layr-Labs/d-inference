use std::sync::Arc;

use axum::{
    Json,
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Serialize;

use crate::pilot::{PilotRequestError, RequestDispatchError};

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    kind: &'static str,
    message: Arc<str>,
    retry_after_seconds: Option<u64>,
}

impl ApiError {
    pub fn new(
        status: StatusCode,
        code: &'static str,
        kind: &'static str,
        message: impl Into<Arc<str>>,
    ) -> Self {
        Self {
            status,
            code,
            kind,
            message: message.into(),
            retry_after_seconds: None,
        }
    }

    pub fn capacity(message: impl Into<Arc<str>>) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: "capacity_exhausted",
            kind: "rate_limit_error",
            message: message.into(),
            retry_after_seconds: Some(1),
        }
    }

    pub fn draining() -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: "rate_limit_exceeded",
            kind: "rate_limit_exceeded",
            message: Arc::from("draining rate limit exceeded — retry after 3s"),
            retry_after_seconds: Some(3),
        }
    }
}

impl From<PilotRequestError> for ApiError {
    fn from(error: PilotRequestError) -> Self {
        match error {
            PilotRequestError::InvalidRequest(message) => Self::new(
                StatusCode::BAD_REQUEST,
                "invalid_request",
                "invalid_request_error",
                message,
            ),
            PilotRequestError::ModelNotFound(model) => Self::new(
                StatusCode::NOT_FOUND,
                "model_not_found",
                "invalid_request_error",
                format!("model {model} is not available"),
            ),
            PilotRequestError::Capacity => Self::capacity("pilot fleet is at capacity"),
            PilotRequestError::PaymentRequired => Self::new(
                StatusCode::PAYMENT_REQUIRED,
                "insufficient_credit",
                "billing_error",
                "consumer account has insufficient credit",
            ),
            PilotRequestError::Forbidden => Self::new(
                StatusCode::FORBIDDEN,
                "forbidden",
                "permission_error",
                "consumer API key no longer authorizes this request",
            ),
            PilotRequestError::Timeout => Self::new(
                StatusCode::GATEWAY_TIMEOUT,
                "request_timeout",
                "server_error",
                "pilot request timed out",
            ),
            PilotRequestError::Cancelled => Self::new(
                StatusCode::from_u16(499).expect("499 is a valid HTTP status"),
                "request_cancelled",
                "server_error",
                "pilot request was cancelled",
            ),
            PilotRequestError::Provider(message) | PilotRequestError::ProviderPricing(message) => {
                Self::new(
                    StatusCode::BAD_GATEWAY,
                    "provider_error",
                    "server_error",
                    message,
                )
            }
            PilotRequestError::Protocol(message) => Self::new(
                StatusCode::BAD_GATEWAY,
                "provider_protocol_error",
                "server_error",
                message,
            ),
            PilotRequestError::Unavailable(message) => Self::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "pilot_unavailable",
                "server_error",
                message,
            ),
            PilotRequestError::Internal(message) => Self::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                "server_error",
                message,
            ),
            other => Self::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                "server_error",
                other.to_string(),
            ),
        }
    }
}

impl From<RequestDispatchError> for ApiError {
    fn from(error: RequestDispatchError) -> Self {
        match error {
            RequestDispatchError::Full => Self::capacity("pilot request queue is full"),
            RequestDispatchError::Closed => Self::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "pilot_unavailable",
                "server_error",
                "pilot request dispatcher is unavailable",
            ),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut headers = HeaderMap::new();
        if let Some(seconds) = self.retry_after_seconds
            && let Ok(value) = HeaderValue::from_str(&seconds.to_string())
        {
            headers.insert(header::RETRY_AFTER, value);
        }
        (
            self.status,
            headers,
            Json(ErrorEnvelope {
                error: ErrorBody {
                    message: self.message,
                    kind: self.kind,
                    code: self.code,
                },
            }),
        )
            .into_response()
    }
}

#[derive(Serialize)]
struct ErrorEnvelope {
    error: ErrorBody,
}

#[derive(Serialize)]
struct ErrorBody {
    message: Arc<str>,
    #[serde(rename = "type")]
    kind: &'static str,
    code: &'static str,
}
