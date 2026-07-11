use std::{borrow::Cow, time::Duration};

use axum::{
    Json,
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum IdentityError {
    #[error("authentication failed")]
    Unauthorized,
    #[error("an interactive Privy session is required")]
    PrivyRequired,
    #[error("the authenticated principal does not own this resource")]
    Forbidden,
    #[error("{0}")]
    InvalidRequest(Cow<'static, str>),
    #[error("{0}")]
    NotFound(Cow<'static, str>),
    #[error("{0}")]
    Conflict(Cow<'static, str>),
    #[error("{0}")]
    Expired(Cow<'static, str>),
    #[error("rate limit exceeded")]
    RateLimited(Duration),
    #[error("coordinator database ownership is unavailable")]
    OwnershipUnavailable,
    #[error("identity database operation timed out")]
    Timeout,
    #[error("identity database operation failed: {0}")]
    Database(#[from] sqlx::Error),
    #[error("identity service is unavailable")]
    Unavailable,
}

impl IdentityError {
    pub fn invalid(message: impl Into<Cow<'static, str>>) -> Self {
        Self::InvalidRequest(message.into())
    }

    pub fn not_found(message: impl Into<Cow<'static, str>>) -> Self {
        Self::NotFound(message.into())
    }

    pub fn conflict(message: impl Into<Cow<'static, str>>) -> Self {
        Self::Conflict(message.into())
    }

    pub fn expired(message: impl Into<Cow<'static, str>>) -> Self {
        Self::Expired(message.into())
    }
}

impl IntoResponse for IdentityError {
    fn into_response(self) -> Response {
        let (status, code, message, retry_after) = match self {
            Self::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                "authentication_error",
                Cow::Borrowed("invalid or missing credentials"),
                None,
            ),
            Self::PrivyRequired => (
                StatusCode::FORBIDDEN,
                "forbidden",
                Cow::Borrowed("this endpoint requires an interactive Privy session"),
                None,
            ),
            Self::Forbidden => (
                StatusCode::FORBIDDEN,
                "forbidden",
                Cow::Borrowed("you do not own this resource"),
                None,
            ),
            Self::InvalidRequest(message) => {
                (StatusCode::BAD_REQUEST, "invalid_request", message, None)
            }
            Self::NotFound(message) => (StatusCode::NOT_FOUND, "not_found", message, None),
            Self::Conflict(message) => (StatusCode::CONFLICT, "conflict", message, None),
            Self::Expired(message) => (StatusCode::GONE, "expired_token", message, None),
            Self::RateLimited(duration) => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limit_exceeded",
                Cow::Borrowed("too many requests; retry after the indicated interval"),
                Some(
                    duration
                        .as_secs()
                        .saturating_add(u64::from(duration.subsec_nanos() > 0))
                        .max(1),
                ),
            ),
            Self::OwnershipUnavailable | Self::Unavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "service_unavailable",
                Cow::Borrowed("identity service is temporarily unavailable"),
                None,
            ),
            Self::Timeout | Self::Database(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                Cow::Borrowed("identity operation failed"),
                None,
            ),
        };
        let mut headers = HeaderMap::new();
        if let Some(seconds) = retry_after
            && let Ok(value) = HeaderValue::from_str(&seconds.to_string())
        {
            headers.insert(header::RETRY_AFTER, value);
        }
        (
            status,
            headers,
            Json(ErrorEnvelope {
                error: ErrorBody {
                    code,
                    kind: if status == StatusCode::TOO_MANY_REQUESTS {
                        "rate_limit_error"
                    } else if status == StatusCode::UNAUTHORIZED {
                        "authentication_error"
                    } else {
                        "invalid_request_error"
                    },
                    message,
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
    code: &'static str,
    #[serde(rename = "type")]
    kind: &'static str,
    message: Cow<'static, str>,
}
