//! OpenAI-compatible error mapping (plan §7.1): one typed [`ApiError`] →
//! exact status plus the Go coordinator's `{"error":{"message","type",
//! "code"}}` shape (`coordinator/api/httputil.go errorResponse`).

use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

use darkbloom_core::provider_error::ProviderErrorClass;
use darkbloom_core::request::RequestOutcome;

use crate::contracts::LedgerError;
use crate::request_task::TaskReport;

/// Typed consumer-facing failure. Message copy mirrors the Go coordinator
/// where consumers may pattern-match on it.
#[derive(Debug)]
pub enum ApiError {
    Unauthorized,
    InvalidRequest(String),
    ModelNotFound(String),
    PayloadTooLarge,
    InsufficientFunds,
    /// 429 with `Retry-After` (plan §11.7: fast capacity miss, no queue).
    Capacity {
        message: String,
        retry_after_secs: u64,
    },
    /// Global/per-account concurrency shed (plan §14: reject before
    /// allocating).
    Overloaded,
    ModelUnavailable(String),
    /// Provider failure before any content (503; Go `provider_error`).
    ProviderError(String),
    Timeout,
    EncryptionUnavailable,
    SealedRequestInvalid,
    Internal(&'static str),
}

impl ApiError {
    fn parts(&self) -> (StatusCode, &'static str, &'static str, String, Option<u64>) {
        match self {
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "authentication_error",
                "authentication_error",
                "missing credentials — use Authorization: Bearer <token>".to_owned(),
                None,
            ),
            Self::InvalidRequest(msg) => (
                StatusCode::BAD_REQUEST,
                "invalid_request_error",
                "invalid_request_error",
                msg.clone(),
                None,
            ),
            Self::ModelNotFound(model) => (
                StatusCode::NOT_FOUND,
                "model_not_found",
                "model_not_found",
                format!("model {model:?} not found"),
                None,
            ),
            Self::PayloadTooLarge => (
                StatusCode::PAYLOAD_TOO_LARGE,
                "invalid_request_error",
                "invalid_request_error",
                "request body too large".to_owned(),
                None,
            ),
            Self::InsufficientFunds => (
                StatusCode::PAYMENT_REQUIRED,
                "insufficient_funds",
                // Go mirrors OpenAI's quota code here (consumer.go).
                "insufficient_quota",
                "your balance is too low for this request — add funds at /billing or lower max_tokens"
                    .to_owned(),
                None,
            ),
            Self::Capacity {
                message,
                retry_after_secs,
            } => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limit_exceeded",
                "rate_limit_exceeded",
                message.clone(),
                Some((*retry_after_secs).max(1)),
            ),
            Self::Overloaded => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limit_exceeded",
                "rate_limit_exceeded",
                "coordinator is at capacity — retry shortly".to_owned(),
                Some(1),
            ),
            Self::ModelUnavailable(model) => (
                StatusCode::SERVICE_UNAVAILABLE,
                "model_unavailable",
                "model_unavailable",
                format!("model {model:?} is currently unavailable"),
                None,
            ),
            Self::ProviderError(msg) => (
                StatusCode::SERVICE_UNAVAILABLE,
                "provider_error",
                "provider_error",
                msg.clone(),
                None,
            ),
            Self::Timeout => (
                StatusCode::GATEWAY_TIMEOUT,
                "timeout",
                "timeout",
                "request timed out".to_owned(),
                None,
            ),
            Self::EncryptionUnavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "encryption_unavailable",
                "encryption_unavailable",
                "sender→coordinator encryption is not configured on this coordinator".to_owned(),
                None,
            ),
            Self::SealedRequestInvalid => (
                StatusCode::BAD_REQUEST,
                "invalid_request_error",
                "invalid_request_error",
                "sealed request envelope could not be opened".to_owned(),
                None,
            ),
            Self::Internal(msg) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                "internal_error",
                (*msg).to_owned(),
                None,
            ),
        }
    }

    pub fn status(&self) -> StatusCode {
        self.parts().0
    }

    /// The exact OpenAI-compatible body bytes.
    pub fn body(&self) -> serde_json::Value {
        let (_, error_type, code, message, _) = self.parts();
        json!({
            "error": {
                "type": error_type,
                "message": message,
                "code": code,
            }
        })
    }

    pub fn retry_after_secs(&self) -> Option<u64> {
        self.parts().4
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = self.status();
        let retry = self.retry_after_secs();
        let mut response = (status, Json(self.body())).into_response();
        if let Some(secs) = retry {
            if let Ok(value) = HeaderValue::from_str(&secs.to_string()) {
                response.headers_mut().insert(header::RETRY_AFTER, value);
            }
        }
        response
    }
}

/// Maps a pre-content [`TaskReport`] to the consumer-facing error
/// (plan §7.1: typed domain errors → stable HTTP responses).
pub fn error_for_report(report: &TaskReport, public_model: &str) -> ApiError {
    match report.outcome {
        RequestOutcome::ReserveFailed | RequestOutcome::FundingFailed => {
            match report.ledger_error {
                Some(LedgerError::InsufficientFunds) | Some(LedgerError::SpendCapExceeded) => {
                    ApiError::InsufficientFunds
                }
                _ => ApiError::ProviderError(
                    "service temporarily unavailable — please retry".to_owned(),
                ),
            }
        }
        RequestOutcome::NoCapacity { retry_after } => {
            let secs = retry_after
                .map(|d| d.get().div_ceil(1_000))
                .unwrap_or(2)
                .clamp(1, 60);
            ApiError::Capacity {
                message: format!(
                    "all providers for model {public_model:?} are at capacity — retry after {secs}s"
                ),
                retry_after_secs: secs,
            }
        }
        RequestOutcome::ProviderRejected { class } | RequestOutcome::ProviderError { class } => {
            match class {
                ProviderErrorClass::InvalidRequest => {
                    ApiError::InvalidRequest("provider rejected the request as invalid".to_owned())
                }
                _ => ApiError::ProviderError("provider error before any content".to_owned()),
            }
        }
        RequestOutcome::ProviderLost => {
            ApiError::ProviderError("provider ended without completion".to_owned())
        }
        RequestOutcome::DeadlineExceeded => ApiError::Timeout,
        RequestOutcome::ConsumerBackpressure | RequestOutcome::Cancelled => {
            // 499 semantics: the client is gone; this response is written
            // only when the socket is somehow still open.
            ApiError::Timeout
        }
        RequestOutcome::Completed => ApiError::Internal("completed request reported as failure"),
    }
}
