//! Single-active coordinator fencing epoch (plan §20 / M0.7 + M4).
//!
//! Process-local `Gate` is the admission fence. `LocalOwnershipStore` is the
//! in-process durable-table analogue (CAS acquire / heartbeat / release) used
//! until SQLx wires the same SQL against Postgres (DECISIONS #36).

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum OwnershipError {
    #[error("coordinator ownership lost")]
    OwnershipLost,
    #[error("unsafe startup: active rust_coord jobs or leases")]
    UnsafeStartup,
    #[error("ownership acquire conflict")]
    AcquireConflict,
}

/// Monotonically increasing coordinator fencing token.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Epoch(pub u64);

/// Process-local ownership gate.
pub struct Gate {
    inner: Mutex<GateInner>,
    epoch: AtomicU64,
    holding: AtomicBool,
}

struct GateInner {
    recovery_mode: bool,
    refuse_on_rust: bool,
    rust_active: bool,
}

impl Gate {
    /// `refuse_on_rust` should be true once Rust schema objects may exist and
    /// this process must not admit work over active Rust durable jobs.
    pub fn new(refuse_on_rust: bool) -> Self {
        Self {
            inner: Mutex::new(GateInner {
                recovery_mode: false,
                refuse_on_rust,
                rust_active: false,
            }),
            epoch: AtomicU64::new(0),
            holding: AtomicBool::new(false),
        }
    }

    pub fn set_rust_active(&self, active: bool) {
        let mut g = self.inner.lock().expect("ownership gate poisoned");
        g.rust_active = active;
    }

    /// Allow recovery-only settle/release without admitting new consumer traffic.
    pub fn enable_recovery_mode(&self) {
        let mut g = self.inner.lock().expect("ownership gate poisoned");
        g.recovery_mode = true;
    }

    /// Record that this process holds `fencing_epoch`. Callers must obtain the
    /// durable lock/lease in the same transaction that bumps the epoch first.
    pub fn acquire(&self, fencing_epoch: Epoch) -> Result<(), OwnershipError> {
        let g = self.inner.lock().expect("ownership gate poisoned");
        if g.refuse_on_rust && g.rust_active && !g.recovery_mode {
            return Err(OwnershipError::UnsafeStartup);
        }
        self.epoch.store(fencing_epoch.0, Ordering::SeqCst);
        self.holding.store(true, Ordering::SeqCst);
        Ok(())
    }

    pub fn release(&self) {
        self.holding.store(false, Ordering::SeqCst);
    }

    pub fn holding(&self) -> bool {
        self.holding.load(Ordering::SeqCst)
    }

    pub fn epoch(&self) -> Epoch {
        Epoch(self.epoch.load(Ordering::SeqCst))
    }

    pub fn assert_holding(&self) -> Result<(), OwnershipError> {
        if !self.holding() {
            return Err(OwnershipError::OwnershipLost);
        }
        Ok(())
    }

    /// Refuse-unsafe-startup gate used by main before routes open.
    pub fn check_startup(&self) -> Result<(), OwnershipError> {
        let g = self.inner.lock().expect("ownership gate poisoned");
        if g.refuse_on_rust && g.rust_active && !g.recovery_mode {
            return Err(OwnershipError::UnsafeStartup);
        }
        Ok(())
    }
}

/// In-process analogue of `rust_coord.coordinator_ownership` (DECISIONS #36).
/// Heartbeat expiry lets another holder steal; failed heartbeats fence the Gate.
#[derive(Debug)]
pub struct LocalOwnershipStore {
    inner: Mutex<OwnershipRow>,
    lease_ttl: Duration,
}

#[derive(Debug)]
struct OwnershipRow {
    holder: String,
    fencing_epoch: u64,
    heartbeat_at: Option<Instant>,
}

impl LocalOwnershipStore {
    pub fn new(lease_ttl: Duration) -> Self {
        Self {
            inner: Mutex::new(OwnershipRow {
                holder: String::new(),
                fencing_epoch: 0,
                heartbeat_at: None,
            }),
            lease_ttl: lease_ttl.max(Duration::from_millis(1)),
        }
    }

    fn expired(row: &OwnershipRow, ttl: Duration, now: Instant) -> bool {
        match row.heartbeat_at {
            None => true,
            Some(at) => now.duration_since(at) > ttl,
        }
    }

    /// CAS acquire: empty holder, same holder, or expired heartbeat.
    pub fn acquire(&self, holder: &str) -> Result<Epoch, OwnershipError> {
        if holder.is_empty() {
            return Err(OwnershipError::AcquireConflict);
        }
        let mut g = self.inner.lock().expect("ownership store poisoned");
        let now = Instant::now();
        let can = g.holder.is_empty()
            || g.holder == holder
            || Self::expired(&g, self.lease_ttl, now);
        if !can {
            return Err(OwnershipError::AcquireConflict);
        }
        g.fencing_epoch = g.fencing_epoch.saturating_add(1);
        g.holder = holder.to_string();
        g.heartbeat_at = Some(now);
        Ok(Epoch(g.fencing_epoch))
    }

    /// Heartbeat while holding. Zero rows / mismatch → OwnershipLost.
    pub fn heartbeat(&self, holder: &str, epoch: Epoch) -> Result<(), OwnershipError> {
        let mut g = self.inner.lock().expect("ownership store poisoned");
        if g.holder != holder || g.fencing_epoch != epoch.0 {
            return Err(OwnershipError::OwnershipLost);
        }
        g.heartbeat_at = Some(Instant::now());
        Ok(())
    }

    pub fn release(&self, holder: &str, epoch: Epoch) -> Result<(), OwnershipError> {
        let mut g = self.inner.lock().expect("ownership store poisoned");
        if g.holder != holder || g.fencing_epoch != epoch.0 {
            return Err(OwnershipError::OwnershipLost);
        }
        g.holder.clear();
        g.heartbeat_at = None;
        Ok(())
    }

    /// Test helper: expire the current lease so another holder can steal.
    pub fn force_expire_for_test(&self) {
        let mut g = self.inner.lock().expect("ownership store poisoned");
        if let Some(at) = g.heartbeat_at.as_mut() {
            *at = Instant::now()
                .checked_sub(self.lease_ttl + Duration::from_secs(1))
                .unwrap_or_else(Instant::now);
        }
    }

    pub fn holder(&self) -> String {
        self.inner
            .lock()
            .expect("ownership store poisoned")
            .holder
            .clone()
    }

    pub fn fencing_epoch(&self) -> Epoch {
        Epoch(
            self.inner
                .lock()
                .expect("ownership store poisoned")
                .fencing_epoch,
        )
    }
}

/// Periodically heartbeats the local store; on failure releases the Gate so
/// mutating routes fence with ownership_lost (DECISIONS #36).
pub async fn run_ownership_heartbeat(
    store: Arc<LocalOwnershipStore>,
    gate: Arc<Gate>,
    holder: String,
    interval: Duration,
) {
    let interval = interval.max(Duration::from_millis(5));
    loop {
        tokio::time::sleep(interval).await;
        if !gate.holding() {
            continue;
        }
        let epoch = gate.epoch();
        if let Err(err) = store.heartbeat(&holder, epoch) {
            tracing::error!(%err, holder = %holder, epoch = epoch.0, "ownership heartbeat lost");
            gate.release();
        }
    }
}

/// Documented SQL for durable fencing epoch CAS (lands with SQLx).
pub fn acquire_sql() -> &'static str {
    r#"
    UPDATE rust_coord.coordinator_ownership
    SET fencing_epoch = fencing_epoch + 1,
        holder = $1,
        acquired_at = NOW(),
        heartbeat_at = NOW(),
        recovery_mode = $2
    WHERE id = 1
      AND (holder = '' OR holder = $1 OR heartbeat_at < NOW() - INTERVAL '30 seconds')
    RETURNING fencing_epoch, holder
    "#
}

/// Documented SQL for heartbeat while holding.
pub fn heartbeat_sql() -> &'static str {
    r#"
    UPDATE rust_coord.coordinator_ownership
    SET heartbeat_at = NOW()
    WHERE id = 1 AND holder = $1 AND fencing_epoch = $2
    RETURNING fencing_epoch
    "#
}

/// Documented SQL for release on graceful shutdown.
pub fn release_sql() -> &'static str {
    r#"
    UPDATE rust_coord.coordinator_ownership
    SET holder = '', heartbeat_at = NULL
    WHERE id = 1 AND holder = $1 AND fencing_epoch = $2
    RETURNING fencing_epoch
    "#
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuse_unsafe_startup_when_rust_active() {
        let g = Gate::new(true);
        g.set_rust_active(true);
        assert_eq!(g.check_startup(), Err(OwnershipError::UnsafeStartup));
        assert_eq!(g.acquire(Epoch(1)), Err(OwnershipError::UnsafeStartup));
    }

    #[test]
    fn allows_when_no_rust_active() {
        let g = Gate::new(true);
        g.set_rust_active(false);
        assert!(g.check_startup().is_ok());
        assert!(g.acquire(Epoch(7)).is_ok());
        assert!(g.holding());
        assert_eq!(g.epoch(), Epoch(7));
        g.assert_holding().unwrap();
        g.release();
        assert_eq!(g.assert_holding(), Err(OwnershipError::OwnershipLost));
    }

    #[test]
    fn recovery_mode_bypasses_refuse() {
        let g = Gate::new(true);
        g.set_rust_active(true);
        g.enable_recovery_mode();
        assert!(g.check_startup().is_ok());
        assert!(g.acquire(Epoch(3)).is_ok());
    }

    #[test]
    fn refuse_on_rust_false_ignores_active_rust() {
        let g = Gate::new(false);
        g.set_rust_active(true);
        assert!(g.check_startup().is_ok());
        assert!(g.acquire(Epoch(1)).is_ok());
    }

    #[test]
    fn epoch_fencing_monotonic_acquire() {
        let g = Gate::new(false);
        g.acquire(Epoch(1)).unwrap();
        g.acquire(Epoch(2)).unwrap();
        assert_eq!(g.epoch(), Epoch(2));
    }

    #[test]
    fn ownership_sql_docs_mention_coordinator_ownership() {
        assert!(acquire_sql().contains("rust_coord.coordinator_ownership"));
        assert!(acquire_sql().contains("fencing_epoch"));
        assert!(heartbeat_sql().contains("heartbeat_at"));
        assert!(release_sql().contains("holder = ''"));
        assert!(heartbeat_sql().contains("holder = $1 AND fencing_epoch = $2"));
        assert!(release_sql().contains("holder = $1 AND fencing_epoch = $2"));
        assert!(acquire_sql().contains("heartbeat_at < NOW() - INTERVAL '30 seconds'"));
        assert!(acquire_sql().contains("fencing_epoch = fencing_epoch + 1"));
    }

    #[test]
    fn release_clears_holding_flag() {
        let g = Gate::new(false);
        g.acquire(Epoch(7)).unwrap();
        assert!(g.holding());
        g.release();
        assert!(!g.holding());
        assert_eq!(g.assert_holding(), Err(OwnershipError::OwnershipLost));
    }

    #[test]
    fn local_store_acquire_heartbeat_release() {
        let store = LocalOwnershipStore::new(Duration::from_secs(30));
        let e = store.acquire("a").unwrap();
        assert_eq!(e, Epoch(1));
        store.heartbeat("a", e).unwrap();
        store.release("a", e).unwrap();
        assert!(store.holder().is_empty());
    }

    #[test]
    fn local_store_second_holder_blocked_until_expire() {
        let store = LocalOwnershipStore::new(Duration::from_secs(30));
        let e1 = store.acquire("a").unwrap();
        assert_eq!(store.acquire("b"), Err(OwnershipError::AcquireConflict));
        store.force_expire_for_test();
        let e2 = store.acquire("b").unwrap();
        assert!(e2 > e1);
        assert_eq!(
            store.heartbeat("a", e1),
            Err(OwnershipError::OwnershipLost)
        );
        store.heartbeat("b", e2).unwrap();
    }

    #[test]
    fn heartbeat_mismatch_fences_gate() {
        let store = Arc::new(LocalOwnershipStore::new(Duration::from_secs(30)));
        let gate = Arc::new(Gate::new(false));
        let e = store.acquire("a").unwrap();
        gate.acquire(e).unwrap();
        store.force_expire_for_test();
        let e2 = store.acquire("b").unwrap();
        assert_ne!(e, e2);
        assert_eq!(
            store.heartbeat("a", e),
            Err(OwnershipError::OwnershipLost)
        );
        gate.release();
        assert_eq!(gate.assert_holding(), Err(OwnershipError::OwnershipLost));
    }

    #[tokio::test]
    async fn heartbeat_loop_releases_gate_after_steal() {
        let store = Arc::new(LocalOwnershipStore::new(Duration::from_millis(50)));
        let gate = Arc::new(Gate::new(false));
        let e = store.acquire("a").unwrap();
        gate.acquire(e).unwrap();
        let store_hb = store.clone();
        let gate_hb = gate.clone();
        tokio::spawn(async move {
            run_ownership_heartbeat(store_hb, gate_hb, "a".into(), Duration::from_millis(10))
                .await;
        });
        store.force_expire_for_test();
        let _ = store.acquire("b").unwrap();
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert!(!gate.holding());
        assert_eq!(gate.assert_holding(), Err(OwnershipError::OwnershipLost));
    }
}
