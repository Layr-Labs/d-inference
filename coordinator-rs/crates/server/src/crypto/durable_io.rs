//! Bounded offload for fsync-backed JSON state.

use std::{sync::Arc, time::Duration};

use thiserror::Error;
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore},
    task::JoinError,
    time::timeout,
};

/// Cloneable admission handle for the process's durable blocking-I/O lane.
#[derive(Clone, Debug)]
pub struct DurableIoPool {
    permits: Arc<Semaphore>,
    operation_timeout: Duration,
}

impl DurableIoPool {
    /// Creates a finite fsync concurrency domain.
    pub fn new(
        maximum_concurrency: usize,
        operation_timeout: Duration,
    ) -> Result<Self, DurableIoConfigError> {
        if maximum_concurrency == 0 {
            return Err(DurableIoConfigError::ZeroConcurrency);
        }
        if operation_timeout.is_zero() {
            return Err(DurableIoConfigError::ZeroTimeout);
        }
        Ok(Self {
            permits: Arc::new(Semaphore::new(maximum_concurrency)),
            operation_timeout,
        })
    }

    /// Runs one synchronous store operation outside Tokio workers.
    ///
    /// The owned permit is moved into the blocking closure, so timing out the
    /// caller never admits replacement work while the underlying fsync is
    /// still finishing.
    pub async fn run<T, F>(&self, operation: &'static str, work: F) -> Result<T, DurableIoError>
    where
        T: Send + 'static,
        F: FnOnce() -> T + Send + 'static,
    {
        let permit = timeout(self.operation_timeout, self.permits.clone().acquire_owned())
            .await
            .map_err(|_| DurableIoError::Timeout { operation })?
            .map_err(|_| DurableIoError::Closed)?;
        let task = tokio::task::spawn_blocking(move || run_with_permit(permit, work));
        timeout(self.operation_timeout, task)
            .await
            .map_err(|_| DurableIoError::Timeout { operation })?
            .map_err(|error| join_error(operation, error))
    }

    /// Number of fsync operations that can start immediately.
    #[must_use]
    pub fn available_permits(&self) -> usize {
        self.permits.available_permits()
    }
}

fn run_with_permit<T, F>(_permit: OwnedSemaphorePermit, work: F) -> T
where
    F: FnOnce() -> T,
{
    work()
}

fn join_error(operation: &'static str, error: JoinError) -> DurableIoError {
    DurableIoError::Join {
        operation,
        message: Arc::from(error.to_string()),
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum DurableIoConfigError {
    #[error("durable I/O concurrency must be greater than zero")]
    ZeroConcurrency,
    #[error("durable I/O timeout must be greater than zero")]
    ZeroTimeout,
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DurableIoError {
    #[error("durable I/O pool is closed")]
    Closed,
    #[error("durable I/O operation {operation} exceeded its deadline")]
    Timeout { operation: &'static str },
    #[error("durable I/O operation {operation} failed to join: {message}")]
    Join {
        operation: &'static str,
        message: Arc<str>,
    },
}

#[cfg(test)]
mod tests {
    use std::{
        sync::atomic::{AtomicBool, Ordering},
        thread,
    };

    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn slow_or_faulting_peer_does_not_block_healthy_durable_progress() {
        let pool = DurableIoPool::new(2, Duration::from_secs(1)).expect("pool");
        let slow_started = Arc::new(AtomicBool::new(false));
        let slow_release = Arc::new(AtomicBool::new(false));
        let started = slow_started.clone();
        let release = slow_release.clone();
        let slow_pool = pool.clone();
        let slow = tokio::spawn(async move {
            slow_pool
                .run("slow provider terminal", move || {
                    started.store(true, Ordering::Release);
                    while !release.load(Ordering::Acquire) {
                        thread::yield_now();
                    }
                    Err::<(), &'static str>("injected fsync failure")
                })
                .await
        });
        while !slow_started.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }

        let cancellation = tokio_util::sync::CancellationToken::new();
        let cancelled = cancellation.clone();
        let cancellation_waiter = tokio::spawn(async move {
            cancelled.cancelled().await;
            11
        });
        cancellation.cancel();
        assert_eq!(
            timeout(Duration::from_millis(100), cancellation_waiter)
                .await
                .expect("Tokio worker remained responsive")
                .expect("cancellation waiter"),
            11
        );

        let healthy = pool
            .run("healthy provider terminal", || Ok::<_, &'static str>(17))
            .await
            .expect("healthy operation joins")
            .expect("healthy operation succeeds");
        assert_eq!(healthy, 17);
        assert_eq!(pool.available_permits(), 1);

        slow_release.store(true, Ordering::Release);
        assert_eq!(
            slow.await.expect("slow task joins").expect("pool result"),
            Err("injected fsync failure")
        );
        assert_eq!(pool.available_permits(), 2);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn timed_out_fsync_keeps_its_permit_until_blocking_work_ends() {
        let pool = DurableIoPool::new(1, Duration::from_millis(10)).expect("pool");
        let completed = Arc::new(AtomicBool::new(false));
        let marker = completed.clone();
        assert!(matches!(
            pool.run("timed out fsync", move || {
                thread::sleep(Duration::from_millis(30));
                marker.store(true, Ordering::Release);
            })
            .await,
            Err(DurableIoError::Timeout { .. })
        ));
        assert_eq!(pool.available_permits(), 0);
        while !completed.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
        while pool.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(pool.available_permits(), 1);
    }
}
