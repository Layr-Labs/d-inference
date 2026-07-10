//! External-event idempotency (Stripe inbox / plan §12 `external_events`).
//!
//! Process-local mirror of `rust_coord.external_events`. Duplicate
//! `(source, event_id)` must never re-apply side effects.

use std::collections::HashSet;
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ExternalEventError {
    #[error("empty source or event_id")]
    InvalidKey,
    #[error("conflict: {0}")]
    Conflict(String),
}

#[derive(Debug, Default)]
pub struct ExternalEventInbox {
    seen: HashSet<(String, String)>,
}

impl ExternalEventInbox {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns `true` if this is the first observation of `(source, event_id)`.
    /// Returns `false` on replay (idempotent no-op).
    pub fn observe(&mut self, source: &str, event_id: &str) -> Result<bool, ExternalEventError> {
        if source.is_empty() || event_id.is_empty() {
            return Err(ExternalEventError::InvalidKey);
        }
        Ok(self.seen.insert((source.to_string(), event_id.to_string())))
    }

    pub fn contains(&self, source: &str, event_id: &str) -> bool {
        self.seen
            .contains(&(source.to_string(), event_id.to_string()))
    }

    /// Remove a previously observed key (compensate after a failed side effect).
    pub fn forget(&mut self, source: &str, event_id: &str) -> bool {
        self.seen
            .remove(&(source.to_string(), event_id.to_string()))
    }

    pub fn len(&self) -> usize {
        self.seen.len()
    }

    pub fn is_empty(&self) -> bool {
        self.seen.is_empty()
    }
}

/// Documented SQL for durable observe (mirrors ExternalEventInbox).
pub fn observe_sql() -> &'static str {
    r#"
    INSERT INTO rust_coord.external_events (source, event_id, payload_digest)
    VALUES ($1, $2, $3)
    ON CONFLICT (source, event_id) DO NOTHING
    RETURNING source, event_id
    "#
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_observe_applies_replay_is_noop() {
        let mut inbox = ExternalEventInbox::new();
        assert!(inbox.observe("stripe", "evt_1").unwrap());
        assert!(!inbox.observe("stripe", "evt_1").unwrap());
        assert!(inbox.contains("stripe", "evt_1"));
        assert_eq!(inbox.len(), 1);
    }

    #[test]
    fn distinct_sources_same_event_id_are_independent() {
        let mut inbox = ExternalEventInbox::new();
        assert!(inbox.observe("stripe", "evt_1").unwrap());
        assert!(inbox.observe("connect", "evt_1").unwrap());
        assert_eq!(inbox.len(), 2);
    }

    #[test]
    fn empty_keys_rejected() {
        let mut inbox = ExternalEventInbox::new();
        assert_eq!(
            inbox.observe("", "evt"),
            Err(ExternalEventError::InvalidKey)
        );
        assert_eq!(
            inbox.observe("stripe", ""),
            Err(ExternalEventError::InvalidKey)
        );
    }

    #[test]
    fn observe_sql_is_idempotent_insert() {
        let sql = observe_sql();
        assert!(sql.contains("rust_coord.external_events"));
        assert!(sql.contains("ON CONFLICT"));
        assert!(sql.contains("DO NOTHING"));
    }
}
