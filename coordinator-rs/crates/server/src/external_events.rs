//! External-event idempotency (Stripe inbox / plan §12 `external_events`).
//!
//! Process-local mirror of `rust_coord.external_events`. Duplicate
//! `(source, event_id)` must never re-apply side effects. Replay with a
//! mismatched payload digest is Conflict (DECISIONS #46).

use std::collections::HashMap;
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ExternalEventError {
    #[error("empty source, event_id, or payload_digest")]
    InvalidKey,
    #[error("conflict: {0}")]
    Conflict(String),
}

#[derive(Debug, Default)]
pub struct ExternalEventInbox {
    /// (source, event_id) → payload_digest
    seen: HashMap<(String, String), String>,
}

impl ExternalEventInbox {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns `true` if this is the first observation of `(source, event_id)`.
    /// Returns `false` on identical replay (idempotent no-op).
    /// Returns `Conflict` when the same key is replayed with a different digest.
    pub fn observe(
        &mut self,
        source: &str,
        event_id: &str,
        payload_digest: &str,
    ) -> Result<bool, ExternalEventError> {
        if source.is_empty() || event_id.is_empty() || payload_digest.is_empty() {
            return Err(ExternalEventError::InvalidKey);
        }
        let key = (source.to_string(), event_id.to_string());
        match self.seen.get(&key) {
            Some(prev) if prev == payload_digest => Ok(false),
            Some(_) => Err(ExternalEventError::Conflict(format!(
                "external event payload mismatch for {source}/{event_id}"
            ))),
            None => {
                self.seen.insert(key, payload_digest.to_string());
                Ok(true)
            }
        }
    }

    pub fn contains(&self, source: &str, event_id: &str) -> bool {
        self.seen
            .contains_key(&(source.to_string(), event_id.to_string()))
    }

    pub fn payload_digest(&self, source: &str, event_id: &str) -> Option<&str> {
        self.seen
            .get(&(source.to_string(), event_id.to_string()))
            .map(|s| s.as_str())
    }

    /// Remove a previously observed key (compensate after a failed side effect).
    pub fn forget(&mut self, source: &str, event_id: &str) -> bool {
        self.seen
            .remove(&(source.to_string(), event_id.to_string()))
            .is_some()
    }

    pub fn len(&self) -> usize {
        self.seen.len()
    }

    pub fn is_empty(&self) -> bool {
        self.seen.is_empty()
    }
}

/// Documented SQL for durable observe (mirrors ExternalEventInbox).
/// Parameters: $1 source, $2 event_id, $3 payload_digest
///
/// On conflict: identical digest → no-op (no row returned); mismatched digest
/// is detected by the mismatch CTE so callers can surface Conflict (DECISIONS #46).
pub fn observe_sql() -> &'static str {
    r#"
    WITH existing AS (
      SELECT payload_digest
      FROM rust_coord.external_events
      WHERE source = $1 AND event_id = $2
      FOR UPDATE
    ), mismatch AS (
      SELECT 1 FROM existing
      WHERE payload_digest IS DISTINCT FROM $3
    ), evt AS (
      INSERT INTO rust_coord.external_events (source, event_id, payload_digest)
      SELECT $1, $2, $3
      WHERE NOT EXISTS (SELECT 1 FROM existing)
        AND NOT EXISTS (SELECT 1 FROM mismatch)
      ON CONFLICT (source, event_id) DO NOTHING
      RETURNING source, event_id
    )
    SELECT
      (SELECT COUNT(*)::int FROM evt) AS inserted,
      (SELECT COUNT(*)::int FROM mismatch) AS mismatched,
      (SELECT COUNT(*)::int FROM existing) AS existed
    "#
}

/// Documented SQL for compensating a failed post-observe side effect (DECISIONS #22).
/// Only deletes when the event was just observed and credit did not land.
pub fn forget_sql() -> &'static str {
    r#"
    DELETE FROM rust_coord.external_events
    WHERE source = $1
      AND event_id = $2
      AND NOT EXISTS (
        SELECT 1 FROM rust_coord.financial_operations
        WHERE operation_key = 'deposit:' || $1 || ':' || $2
      )
    RETURNING source, event_id
    "#
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_observe_applies_replay_is_noop() {
        let mut inbox = ExternalEventInbox::new();
        assert!(inbox.observe("stripe", "evt_1", "dig-a").unwrap());
        assert!(!inbox.observe("stripe", "evt_1", "dig-a").unwrap());
        assert!(inbox.contains("stripe", "evt_1"));
        assert_eq!(inbox.payload_digest("stripe", "evt_1"), Some("dig-a"));
        assert_eq!(inbox.len(), 1);
    }

    #[test]
    fn mismatched_payload_digest_is_conflict() {
        let mut inbox = ExternalEventInbox::new();
        assert!(inbox.observe("stripe", "evt_1", "dig-a").unwrap());
        assert!(matches!(
            inbox.observe("stripe", "evt_1", "dig-b"),
            Err(ExternalEventError::Conflict(_))
        ));
        assert_eq!(inbox.payload_digest("stripe", "evt_1"), Some("dig-a"));
    }

    #[test]
    fn distinct_sources_same_event_id_are_independent() {
        let mut inbox = ExternalEventInbox::new();
        assert!(inbox.observe("stripe", "evt_1", "d1").unwrap());
        assert!(inbox.observe("connect", "evt_1", "d1").unwrap());
        assert_eq!(inbox.len(), 2);
    }

    #[test]
    fn empty_keys_rejected() {
        let mut inbox = ExternalEventInbox::new();
        assert_eq!(
            inbox.observe("", "evt", "d"),
            Err(ExternalEventError::InvalidKey)
        );
        assert_eq!(
            inbox.observe("stripe", "", "d"),
            Err(ExternalEventError::InvalidKey)
        );
        assert_eq!(
            inbox.observe("stripe", "evt", ""),
            Err(ExternalEventError::InvalidKey)
        );
    }

    #[test]
    fn observe_sql_detects_payload_mismatch() {
        let sql = observe_sql();
        assert!(sql.contains("rust_coord.external_events"));
        assert!(sql.contains("payload_digest"));
        assert!(sql.contains("mismatch"));
        assert!(sql.contains("IS DISTINCT FROM $3"));
        assert!(sql.contains("FOR UPDATE"));
    }

    #[test]
    fn forget_sql_compensates_without_deposit_op() {
        let sql = forget_sql();
        assert!(sql.contains("DELETE FROM rust_coord.external_events"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("deposit:"));
        assert!(sql.contains("RETURNING source, event_id"));
    }

    #[test]
    fn forget_restores_key_for_retry() {
        let mut inbox = ExternalEventInbox::new();
        assert!(inbox.observe("stripe", "evt_x", "d").unwrap());
        assert!(inbox.forget("stripe", "evt_x"));
        assert!(!inbox.contains("stripe", "evt_x"));
        assert!(inbox.observe("stripe", "evt_x", "d").unwrap());
    }
}
