//! Bounded, provider-epoch-fenced blocking verification.

use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

use darkbloom_coordinator_protocol::v2::ProviderId;
use thiserror::Error;
use tokio::sync::Semaphore;

/// Globally monotonic verification start epoch.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct VerificationEpoch(u64);

impl VerificationEpoch {
    /// Numeric epoch, beginning at one.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// A blocking result proven current for its stable provider.
#[derive(Debug)]
pub struct EpochVerified<T> {
    /// Epoch minted before the blocking task started.
    pub epoch: VerificationEpoch,
    /// Verification output.
    pub value: T,
}

#[derive(Debug, Default)]
struct BlockingState {
    next_epoch: u64,
    current: BTreeMap<ProviderId, VerificationEpoch>,
}

struct PendingEpoch<'a> {
    state: &'a Mutex<BlockingState>,
    provider_id: ProviderId,
    epoch: VerificationEpoch,
    active: bool,
}

impl PendingEpoch<'_> {
    fn take_current(&mut self) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let is_current = state.current.get(&self.provider_id) == Some(&self.epoch);
        if is_current {
            state.current.remove(&self.provider_id);
        }
        self.active = false;
        is_current
    }
}

impl Drop for PendingEpoch<'_> {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.current.get(&self.provider_id) == Some(&self.epoch) {
            state.current.remove(&self.provider_id);
        }
    }
}

/// Process-wide finite admission to CPU-bound trust verification.
#[derive(Debug)]
pub struct BoundedBlockingVerifier {
    permits: Arc<Semaphore>,
    maximum_pending_providers: usize,
    state: Mutex<BlockingState>,
}

impl BoundedBlockingVerifier {
    /// Creates strict nonqueueing blocking admission.
    pub fn new(
        maximum_concurrent_jobs: usize,
        maximum_pending_providers: usize,
    ) -> Result<Self, BlockingVerificationError> {
        if maximum_concurrent_jobs == 0 || maximum_pending_providers == 0 {
            return Err(BlockingVerificationError::ZeroLimit);
        }
        Ok(Self {
            permits: Arc::new(Semaphore::new(maximum_concurrent_jobs)),
            maximum_pending_providers,
            state: Mutex::new(BlockingState::default()),
        })
    }

    /// Runs one CPU-bound verifier without an unbounded Tokio blocking queue.
    ///
    /// The epoch is installed before `spawn_blocking`. A newer verification
    /// for the same stable provider makes this result stale regardless of
    /// completion order.
    pub async fn run<T, F>(
        &self,
        provider_id: ProviderId,
        verify: F,
    ) -> Result<EpochVerified<T>, BlockingVerificationError>
    where
        T: Send + 'static,
        F: FnOnce() -> T + Send + 'static,
    {
        let permit = Arc::clone(&self.permits)
            .try_acquire_owned()
            .map_err(|_| BlockingVerificationError::Busy)?;
        let epoch = {
            let mut state = self.lock_state();
            if !state.current.contains_key(&provider_id)
                && state.current.len() == self.maximum_pending_providers
            {
                return Err(BlockingVerificationError::ProviderLimit {
                    maximum: self.maximum_pending_providers,
                });
            }
            state.next_epoch = state
                .next_epoch
                .checked_add(1)
                .ok_or(BlockingVerificationError::EpochExhausted)?;
            let epoch = VerificationEpoch(state.next_epoch);
            state.current.insert(provider_id, epoch);
            epoch
        };
        let mut pending = PendingEpoch {
            state: &self.state,
            provider_id,
            epoch,
            active: true,
        };

        let joined = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            verify()
        })
        .await;
        let is_current = pending.take_current();
        let value = joined.map_err(|_| BlockingVerificationError::TaskFailed)?;
        if !is_current {
            return Err(BlockingVerificationError::Stale { provider_id, epoch });
        }
        Ok(EpochVerified { epoch, value })
    }

    /// Supersedes any in-flight result for one provider.
    pub fn invalidate(
        &self,
        provider_id: ProviderId,
    ) -> Result<VerificationEpoch, BlockingVerificationError> {
        let mut state = self.lock_state();
        if !state.current.contains_key(&provider_id)
            && state.current.len() == self.maximum_pending_providers
        {
            return Err(BlockingVerificationError::ProviderLimit {
                maximum: self.maximum_pending_providers,
            });
        }
        state.next_epoch = state
            .next_epoch
            .checked_add(1)
            .ok_or(BlockingVerificationError::EpochExhausted)?;
        let epoch = VerificationEpoch(state.next_epoch);
        state.current.insert(provider_id, epoch);
        Ok(epoch)
    }

    /// Removes an explicit invalidation fence after downstream applies it.
    pub fn clear_if_current(&self, provider_id: ProviderId, epoch: VerificationEpoch) -> bool {
        let mut state = self.lock_state();
        if state.current.get(&provider_id) != Some(&epoch) {
            return false;
        }
        state.current.remove(&provider_id);
        true
    }

    /// Number of provider identities with verification or invalidation pending.
    #[must_use]
    pub fn pending_provider_count(&self) -> usize {
        self.lock_state().current.len()
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, BlockingState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Blocking trust boundary rejection.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum BlockingVerificationError {
    /// Finite limits must be positive.
    #[error("blocking verification limits must be greater than zero")]
    ZeroLimit,
    /// No blocking slot is immediately available.
    #[error("blocking verification capacity is full")]
    Busy,
    /// Too many distinct provider verifications are pending.
    #[error("blocking verification provider limit of {maximum} reached")]
    ProviderLimit {
        /// Configured provider bound.
        maximum: usize,
    },
    /// Verification start epochs cannot wrap safely.
    #[error("blocking verification epoch exhausted")]
    EpochExhausted,
    /// Blocking closure panicked or the runtime aborted it.
    #[error("blocking verification task failed")]
    TaskFailed,
    /// A newer verification started before this one completed.
    #[error("provider {provider_id} verification epoch {epoch:?} is stale")]
    Stale {
        /// Stable provider whose result is stale.
        provider_id: ProviderId,
        /// Stale start epoch.
        epoch: VerificationEpoch,
    },
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{Arc, Barrier},
        time::Duration,
    };

    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn newer_start_fences_slow_old_result() {
        let verifier = Arc::new(BoundedBlockingVerifier::new(2, 2).expect("verifier"));
        let provider = ProviderId::new([1; 16]);
        let started = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let old_verifier = Arc::clone(&verifier);
        let old_started = Arc::clone(&started);
        let old_release = Arc::clone(&release);
        let old = tokio::spawn(async move {
            old_verifier
                .run(provider, move || {
                    old_started.wait();
                    old_release.wait();
                    "old"
                })
                .await
        });
        tokio::task::spawn_blocking(move || started.wait())
            .await
            .expect("started");
        let new = verifier.run(provider, || "new").await.expect("new result");
        assert_eq!(new.value, "new");
        tokio::task::spawn_blocking(move || release.wait())
            .await
            .expect("release");
        assert!(matches!(
            old.await.expect("join"),
            Err(BlockingVerificationError::Stale { .. })
        ));
        assert_eq!(verifier.pending_provider_count(), 0);
    }

    #[tokio::test]
    async fn full_pool_rejects_instead_of_building_unbounded_waiters() {
        let verifier = Arc::new(BoundedBlockingVerifier::new(1, 2).expect("verifier"));
        let barrier = Arc::new(Barrier::new(2));
        let held = Arc::clone(&verifier);
        let held_barrier = Arc::clone(&barrier);
        let job = tokio::spawn(async move {
            held.run(ProviderId::new([1; 16]), move || {
                held_barrier.wait();
            })
            .await
        });
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert_eq!(
            verifier
                .run(ProviderId::new([2; 16]), || ())
                .await
                .expect_err("must reject"),
            BlockingVerificationError::Busy
        );
        tokio::task::spawn_blocking(move || barrier.wait())
            .await
            .expect("release");
        job.await.expect("join").expect("held");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cancelling_waiter_cleans_epoch_without_releasing_running_job_permit() {
        let verifier = Arc::new(BoundedBlockingVerifier::new(1, 2).expect("verifier"));
        let provider = ProviderId::new([1; 16]);
        let started = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let running_verifier = Arc::clone(&verifier);
        let running_started = Arc::clone(&started);
        let running_release = Arc::clone(&release);
        let running = tokio::spawn(async move {
            running_verifier
                .run(provider, move || {
                    running_started.wait();
                    running_release.wait();
                })
                .await
        });
        tokio::task::spawn_blocking(move || started.wait())
            .await
            .expect("started");

        running.abort();
        assert!(running.await.expect_err("cancelled").is_cancelled());
        assert_eq!(verifier.pending_provider_count(), 0);
        assert_eq!(
            verifier
                .run(ProviderId::new([2; 16]), || ())
                .await
                .expect_err("running blocking job retains permit"),
            BlockingVerificationError::Busy
        );

        tokio::task::spawn_blocking(move || release.wait())
            .await
            .expect("release");
    }
}
