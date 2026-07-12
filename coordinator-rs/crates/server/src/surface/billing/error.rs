use std::borrow::Cow;

use axum::{
    Json,
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Serialize;

use crate::ledger::LedgerError;

#[derive(Debug)]
pub struct BillingError {
    status: StatusCode,
    code: &'static str,
    message: Cow<'static, str>,
    retry_after: Option<u64>,
}

impl BillingError {
    pub(super) fn new(
        status: StatusCode,
        code: &'static str,
        message: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            retry_after: None,
        }
    }

    pub(super) fn bad_request(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "invalid_request_error", message)
    }

    pub(crate) fn unauthorized(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, "unauthorized", message)
    }

    pub(super) fn forbidden(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::FORBIDDEN, "forbidden", message)
    }

    pub(super) fn not_found(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", message)
    }

    pub(super) fn conflict(code: &'static str, message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::CONFLICT, code, message)
    }

    pub(super) fn payload_too_large() -> Self {
        Self::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "payload_too_large",
            "request body exceeds the 1 MiB limit",
        )
    }

    pub(super) fn stripe_unavailable(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::BAD_GATEWAY, "stripe_error", message)
    }

    pub(super) fn unavailable(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "billing_unavailable",
            message,
        )
    }

    pub(super) fn external_unknown(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::ACCEPTED, "external_unknown", message)
    }

    pub(super) fn internal(operation: &'static str, error: impl std::fmt::Display) -> Self {
        tracing::error!(operation, error = %error, "billing surface failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            format!("{operation} failed"),
        )
    }

    pub(super) fn retryable(operation: &'static str, error: impl std::fmt::Display) -> Self {
        tracing::warn!(operation, error = %error, "billing surface asks caller to retry");
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: "retryable_error",
            message: format!("{operation} is temporarily unavailable").into(),
            retry_after: Some(1),
        }
    }

    pub(super) fn is_external_unknown(&self) -> bool {
        self.code == "external_unknown"
    }

    pub(super) fn from_ledger(operation: &'static str, error: LedgerError) -> Self {
        match error {
            LedgerError::InsufficientBalance => Self::bad_request(
                "insufficient withdrawable balance; only earned funds can be withdrawn",
            ),
            LedgerError::OperationConflict | LedgerError::StaleVersion => Self::conflict(
                "operation_conflict",
                "the operation conflicts with durable state",
            ),
            LedgerError::OwnershipUnavailable | LedgerError::OwnershipLost => {
                Self::unavailable("coordinator ownership is unavailable")
            }
            LedgerError::Timeout | LedgerError::CommitOutcomeUnknown { .. } => {
                Self::external_unknown("the durable operation outcome is being reconciled")
            }
            LedgerError::Invalid(error) => Self::bad_request(error.to_string()),
            error => Self::internal(operation, error),
        }
    }
}

impl std::fmt::Display for BillingError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for BillingError {}

impl IntoResponse for BillingError {
    fn into_response(self) -> Response {
        let mut headers = HeaderMap::new();
        if let Some(seconds) = self.retry_after
            && let Ok(value) = HeaderValue::from_str(&seconds.to_string())
        {
            headers.insert(header::RETRY_AFTER, value);
        }
        (
            self.status,
            headers,
            Json(ErrorEnvelope {
                error: ErrorBody {
                    kind: error_kind(self.status),
                    code: self.code,
                    message: self.message,
                },
            }),
        )
            .into_response()
    }
}

fn error_kind(status: StatusCode) -> &'static str {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => "authentication_error",
        StatusCode::TOO_MANY_REQUESTS => "rate_limit_error",
        status if status.is_client_error() => "invalid_request_error",
        _ => "server_error",
    }
}

#[derive(Serialize)]
struct ErrorEnvelope {
    error: ErrorBody,
}

#[derive(Serialize)]
struct ErrorBody {
    #[serde(rename = "type")]
    kind: &'static str,
    code: &'static str,
    message: Cow<'static, str>,
}
