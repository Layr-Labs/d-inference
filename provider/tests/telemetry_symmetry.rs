//! Protocol symmetry test — asserts a telemetry event JSON shape matches the
//! Go canonical definition.
//!
//! This test duplicates the types inline so it doesn't require the
//! `darkbloom` crate to expose its modules as a library. The real types live
//! in `src/telemetry/event.rs`; if that file changes, update this fixture to
//! match.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Source {
    Coordinator,
    Provider,
    App,
    Console,
    Bridge,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Severity {
    Debug,
    Info,
    Warn,
    Error,
    Fatal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Kind {
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

#[derive(Debug, Clone, Serialize)]
struct TelemetryEvent {
    id: String,
    timestamp: String,
    source: Source,
    severity: Severity,
    kind: Kind,
    #[serde(skip_serializing_if = "String::is_empty")]
    version: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    machine_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    account_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    request_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    session_id: String,
    message: String,
    #[serde(skip_serializing_if = "Map::is_empty")]
    fields: Map<String, Value>,
    #[serde(skip_serializing_if = "String::is_empty")]
    stack: String,
}

#[test]
fn enum_serializations_match_go() {
    let ev = TelemetryEvent {
        id: "00000000-0000-0000-0000-000000000001".into(),
        timestamp: "2026-04-16T00:00:00.000000000Z".into(),
        source: Source::Provider,
        severity: Severity::Error,
        kind: Kind::BackendCrash,
        version: "0.3.10".into(),
        machine_id: "".into(),
        account_id: "".into(),
        request_id: "".into(),
        session_id: "abc".into(),
        message: "hi".into(),
        fields: Map::new(),
        stack: "".into(),
    };
    let s = serde_json::to_string(&ev).unwrap();
    let v: Value = serde_json::from_str(&s).unwrap();
    assert_eq!(v["source"], "provider");
    assert_eq!(v["severity"], "error");
    assert_eq!(v["kind"], "backend_crash");
    // Optionals omitted:
    assert!(v.get("machine_id").is_none());
    assert!(v.get("stack").is_none());
}
