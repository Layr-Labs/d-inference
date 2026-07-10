//! Outbox for durable side effects (plan §12 `rust_coord.outbox`).
//!
//! Process-local queue with bounded retries. Workers claim via
//! `try_claim` (SKIP LOCKED analogue). Claims are non-destructive until
//! `ack_done` (DECISIONS #35) so quiescence cannot go ready mid-delivery.

use std::collections::{HashMap, VecDeque};
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
    #[error("unknown in-flight id")]
    UnknownId,
}

const DEFAULT_MAX: usize = 10_000;
const MAX_ATTEMPTS: u32 = 100;

#[derive(Debug)]
pub struct Outbox {
    next_id: u64,
    max: usize,
    pending: VecDeque<OutboxEntry>,
    /// Claimed but not yet acked — still blocks quiescence.
    in_flight: HashMap<u64, OutboxEntry>,
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
            in_flight: HashMap::new(),
        }
    }

    fn occupied(&self) -> usize {
        self.pending.len() + self.in_flight.len()
    }

    pub fn enqueue(&mut self, kind: &str, payload: &str) -> Result<u64, OutboxError> {
        if kind.is_empty() {
            return Err(OutboxError::InvalidKind);
        }
        if self.occupied() >= self.max {
            return Err(OutboxError::Full);
        }
        Ok(self.push(kind, payload))
    }

    /// Money-critical side effects must never be dropped when the bounded queue
    /// is full (DECISIONS #32). Extends past `max` so quiescence still blocks.
    pub fn enqueue_critical(&mut self, kind: &str, payload: &str) -> Result<u64, OutboxError> {
        if kind.is_empty() {
            return Err(OutboxError::InvalidKind);
        }
        Ok(self.push(kind, payload))
    }

    /// Enqueue a critical `inference.released` side effect (DECISIONS #43).
    pub fn enqueue_released(
        &mut self,
        job_id: &str,
        account: &str,
        refunded_micro_usd: i64,
    ) -> Result<u64, OutboxError> {
        self.enqueue_critical(
            "inference.released",
            &serde_json::json!({
                "job_id": job_id,
                "account": account,
                "disposition": "released",
                "refunded_micro_usd": refunded_micro_usd,
            })
            .to_string(),
        )
    }

    fn push(&mut self, kind: &str, payload: &str) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        self.pending.push_back(OutboxEntry {
            id,
            kind: kind.to_string(),
            payload: payload.to_string(),
            attempts: 0,
        });
        id
    }

    /// Claim the next available entry (SKIP LOCKED analogue).
    /// Moves it to `in_flight` — must `ack_done` or `requeue` (DECISIONS #35).
    pub fn try_claim(&mut self) -> Option<OutboxEntry> {
        let idx = self
            .pending
            .iter()
            .position(|e| e.attempts < MAX_ATTEMPTS)?;
        let mut entry = self.pending.remove(idx)?;
        entry.attempts += 1;
        self.in_flight.insert(entry.id, entry.clone());
        Some(entry)
    }

    /// Re-queue after a failed delivery (keeps attempt count).
    pub fn requeue(&mut self, entry: OutboxEntry) -> Result<(), OutboxError> {
        let was_inflight = self.in_flight.remove(&entry.id).is_some();
        if self.occupied() >= self.max {
            if was_inflight {
                self.in_flight.insert(entry.id, entry);
            }
            return Err(OutboxError::Full);
        }
        self.pending.push_back(entry);
        Ok(())
    }

    /// Drop a successfully delivered entry (removes from in_flight).
    pub fn ack_done(&mut self, id: u64) -> Result<(), OutboxError> {
        if self.in_flight.remove(&id).is_some() {
            Ok(())
        } else {
            Err(OutboxError::UnknownId)
        }
    }

    pub fn len(&self) -> usize {
        self.occupied()
    }

    pub fn is_empty(&self) -> bool {
        self.occupied() == 0
    }

    pub fn pending_under_retry_cap(&self) -> usize {
        let pending = self
            .pending
            .iter()
            .filter(|e| e.attempts < MAX_ATTEMPTS)
            .count();
        let inflight = self
            .in_flight
            .values()
            .filter(|e| e.attempts < MAX_ATTEMPTS)
            .count();
        pending + inflight
    }

    /// Entries at/above the retry cap — still occupy the queue but are not
    /// claimable by the best-effort worker (DECISIONS #133).
    pub fn pending_blocked(&self) -> usize {
        let pending = self
            .pending
            .iter()
            .filter(|e| e.attempts >= MAX_ATTEMPTS)
            .count();
        let inflight = self
            .in_flight
            .values()
            .filter(|e| e.attempts >= MAX_ATTEMPTS)
            .count();
        pending + inflight
    }

    pub fn in_flight_len(&self) -> usize {
        self.in_flight.len()
    }

    /// Pilot/cutover: claim all pending and ack everything in-flight (DECISIONS #82).
    /// Returns (acked_count, kinds). Does not requeue.
    pub fn drain_ack_all(&mut self) -> (usize, Vec<String>) {
        let mut kinds = Vec::new();
        while let Some(kind) = self.drain_ack_one() {
            kinds.push(kind);
        }
        (kinds.len(), kinds)
    }

    /// Claim+ack a single pending entry, or ack one pre-existing in-flight.
    /// Returns the kind when an entry was drained, else None when empty.
    /// Exhausted (attempts >= MAX) pending rows are force-acked so cutover
    /// drain can clear the queue (DECISIONS #133).
    pub fn drain_ack_one(&mut self) -> Option<String> {
        if let Some(e) = self.try_claim() {
            let kind = e.kind.clone();
            let _ = self.ack_done(e.id);
            return Some(kind);
        }
        if let Some(id) = self.in_flight.keys().next().copied() {
            let kind = self.in_flight.get(&id).map(|e| e.kind.clone())?;
            let _ = self.ack_done(id);
            return Some(kind);
        }
        // Stuck/exhausted pending — admin drain drops them so ready can clear.
        let e = self.pending.pop_front()?;
        Some(e.kind)
    }

    /// Test helper: bump a pending entry to the retry cap via claim+requeue.
    pub fn force_exhaust_one_for_test(&mut self) -> bool {
        let Some(mut e) = self.try_claim() else {
            return false;
        };
        e.attempts = MAX_ATTEMPTS;
        self.in_flight.remove(&e.id);
        self.pending.push_back(e);
        true
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
/// Claim increments attempts in-place; row remains until ack_done DELETE.
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

/// Documented SQL for pilot cutover drain: claim+ack all retryable rows
/// (DECISIONS #82/#87). Prefer a single transaction in SQLx.
pub fn drain_ack_all_sql() -> &'static str {
    r#"
    WITH claimed AS (
      UPDATE rust_coord.outbox o
      SET attempts = o.attempts + 1
      WHERE o.id IN (
        SELECT id FROM rust_coord.outbox
        WHERE attempts < 100
        ORDER BY id
        FOR UPDATE SKIP LOCKED
      )
      RETURNING o.id
    )
    DELETE FROM rust_coord.outbox
    WHERE id IN (SELECT id FROM claimed)
    RETURNING id
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
        assert_eq!(box_.in_flight_len(), 1);
        assert!(!box_.is_empty());
        box_.ack_done(e.id).unwrap();
        assert!(box_.is_empty());
    }

    #[test]
    fn claim_without_ack_still_blocks_retryable() {
        let mut box_ = Outbox::new(10);
        box_.enqueue("billing.deposit_applied", "{}").unwrap();
        let e = box_.try_claim().unwrap();
        assert_eq!(box_.pending_under_retry_cap(), 1);
        assert_eq!(box_.in_flight_len(), 1);
        box_.ack_done(e.id).unwrap();
        assert_eq!(box_.pending_under_retry_cap(), 0);
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
        box_.ack_done(e2.id).unwrap();
    }

    #[test]
    fn full_queue_rejects() {
        let mut box_ = Outbox::new(2);
        box_.enqueue("a", "{}").unwrap();
        box_.enqueue("b", "{}").unwrap();
        assert_eq!(box_.enqueue("c", "{}"), Err(OutboxError::Full));
    }

    #[test]
    fn enqueue_released_is_critical_kind() {
        let mut box_ = Outbox::new(1);
        box_.enqueue("fill", "{}").unwrap();
        let id = box_.enqueue_released("j1", "acct", 42_000).unwrap();
        assert_eq!(id, 2);
        assert_eq!(box_.len(), 2);
        let e = box_.try_claim().unwrap();
        // FIFO: fill first
        assert_eq!(e.kind, "fill");
        box_.ack_done(e.id).unwrap();
        let e2 = box_.try_claim().unwrap();
        assert_eq!(e2.kind, "inference.released");
        assert!(e2.payload.contains("42000"));
    }

    #[test]
    fn enqueue_critical_extends_past_capacity() {
        let mut box_ = Outbox::new(1);
        box_.enqueue("a", "{}").unwrap();
        assert_eq!(box_.enqueue("b", "{}"), Err(OutboxError::Full));
        let id = box_
            .enqueue_critical("billing.deposit_applied", r#"{"n":1}"#)
            .unwrap();
        assert_eq!(id, 2);
        assert_eq!(box_.len(), 2);
        assert_eq!(box_.pending_under_retry_cap(), 2);
        assert_eq!(
            box_.enqueue_critical("", "{}"),
            Err(OutboxError::InvalidKind)
        );
    }

    #[test]
    fn empty_kind_rejected() {
        let mut box_ = Outbox::default();
        assert_eq!(box_.enqueue("", "{}"), Err(OutboxError::InvalidKind));
    }

    #[test]
    fn drain_ack_all_clears_pending_and_inflight() {
        let mut box_ = Outbox::new(10);
        box_.enqueue_critical("inference.released", "{}").unwrap();
        box_.enqueue_critical("inference.settled", "{}").unwrap();
        let _ = box_.try_claim(); // one in-flight
        let (n, kinds) = box_.drain_ack_all();
        assert_eq!(n, 2);
        assert!(kinds.contains(&"inference.released".to_string()));
        assert!(kinds.contains(&"inference.settled".to_string()));
        assert!(box_.is_empty());
        assert_eq!(box_.pending_under_retry_cap(), 0);
    }

    #[test]
    fn sql_docs_mention_skip_locked() {
        assert!(claim_sql().contains("SKIP LOCKED"));
        assert!(enqueue_sql().contains("rust_coord.outbox"));
        assert!(ack_done_sql().contains("DELETE FROM rust_coord.outbox"));
        assert!(requeue_sql().contains("available_at"));
        assert!(requeue_sql().contains("attempts < 100"));
        assert!(drain_ack_all_sql().contains("SKIP LOCKED"));
        assert!(drain_ack_all_sql().contains("DELETE FROM rust_coord.outbox"));
    }

    #[test]
    fn exhausted_pending_blocks_len_but_not_retryable() {
        let mut box_ = Outbox::new(10);
        box_
            .enqueue_critical("billing.deposit_applied", r#"{"e":1}"#)
            .unwrap();
        assert!(box_.force_exhaust_one_for_test());
        assert_eq!(box_.len(), 1);
        assert_eq!(box_.pending_under_retry_cap(), 0);
        assert_eq!(box_.pending_blocked(), 1);
        assert!(box_.try_claim().is_none());
    }

    #[test]
    fn drain_ack_clears_exhausted_pending() {
        let mut box_ = Outbox::new(10);
        box_
            .enqueue_critical("inference.settled", r#"{"e":1}"#)
            .unwrap();
        assert!(box_.force_exhaust_one_for_test());
        assert_eq!(box_.pending_blocked(), 1);
        let (n, kinds) = box_.drain_ack_all();
        assert_eq!(n, 1);
        assert_eq!(kinds, vec!["inference.settled".to_string()]);
        assert!(box_.is_empty());
        assert_eq!(box_.pending_blocked(), 0);
    }
}
