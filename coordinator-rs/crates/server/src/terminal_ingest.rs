//! Terminal ingest for rollback-safe ACK without double settlement (plan §4.6).
//!
//! Mirrors `coordinator/ownership/terminal_ingest.go`. When a provider
//! reconnects with an unacked terminal after Rust→Go (or Rust restart),
//! look up the durable disposition and ACK — never move money again.

use serde_json::{json, Value};
use std::collections::HashMap;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalIngest {
    pub job_id: String,
    pub attempt_id: String,
    pub terminal_digest: String,
    pub se_signature: String,
    pub outcome: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalDisposition {
    pub disposition: String,
    pub ack_payload: Option<Value>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TerminalIngestError {
    #[error("terminal ingest missing attempt/digest")]
    MissingIdentity,
}

/// Process-local store of Rust terminal dispositions (SQLx later).
#[derive(Debug, Default)]
pub struct MemoryTerminalStore {
    /// (attempt_id, digest) → disposition
    by_attempt_digest: HashMap<(String, String), TerminalDisposition>,
    late: Vec<TerminalIngest>,
}

impl MemoryTerminalStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record(
        &mut self,
        attempt_id: &str,
        digest: &str,
        disposition: &str,
        ack: Option<Value>,
    ) {
        self.by_attempt_digest.insert(
            (attempt_id.to_string(), digest.to_string()),
            TerminalDisposition {
                disposition: disposition.to_string(),
                ack_payload: ack,
            },
        );
    }

    pub fn lookup(&self, attempt_id: &str, digest: &str) -> Option<&TerminalDisposition> {
        self.by_attempt_digest
            .get(&(attempt_id.to_string(), digest.to_string()))
    }

    pub fn late_count(&self) -> usize {
        self.late.len()
    }

    pub fn record_late(&mut self, t: TerminalIngest) {
        self.late.push(t);
    }
}

/// ACK a replayed v2 terminal using stored disposition. Never settles/releases.
pub fn ingest_terminal(
    store: &mut MemoryTerminalStore,
    t: TerminalIngest,
) -> Result<Value, TerminalIngestError> {
    if t.attempt_id.is_empty() || t.terminal_digest.is_empty() {
        return Err(TerminalIngestError::MissingIdentity);
    }
    if let Some(disp) = store.lookup(&t.attempt_id, &t.terminal_digest) {
        if let Some(ack) = &disp.ack_payload {
            return Ok(ack.clone());
        }
        return Ok(json!({
            "type": "terminal_ack",
            "job_id": t.job_id,
            "attempt_id": t.attempt_id,
            "terminal_digest": t.terminal_digest,
            "disposition": disp.disposition,
        }));
    }
    store.record_late(t.clone());
    Ok(json!({
        "type": "terminal_ack",
        "job_id": t.job_id,
        "attempt_id": t.attempt_id,
        "terminal_digest": t.terminal_digest,
        "disposition": "late",
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_terminal_returns_disposition_ack() {
        let mut store = MemoryTerminalStore::new();
        store.record("a1", "d1", "settled", None);
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                se_signature: String::new(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "settled");
        assert_eq!(ack["type"], "terminal_ack");
        assert_eq!(store.late_count(), 0);
    }

    #[test]
    fn unknown_terminal_recorded_as_late() {
        let mut store = MemoryTerminalStore::new();
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "unknown".into(),
                se_signature: String::new(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "late");
        assert_eq!(store.late_count(), 1);
    }

    #[test]
    fn missing_identity_errors() {
        let mut store = MemoryTerminalStore::new();
        assert_eq!(
            ingest_terminal(
                &mut store,
                TerminalIngest {
                    job_id: "j".into(),
                    attempt_id: String::new(),
                    terminal_digest: "d".into(),
                    se_signature: String::new(),
                    outcome: String::new(),
                },
            ),
            Err(TerminalIngestError::MissingIdentity)
        );
    }

    #[test]
    fn stored_ack_payload_preferred() {
        let mut store = MemoryTerminalStore::new();
        let custom = json!({"type":"terminal_ack","custom":true});
        store.record("a1", "d1", "settled", Some(custom.clone()));
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                se_signature: String::new(),
                outcome: String::new(),
            },
        )
        .unwrap();
        assert_eq!(ack, custom);
    }
}
