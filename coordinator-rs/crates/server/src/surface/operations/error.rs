use std::borrow::Cow;

use axum::{
    Json,
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Serialize;

#[derive(Debug)]
pub(super) struct OperationsError {
    status: StatusCode,
    code: &'static str,
    message: Cow<'static, str>,
    retry_after: Option<u64>,
}

impl OperationsError {
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

    pub(super) fn unauthorized(message: impl Into<Cow<'static, str>>) -> Self {
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

    pub(super) fn payload_too_large(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::PAYLOAD_TOO_LARGE, "payload_too_large", message)
    }

    pub(super) fn rate_limited(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::TOO_MANY_REQUESTS, "rate_limited", message)
    }

    pub(super) fn unavailable(message: impl Into<Cow<'static, str>>) -> Self {
        Self::new(StatusCode::SERVICE_UNAVAILABLE, "not_configured", message)
    }

    pub(super) fn internal(operation: &'static str, error: impl std::fmt::Display) -> Self {
        tracing::error!(operation, error = %error, "operations surface failed");
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            format!("{operation} failed"),
        )
    }
}

impl IntoResponse for OperationsError {
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
