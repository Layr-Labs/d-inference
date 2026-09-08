//! Attempt routing table and the zombie-stream canceller (plan §7.4).
//!
//! The table maps wire ids (v1 `request_id`, v2 `attempt_id` in canonical
//! UUID form) to the request task's sinks, the outbound scope binding the
//! writer recorded when it sent the v2 prepare (the epoch/nonce/digest
//! every inbound frame must echo — plan §10.2), and the abort tombstone.
//! Shared between the writer (binds on send) and the reader (validates and
//! routes) behind a plain mutex: every critical section is a map touch,
//! never an await.
//!
//! Attach also reserves ONE event-channel permit per attempt: when the
//! bounded events lane overflows, that permit is the guaranteed path for
//! exactly one terminal-class event (plan §9.4.5 — terminal/cancel-class
//! events are never silently dropped; the naive fallback of `try_send`ing
//! `SessionLost` into the same full channel provably cannot deliver).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::mpsc::OwnedPermit;

use darkbloom_core::ids::AttemptId;
use darkbloom_protocol::json_v2;

use crate::contracts::{AttemptEvent, AttemptSinks};

/// What the writer recorded when it dispatched the attempt's prepare.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ScopeBinding {
    pub nonce: json_v2::DispatchNonce,
    pub digest: json_v2::RequestDigest,
}

#[derive(Default)]
pub(crate) struct AttemptEntry {
    pub attempt: Option<AttemptId>,
    pub sinks: Option<AttemptSinks>,
    /// One events-lane permit reserved at attach: the guaranteed slot for
    /// exactly one terminal-class event on lane overflow (plan §9.4.5).
    pub reserved: Option<OwnedPermit<AttemptEvent>>,
    pub binding: Option<ScopeBinding>,
    /// Reason from the coordinator's outbound `abort`, recorded by the
    /// writer so the provider's bare `aborted` acknowledgement can carry it
    /// back to the request task.
    pub pending_abort_reason: Option<json_v2::AbortReason>,
    /// Set when the provider acknowledged `aborted`: the lease is
    /// tombstoned provider-side, so a later `started` is dropped (§10.3).
    pub tombstoned: bool,
}

#[derive(Default)]
pub(crate) struct AttemptTable {
    entries: HashMap<String, AttemptEntry>,
}

pub(crate) type SharedAttempts = Arc<Mutex<AttemptTable>>;

pub(crate) fn shared() -> SharedAttempts {
    Arc::new(Mutex::new(AttemptTable::default()))
}

impl AttemptTable {
    pub fn attach(&mut self, wire_id: String, attempt: AttemptId, sinks: AttemptSinks) {
        // Reserve the terminal-class slot up front, while the fresh channel
        // is guaranteed to have room; a failure here (already-full or
        // closed channel at attach) degrades to the lossy legacy fallback.
        let reserved = sinks.events.clone().try_reserve_owned().ok();
        let entry = self.entries.entry(wire_id).or_default();
        entry.attempt = Some(attempt);
        entry.sinks = Some(sinks);
        entry.reserved = reserved;
    }

    pub fn detach(&mut self, wire_id: &str) {
        self.entries.remove(wire_id);
    }

    pub fn bind(&mut self, wire_id: String, binding: ScopeBinding) {
        self.entries.entry(wire_id).or_default().binding = Some(binding);
    }

    pub fn record_abort_reason(&mut self, wire_id: String, reason: json_v2::AbortReason) {
        self.entries
            .entry(wire_id)
            .or_default()
            .pending_abort_reason = Some(reason);
    }

    pub fn entry_mut(&mut self, wire_id: &str) -> Option<&mut AttemptEntry> {
        self.entries.get_mut(wire_id)
    }

    pub fn tombstone(&mut self, wire_id: &str) {
        self.entries
            .entry(wire_id.to_owned())
            .or_default()
            .tombstoned = true;
    }

    fn drain_sinks(&mut self) -> Vec<(AttemptSinks, Option<OwnedPermit<AttemptEvent>>)> {
        self.entries
            .drain()
            .filter_map(|(_, entry)| entry.sinks.map(|sinks| (sinks, entry.reserved)))
            .collect()
    }
}

/// Removes and returns every attached sink with its reserved terminal-slot
/// permit (session teardown: each one gets `AttemptEvent::SessionLost`, via
/// the permit when the lane is full). Poisoning cannot happen — no panics
/// occur under the lock — but fail safe rather than propagate.
pub(crate) fn take_all_sinks(
    attempts: &SharedAttempts,
) -> Vec<(AttemptSinks, Option<OwnedPermit<AttemptEvent>>)> {
    match attempts.lock() {
        Ok(mut table) => table.drain_sinks(),
        Err(poisoned) => poisoned.into_inner().drain_sinks(),
    }
}

/// Locks the table, absorbing poison the same way.
pub(crate) fn lock(attempts: &SharedAttempts) -> std::sync::MutexGuard<'_, AttemptTable> {
    match attempts.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// Throttles cancels for chunks that arrive for a request this session does
/// not track (consumer gone / already settled). Line-for-line port of Go
/// `zombieStreamCanceller` (api/zombie_stream.go): one cancel per request
/// per throttle window, bounded map with opportunistic sweep.
pub(crate) struct ZombieCanceller {
    throttle: Duration,
    max_entries: usize,
    sent: HashMap<String, Instant>,
}

impl ZombieCanceller {
    pub fn new(throttle: Duration) -> Self {
        Self {
            throttle,
            max_entries: 4096,
            sent: HashMap::new(),
        }
    }

    pub fn should_cancel(&mut self, wire_id: &str, now: Instant) -> bool {
        if let Some(&sent_at) = self.sent.get(wire_id) {
            if now.duration_since(sent_at) < self.throttle {
                return false;
            }
            self.sent.remove(wire_id);
        }
        if self.sent.len() >= self.max_entries {
            let throttle = self.throttle;
            self.sent
                .retain(|_, &mut sent_at| now.duration_since(sent_at) <= throttle);
            if self.sent.len() >= self.max_entries {
                if let Some(oldest) = self
                    .sent
                    .iter()
                    .min_by_key(|(_, &at)| at)
                    .map(|(id, _)| id.clone())
                {
                    self.sent.remove(&oldest);
                }
            }
        }
        self.sent.insert(wire_id.to_owned(), now);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zombie_canceller_throttles_per_request() {
        let mut z = ZombieCanceller::new(Duration::from_secs(10));
        let t0 = Instant::now();
        assert!(z.should_cancel("r1", t0));
        assert!(!z.should_cancel("r1", t0 + Duration::from_secs(5)));
        assert!(z.should_cancel("r2", t0 + Duration::from_secs(5)));
        assert!(z.should_cancel("r1", t0 + Duration::from_secs(11)));
    }

    #[test]
    fn zombie_canceller_stays_bounded() {
        let mut z = ZombieCanceller::new(Duration::from_secs(10));
        z.max_entries = 8;
        let t0 = Instant::now();
        for i in 0..64 {
            assert!(z.should_cancel(&format!("r{i}"), t0));
        }
        assert!(z.sent.len() <= 8);
    }

    #[test]
    fn tombstone_survives_until_detach() {
        let mut table = AttemptTable::default();
        table.tombstone("a1");
        assert!(table.entry_mut("a1").is_some_and(|e| e.tombstoned));
        table.detach("a1");
        assert!(table.entry_mut("a1").is_none());
    }
}
