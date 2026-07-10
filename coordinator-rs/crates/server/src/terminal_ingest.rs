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
    /// Funded lease that produced this terminal (DECISIONS #53). Empty = unbound.
    pub lease_id: String,
    pub se_signature: String,
    pub outcome: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalDisposition {
    pub disposition: String,
    /// Job that owns this terminal (DECISIONS #45). Empty = legacy unbound.
    pub job_id: String,
    /// Lease that owns this terminal (DECISIONS #53). Empty = legacy unbound.
    pub lease_id: String,
    /// Provider SE signature material (DECISIONS #51/#53). Empty = unbound.
    pub se_signature: String,
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
        job_id: &str,
        attempt_id: &str,
        digest: &str,
        disposition: &str,
        ack: Option<Value>,
    ) {
        self.record_bound(job_id, attempt_id, digest, disposition, ack, "", "");
    }

    /// Record a disposition bound to the funded lease + SE signature (DECISIONS #53).
    pub fn record_bound(
        &mut self,
        job_id: &str,
        attempt_id: &str,
        digest: &str,
        disposition: &str,
        ack: Option<Value>,
        lease_id: &str,
        se_signature: &str,
    ) {
        let disp = TerminalDisposition {
            disposition: disposition.to_string(),
            job_id: job_id.to_string(),
            lease_id: lease_id.to_string(),
            se_signature: se_signature.to_string(),
            ack_payload: ack,
        };
        self.by_attempt_digest.insert(
            (attempt_id.to_string(), digest.to_string()),
            disp.clone(),
        );
        self.by_digest.insert(digest.to_string(), disp);
    }

    pub fn lookup(
        &self,
        job_id: &str,
        attempt_id: &str,
        digest: &str,
    ) -> Option<&TerminalDisposition> {
        let candidate = self
            .by_attempt_digest
            .get(&(attempt_id.to_string(), digest.to_string()))
            .or_else(|| self.by_digest.get(digest))?;
        // Job-bound: known digest with wrong job is not a match (DECISIONS #45).
        if !candidate.job_id.is_empty() && !job_id.is_empty() && candidate.job_id != job_id {
            return None;
        }
        Some(candidate)
    }

    /// True when digest is known but bound to a different job_id.
    pub fn job_mismatch(&self, job_id: &str, digest: &str) -> bool {
        match self.by_digest.get(digest) {
            Some(d) if !d.job_id.is_empty() && !job_id.is_empty() && d.job_id != job_id => true,
            _ => false,
        }
    }

    /// True when digest is known but bound to a different lease_id (DECISIONS #53).
    pub fn lease_mismatch(&self, lease_id: &str, digest: &str) -> bool {
        match self.by_digest.get(digest) {
            Some(d)
                if !d.lease_id.is_empty() && !lease_id.is_empty() && d.lease_id != lease_id =>
            {
                true
            }
            _ => false,
        }
    }

    /// True when digest is known but bound to a different se_signature (DECISIONS #53).
    pub fn se_signature_mismatch(&self, se_signature: &str, digest: &str) -> bool {
        match self.by_digest.get(digest) {
            Some(d)
                if !d.se_signature.is_empty()
                    && !se_signature.is_empty()
                    && d.se_signature != se_signature =>
            {
                true
            }
            _ => false,
        }
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
    if store.job_mismatch(&t.job_id, &t.terminal_digest)
        || store.lease_mismatch(&t.lease_id, &t.terminal_digest)
        || store.se_signature_mismatch(&t.se_signature, &t.terminal_digest)
    {
        // Digest known under another job/lease/signature — never ACK as settled.
        return Ok(json!({
            "type": "terminal_ack",
            "job_id": t.job_id,
            "attempt_id": t.attempt_id,
            "lease_id": t.lease_id,
            "terminal_digest": t.terminal_digest,
            "disposition": "conflict",
        }));
    }
    if let Some(disp) = store.lookup(&t.job_id, &t.attempt_id, &t.terminal_digest) {
        if let Some(ack) = &disp.ack_payload {
            return Ok(ack.clone());
        }
        let job = if !disp.job_id.is_empty() {
            disp.job_id.as_str()
        } else {
            t.job_id.as_str()
        };
        let lease = if !disp.lease_id.is_empty() {
            disp.lease_id.as_str()
        } else {
            t.lease_id.as_str()
        };
        return Ok(json!({
            "type": "terminal_ack",
            "job_id": job,
            "attempt_id": t.attempt_id,
            "lease_id": lease,
            "terminal_digest": t.terminal_digest,
            "disposition": disp.disposition,
        }));
    }
    store.record_late(t.clone());
    Ok(json!({
        "type": "terminal_ack",
        "job_id": t.job_id,
        "attempt_id": t.attempt_id,
        "lease_id": t.lease_id,
        "terminal_digest": t.terminal_digest,
        "disposition": "late",
    }))
}

/// Documented SQL for durable terminal disposition lookup (mirrors MemoryTerminalStore).
/// Prefer (attempt_id, digest); fall back to digest-only for attempt_id drift.
/// Job_id must match when both sides are non-empty (DECISIONS #45).
/// Lease_id / se_signature must match when both sides are non-empty (DECISIONS #53).
pub fn lookup_sql() -> &'static str {
    r#"
    SELECT disposition, ack_payload, job_id, lease_id, se_signature
    FROM rust_coord.provider_terminals
    WHERE terminal_digest = $2
      AND (job_id = $3 OR job_id = '' OR $3 = '')
      AND (attempt_id = $1 OR attempt_id = '' OR $1 = '')
      AND (lease_id = $4 OR lease_id = '' OR $4 = '')
      AND (se_signature = $5 OR se_signature = '' OR $5 = '')
    ORDER BY CASE WHEN attempt_id = $1 THEN 0 ELSE 1 END,
             CASE WHEN job_id = $3 THEN 0 ELSE 1 END,
             CASE WHEN lease_id = $4 THEN 0 ELSE 1 END
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
        store.record("j1", "a1", "d1", "settled", None);
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                lease_id: String::new(),
                se_signature: String::new(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "settled");
        assert_eq!(ack["type"], "terminal_ack");
        assert_eq!(ack["job_id"], "j1");
        assert_eq!(store.late_count(), 0);
    }

    #[test]
    fn wrong_job_id_returns_conflict_not_settled() {
        let mut store = MemoryTerminalStore::new();
        store.record("j-real", "a1", "d1", "settled", None);
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j-attacker".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                lease_id: String::new(),
                se_signature: String::new(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "conflict");
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
                lease_id: String::new(),
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
                    lease_id: String::new(),
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
        let custom = json!({"type":"terminal_ack","custom":true,"job_id":"j1"});
        store.record("j1", "a1", "d1", "settled", Some(custom.clone()));
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                lease_id: String::new(),
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
        store.record("j1", "", "d-empty", "settled", None);
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "real-attempt".into(),
                terminal_digest: "d-empty".into(),
                lease_id: String::new(),
                se_signature: String::new(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "settled");
        assert_eq!(store.late_count(), 0);
    }

    #[test]
    fn wrong_lease_id_returns_conflict_not_settled() {
        let mut store = MemoryTerminalStore::new();
        store.record_bound("j1", "a1", "d1", "settled", None, "lease-real", "");
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                lease_id: "lease-attacker".into(),
                se_signature: String::new(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "conflict");
        assert_eq!(store.late_count(), 0);
    }

    #[test]
    fn wrong_se_signature_returns_conflict_not_settled() {
        let mut store = MemoryTerminalStore::new();
        store.record_bound("j1", "a1", "d1", "settled", None, "l1", "sig-real");
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                lease_id: "l1".into(),
                se_signature: "sig-attacker".into(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "conflict");
        assert_eq!(store.late_count(), 0);
    }

    #[test]
    fn matching_lease_and_signature_acks_settled() {
        let mut store = MemoryTerminalStore::new();
        store.record_bound("j1", "a1", "d1", "settled", None, "l1", "sig1");
        let ack = ingest_terminal(
            &mut store,
            TerminalIngest {
                job_id: "j1".into(),
                attempt_id: "a1".into(),
                terminal_digest: "d1".into(),
                lease_id: "l1".into(),
                se_signature: "sig1".into(),
                outcome: "ok".into(),
            },
        )
        .unwrap();
        assert_eq!(ack["disposition"], "settled");
        assert_eq!(ack["lease_id"], "l1");
    }

    #[test]
    fn sql_docs_never_settle_and_bind_job() {
        assert!(lookup_sql().contains("rust_coord.provider_terminals"));
        assert!(lookup_sql().contains("disposition"));
        assert!(lookup_sql().contains("terminal_digest = $2"));
        assert!(lookup_sql().contains("job_id = $3"));
        assert!(lookup_sql().contains("lease_id = $4"));
        assert!(lookup_sql().contains("se_signature = $5"));
        assert!(record_late_sql().contains("late_terminals"));
        assert!(record_late_sql().contains("ON CONFLICT"));
        assert!(!record_late_sql().contains("balances"));
        assert!(!lookup_sql().contains("UPDATE balances"));
    }
}
