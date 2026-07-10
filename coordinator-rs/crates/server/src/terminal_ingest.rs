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
    /// digest → disposition (secondary index for attempt_id drift / empty settle writes)
    by_digest: HashMap<String, TerminalDisposition>,
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
        let disp = TerminalDisposition {
            disposition: disposition.to_string(),
            ack_payload: ack,
        };
        self.by_attempt_digest.insert(
            (attempt_id.to_string(), digest.to_string()),
            disp.clone(),
        );
        self.by_digest.insert(digest.to_string(), disp);
    }

    pub fn lookup(&self, attempt_id: &str, digest: &str) -> Option<&TerminalDisposition> {
        if let Some(d) = self
            .by_attempt_digest
            .get(&(attempt_id.to_string(), digest.to_string()))
        {
            return Some(d);
        }
        // Fallback: digest-only when settle wrote a different/empty attempt_id.
        self.by_digest.get(digest)
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

/// Documented SQL for durable terminal disposition lookup (mirrors MemoryTerminalStore).
/// Prefer (attempt_id, digest); fall back to digest-only for attempt_id drift.
pub fn lookup_sql() -> &'static str {
    r#"
    SELECT disposition, ack_payload
    FROM rust_coord.provider_terminals
    WHERE terminal_digest = $2
      AND (attempt_id = $1 OR attempt_id = '' OR $1 = '')
    ORDER BY CASE WHEN attempt_id = $1 THEN 0 ELSE 1 END
    LIMIT 1
    "#
}

/// Documented SQL for recording a late (unknown) terminal without settling.
pub fn record_late_sql() -> &'static str {
    r#"
    INSERT INTO rust_coord.late_terminals (
      job_id, attempt_id, terminal_digest, se_signature, outcome, seen_at
    ) VALUES ($1, $2, $3, $4, $5, NOW())
    ON CONFLICT (attempt_id, terminal_digest) DO NOTHING
    "#
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

    #[test]
    fn digest_only_fallback_when_attempt_id_differs() {
        let mut store = MemoryTerminalStore::new();
        store.record("", "d-empty", "settled", None);
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "real-attempt".into(),
                terminal_digest: "d-empty".into(),
                se_signature: String::new(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "settled");
        assert_eq!(store.late_count(), 0);
    }

    #[test]
    fn sql_docs_never_settle() {
        assert!(lookup_sql().contains("rust_coord.provider_terminals"));
        assert!(lookup_sql().contains("disposition"));
        assert!(lookup_sql().contains("terminal_digest = $2"));
        assert!(record_late_sql().contains("late_terminals"));
        assert!(record_late_sql().contains("ON CONFLICT"));
        assert!(!record_late_sql().contains("balances"));
        assert!(!lookup_sql().contains("UPDATE balances"));
    }
}
