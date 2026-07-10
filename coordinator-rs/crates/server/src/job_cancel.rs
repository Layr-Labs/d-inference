//! In-flight chat cancel registry (DECISIONS #164).
//!
//! Chat registers a cancel signal while blocked on prepare/start/terminal.
//! Admin (or future client disconnect) fires the signal so the select! arm
//! runs cancel_before_or_after_content with money_fx.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{watch, Mutex};

#[derive(Clone)]
pub struct CancelSignal {
    tx: watch::Sender<bool>,
    rx: watch::Receiver<bool>,
}

impl CancelSignal {
    fn new() -> Self {
        let (tx, rx) = watch::channel(false);
        Self { tx, rx }
    }

    pub fn cancel(&self) {
        let _ = self.tx.send(true);
    }

    pub fn is_cancelled(&self) -> bool {
        *self.rx.borrow()
    }

    pub async fn cancelled(&self) {
        let mut rx = self.rx.clone();
        while !*rx.borrow_and_update() {
            if rx.changed().await.is_err() {
                return;
            }
        }
    }
}

#[derive(Default, Clone)]
pub struct JobCancelRegistry {
    inner: Arc<Mutex<HashMap<String, CancelSignal>>>,
}

impl JobCancelRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register (or replace) a cancel signal for `job_id`.
    pub async fn register(&self, job_id: &str) -> CancelSignal {
        let signal = CancelSignal::new();
        self.inner
            .lock()
            .await
            .insert(job_id.to_string(), signal.clone());
        signal
    }

    /// Cancel an in-flight job wait. Returns true if a signal was present.
    pub async fn cancel(&self, job_id: &str) -> bool {
        if let Some(signal) = self.inner.lock().await.get(job_id) {
            signal.cancel();
            true
        } else {
            false
        }
    }

    /// Drop the registration when the chat handler finishes the wait.
    pub async fn unregister(&self, job_id: &str) {
        self.inner.lock().await.remove(job_id);
    }

    pub async fn len(&self) -> usize {
        self.inner.lock().await.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cancel_fires_registered_signal() {
        let reg = JobCancelRegistry::new();
        let signal = reg.register("j1").await;
        assert!(!signal.is_cancelled());
        assert!(reg.cancel("j1").await);
        assert!(signal.is_cancelled());
        reg.unregister("j1").await;
        assert!(!reg.cancel("j1").await);
        assert_eq!(reg.len().await, 0);
    }
}
