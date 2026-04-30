//! Telemetry wire types — mirror of
//! `coordinator/internal/protocol/telemetry.go`.
//!
//! JSON shapes MUST match the Go definitions byte-for-byte. A symmetry test
//! (`tests/telemetry_symmetry.rs`) enforces this invariant at build time.

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

/// Per-process UUID. Events from the same boot share this ID so the admin UI
/// can group a crash report with the log lines leading up to it.
pub static SESSION_ID: Lazy<String> = Lazy::new(|| Uuid::new_v4().to_string());

/// Source of a telemetry event (which component produced it).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Coordinator,
    Provider,
    App,
    Console,
    Bridge,
}

/// Severity level, narrowed subset of syslog.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Debug,
    Info,
    Warn,
    Error,
    Fatal,
}

/// Coarse categorization for filtering.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Panic,
    HttpError,
    ProtocolError,
    BackendCrash,
    AttestationFailure,
    InferenceError,
    RuntimeMismatch,
    Connectivity,
    Log,
    Custom,
}

/// Single telemetry record. Serialization matches the Go `TelemetryEvent`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryEvent {
    pub id: String,
    /// RFC3339 with nanosecond precision, matching Go `time.Time` default.
    pub timestamp: String,
    pub source: Source,
    pub severity: Severity,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub version: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub machine_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub account_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub request_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub session_id: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub fields: Map<String, Value>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub stack: String,
}

impl TelemetryEvent {
    /// Build a new event with sensible defaults (id, timestamp, session_id).
    pub fn new(source: Source, severity: Severity, kind: Kind, message: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Nanos, true),
            source,
            severity,
            kind,
            version: String::new(),
            machine_id: String::new(),
            account_id: String::new(),
            request_id: String::new(),
            session_id: SESSION_ID.clone(),
            message: message.into(),
            fields: Map::new(),
            stack: String::new(),
        }
    }

    /// Builder-style: attach structured fields.
    pub fn with_fields(mut self, fields: Map<String, Value>) -> Self {
        self.fields = fields;
        self
    }

    /// Builder-style: attach a single field.
    pub fn with_field(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.fields.insert(key.into(), value.into());
        self
    }

    /// Builder-style: attach a stack trace.
    pub fn with_stack(mut self, stack: impl Into<String>) -> Self {
        self.stack = stack.into();
        self
    }

    /// Builder-style: attach a request_id.
    pub fn with_request_id(mut self, request_id: impl Into<String>) -> Self {
        self.request_id = request_id.into();
        self
    }
}

/// Wire shape for batch ingestion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryBatch {
    pub events: Vec<TelemetryEvent>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_minimal_event() {
        let ev = TelemetryEvent::new(Source::Provider, Severity::Warn, Kind::Log, "hi");
        let s = serde_json::to_string(&ev).unwrap();
        // Must contain the expected tag values.
        assert!(s.contains("\"source\":\"provider\""));
        assert!(s.contains("\"severity\":\"warn\""));
        assert!(s.contains("\"kind\":\"log\""));
    }

    #[test]
    fn round_trip() {
        let ev = TelemetryEvent::new(Source::Provider, Severity::Error, Kind::Panic, "boom")
            .with_field("exit_code", 134)
            .with_stack("at main::foo");
        let s = serde_json::to_string(&ev).unwrap();
        let back: TelemetryEvent = serde_json::from_str(&s).unwrap();
        assert_eq!(back.message, "boom");
        assert_eq!(back.fields["exit_code"], 134);
        assert_eq!(back.stack, "at main::foo");
    }

    #[test]
    fn omits_empty_optionals() {
        let ev = TelemetryEvent::new(Source::App, Severity::Info, Kind::Log, "x");
        let s = serde_json::to_string(&ev).unwrap();
        assert!(!s.contains("\"version\""));
        assert!(!s.contains("\"machine_id\""));
        assert!(!s.contains("\"stack\""));
    }
}
