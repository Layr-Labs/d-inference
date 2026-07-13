use std::{borrow::Cow, fmt};

use serde_json::{Value, json};

/// A bounded, consumer-safe compatibility error.
///
/// Messages are static or generated from limits and never contain request
/// values. This makes the type safe to return and safe to record.
#[derive(Clone, Eq, PartialEq)]
pub struct AdapterError {
    status: u16,
    code: &'static str,
    kind: &'static str,
    message: Cow<'static, str>,
    param: Option<&'static str>,
}

impl AdapterError {
    #[must_use]
    pub const fn new(
        status: u16,
        code: &'static str,
        kind: &'static str,
        message: Cow<'static, str>,
        param: Option<&'static str>,
    ) -> Self {
        Self {
            status,
            code,
            kind,
            message,
            param,
        }
    }

    #[must_use]
    pub const fn invalid(message: &'static str, param: Option<&'static str>) -> Self {
        Self::new(
            400,
            "invalid_request_error",
            "invalid_request_error",
            Cow::Borrowed(message),
            param,
        )
    }

    #[must_use]
    pub fn limit(message: String, param: Option<&'static str>) -> Self {
        Self::new(
            400,
            "invalid_request_error",
            "invalid_request_error",
            Cow::Owned(message),
            param,
        )
    }

    #[must_use]
    pub const fn payload_too_large() -> Self {
        Self::new(
            413,
            "request_too_large",
            "invalid_request_error",
            Cow::Borrowed("request body exceeds the 2 MiB limit"),
            None,
        )
    }

    #[must_use]
    pub const fn cancelled() -> Self {
        Self::new(
            499,
            "request_cancelled",
            "server_error",
            Cow::Borrowed("request was cancelled"),
            None,
        )
    }

    #[must_use]
    pub const fn status(&self) -> u16 {
        self.status
    }

    #[must_use]
    pub const fn code(&self) -> &'static str {
        self.code
    }

    #[must_use]
    pub const fn kind(&self) -> &'static str {
        self.kind
    }

    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }

    #[must_use]
    pub const fn param(&self) -> Option<&'static str> {
        self.param
    }

    /// OpenAI error envelope used by Responses and Completions.
    #[must_use]
    pub fn openai_json(&self) -> Value {
        json!({
            "error": {
                "message": self.message(),
                "type": self.kind,
                "param": self.param,
                "code": self.code,
            }
        })
    }

    /// Anthropic's top-level error envelope.
    #[must_use]
    pub fn anthropic_json(&self) -> Value {
        json!({
            "type": "error",
            "error": {
                "type": anthropic_error_type(self),
                "message": self.message(),
            }
        })
    }
}

fn anthropic_error_type(error: &AdapterError) -> &'static str {
    match error.status {
        400 | 413 => "invalid_request_error",
        401 => "authentication_error",
        404 => "not_found_error",
        429 => "rate_limit_error",
        _ => "api_error",
    }
}

impl fmt::Debug for AdapterError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AdapterError")
            .field("status", &self.status)
            .field("code", &self.code)
            .field("kind", &self.kind)
            .field("message", &self.message)
            .field("param", &self.param)
            .finish()
    }
}

impl fmt::Display for AdapterError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for AdapterError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_envelopes_are_deterministic_and_surface_specific() {
        let error = AdapterError::invalid("model is required", Some("model"));
        assert_eq!(
            serde_json::to_string(&error.openai_json()).expect("OpenAI JSON"),
            r#"{"error":{"code":"invalid_request_error","message":"model is required","param":"model","type":"invalid_request_error"}}"#
        );
        assert_eq!(
            serde_json::to_string(&error.anthropic_json()).expect("Anthropic JSON"),
            r#"{"error":{"message":"model is required","type":"invalid_request_error"},"type":"error"}"#
        );
    }
}
