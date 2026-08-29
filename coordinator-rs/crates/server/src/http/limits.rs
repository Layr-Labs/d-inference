//! Global and per-account concurrency shedding (plan §14: reject before any
//! large allocation; admission cannot consume every shared permit).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use darkbloom_core::ids::AccountId;

pub struct ConcurrencyLimits {
    global: Arc<Semaphore>,
    per_account_cap: usize,
    accounts: Mutex<HashMap<AccountId, Arc<Semaphore>>>,
}

/// Permits held for one in-flight request; dropped when the request ends.
pub struct RequestPermits {
    _global: OwnedSemaphorePermit,
    _account: OwnedSemaphorePermit,
}

impl ConcurrencyLimits {
    pub fn new(global_cap: usize, per_account_cap: usize) -> Self {
        Self {
            global: Arc::new(Semaphore::new(global_cap.max(1))),
            per_account_cap: per_account_cap.max(1),
            accounts: Mutex::new(HashMap::new()),
        }
    }

    /// Nonblocking acquire: a miss is an immediate shed, never a queue
    /// (plan §11.7, §14).
    pub fn try_acquire(&self, account: AccountId) -> Option<RequestPermits> {
        let global = self.global.clone().try_acquire_owned().ok()?;
        let semaphore = {
            let mut accounts = self.accounts.lock().ok()?;
            accounts
                .entry(account)
                .or_insert_with(|| Arc::new(Semaphore::new(self.per_account_cap)))
                .clone()
        };
        let account_permit = semaphore.try_acquire_owned().ok()?;
        Some(RequestPermits {
            _global: global,
            _account: account_permit,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn per_account_cap_binds_before_global() {
        let limits = ConcurrencyLimits::new(10, 1);
        let account = AccountId::new(Uuid::from_u128(1));
        let other = AccountId::new(Uuid::from_u128(2));
        let held = limits.try_acquire(account).expect("first");
        assert!(limits.try_acquire(account).is_none(), "account cap");
        assert!(limits.try_acquire(other).is_some(), "other account fine");
        drop(held);
        assert!(limits.try_acquire(account).is_some(), "released");
    }

    #[test]
    fn global_cap_binds() {
        let limits = ConcurrencyLimits::new(1, 5);
        let a = AccountId::new(Uuid::from_u128(1));
        let b = AccountId::new(Uuid::from_u128(2));
        let _held = limits.try_acquire(a).expect("first");
        assert!(limits.try_acquire(b).is_none(), "global cap");
    }
}
