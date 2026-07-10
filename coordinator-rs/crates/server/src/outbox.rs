//! Outbox for durable side effects (plan §12 `rust_coord.outbox`).
//!
//! Process-local queue with bounded retries. Workers claim via
//! `try_claim` (SKIP LOCKED analogue).

use std::collections::VecDeque;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxEntry {
    pub id: u64,
    pub kind: String,
    pub payload: String,
    pub attempts: u32,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum OutboxError {
    #[error("empty kind")]
    InvalidKind,
    #[error("queue full")]
    Full,
}

const DEFAULT_MAX: usize = 10_000;
const MAX_ATTEMPTS: u32 = 100;

#[derive(Debug)]
pub struct Outbox {
    next_id: u64,
    max: usize,
    pending: VecDeque<OutboxEntry>,
}

impl Default for Outbox {
    fn default() -> Self {
        Self::new(DEFAULT_MAX)
    }
}

impl Outbox {
    pub fn new(max: usize) -> Self {
        Self {
            next_id: 1,
            max: max.max(1),
            pending: VecDeque::new(),
        }
    }

    pub fn enqueue(&mut self, kind: &str, payload: &str) -> Result<u64, OutboxError> {
        if kind.is_empty() {
            return Err(OutboxError::InvalidKind);
        }
        if self.pending.len() >= self.max {
            return Err(OutboxError::Full);
        }
        let id = self.next_id;
        self.next_id += 1;
        self.pending.push_back(OutboxEntry {
            id,
            kind: kind.to_string(),
            payload: payload.to_string(),
            attempts: 0,
        });
        Ok(id)
    }

    /// Claim the next entry with attempts < MAX_ATTEMPTS (SKIP LOCKED analogue).
    pub fn try_claim(&mut self) -> Option<OutboxEntry> {
        let idx = self
            .pending
            .iter()
            .position(|e| e.attempts < MAX_ATTEMPTS)?;
        let mut entry = self.pending.remove(idx)?;
        entry.attempts += 1;
        Some(entry)
    }

    /// Re-queue after a failed delivery (keeps attempt count).
    pub fn requeue(&mut self, entry: OutboxEntry) -> Result<(), OutboxError> {
        if self.pending.len() >= self.max {
            return Err(OutboxError::Full);
        }
        self.pending.push_back(entry);
        Ok(())
    }

    /// Drop a successfully delivered entry (already removed by try_claim).
    pub fn ack_done(&self, _id: u64) {
        // Entry was removed on claim; success path is a no-op.
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    pub fn pending_under_retry_cap(&self) -> usize {
        self.pending
            .iter()
            .filter(|e| e.attempts < MAX_ATTEMPTS)
            .count()
    }
}

/// Documented SQL for durable enqueue.
pub fn enqueue_sql() -> &'static str {
    r#"
    INSERT INTO rust_coord.outbox (kind, payload, attempts)
    VALUES ($1, $2::jsonb, 0)
    RETURNING id
    "#
}

/// Documented SQL for SKIP LOCKED claim.
pub fn claim_sql() -> &'static str {
    r#"
    UPDATE rust_coord.outbox o
    SET attempts = o.attempts + 1
    WHERE o.id = (
      SELECT id FROM rust_coord.outbox
      WHERE attempts < 100
      ORDER BY id
      FOR UPDATE SKIP LOCKED
      LIMIT 1
    )
    RETURNING o.id, o.kind, o.payload, o.attempts
    "#
}

/// Documented SQL for durable ack after successful side-effect delivery.
pub fn ack_done_sql() -> &'static str {
    r#"
    DELETE FROM rust_coord.outbox
    WHERE id = $1
    "#
}

/// Documented SQL for requeue after transient side-effect failure.
pub fn requeue_sql() -> &'static str {
    r#"
    UPDATE rust_coord.outbox
    SET available_at = NOW() + ($2::int * INTERVAL '1 second')
    WHERE id = $1
      AND attempts < 100
    "#
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enqueue_claim_ack_drains() {
        let mut box_ = Outbox::new(10);
        let id = box_.enqueue("telemetry", r#"{"k":1}"#).unwrap();
        assert_eq!(id, 1);
        let e = box_.try_claim().unwrap();
        assert_eq!(e.id, 1);
        assert_eq!(e.attempts, 1);
        assert!(box_.is_empty());
        box_.ack_done(e.id);
    }

    #[test]
    fn requeue_preserves_attempts() {
        let mut box_ = Outbox::new(10);
        box_.enqueue("x", "{}").unwrap();
        let e = box_.try_claim().unwrap();
        assert_eq!(e.attempts, 1);
        box_.requeue(e).unwrap();
        let e2 = box_.try_claim().unwrap();
        assert_eq!(e2.attempts, 2);
    }

    #[test]
    fn full_queue_rejects() {
        let mut box_ = Outbox::new(2);
        box_.enqueue("a", "{}").unwrap();
        box_.enqueue("b", "{}").unwrap();
        assert_eq!(box_.enqueue("c", "{}"), Err(OutboxError::Full));
    }

    #[test]
    fn empty_kind_rejected() {
        let mut box_ = Outbox::default();
        assert_eq!(box_.enqueue("", "{}"), Err(OutboxError::InvalidKind));
    }

    #[test]
    fn sql_docs_mention_skip_locked() {
        assert!(claim_sql().contains("SKIP LOCKED"));
        assert!(enqueue_sql().contains("rust_coord.outbox"));
        assert!(ack_done_sql().contains("DELETE FROM rust_coord.outbox"));
        assert!(requeue_sql().contains("available_at"));
        assert!(requeue_sql().contains("attempts < 100"));
    }
}
