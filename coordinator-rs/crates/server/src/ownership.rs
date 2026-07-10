//! Single-active coordinator fencing epoch (plan §20 / M0.7 + M4).
//!
//! Process-local view mirrors `coordinator/ownership`. Durable CAS against
//! `rust_coord.coordinator_ownership` lands with SQLx; this Gate is the
//! admission fence used by the warm plane today.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum OwnershipError {
    #[error("coordinator ownership lost")]
    OwnershipLost,
    #[error("unsafe startup: active rust_coord jobs or leases")]
    UnsafeStartup,
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
    }
}
