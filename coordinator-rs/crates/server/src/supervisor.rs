//! Application supervisor: phased task ownership and ordered shutdown
//! (plan §15.1).
//!
//! Axum's graceful shutdown covers HTTP connections only; upgraded
//! WebSockets and background workers need explicit application shutdown:
//!
//! 1. Stop new inference admission (readiness flips false).
//! 2. Cancel and drain request tasks.
//! 3. Stop model/external/recovery workers.
//! 4. Broadcast provider going-away intent.
//! 5. Close provider sessions.
//! 6. Join every tracked task with a bound — anything still running leaves
//!    durable recovery state (the ledger's job rows) rather than blocking
//!    exit forever.
//!
//! Each phase owns a `CancellationToken` + `TaskTracker` pair; spawning
//! against the right phase is what guarantees the drain ORDER, not timing.

use std::future::Future;
use std::time::Duration;

use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

/// One shutdown phase: a token that fires and a tracker that drains.
#[derive(Clone)]
pub struct Phase {
    token: CancellationToken,
    tracker: TaskTracker,
    name: &'static str,
}

impl Phase {
    fn new(name: &'static str, parent: &CancellationToken) -> Self {
        Self {
            token: parent.child_token(),
            tracker: TaskTracker::new(),
            name,
        }
    }

    /// Cancellation token tasks of this phase must select on.
    pub fn token(&self) -> CancellationToken {
        self.token.clone()
    }

    /// Spawns a task tracked by this phase.
    pub fn spawn<F>(&self, task: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        self.tracker.spawn(task);
    }

    /// Tracker handle, for components that spawn many tasks themselves
    /// (e.g. [`crate::recovery::spawn_all`]).
    pub fn tracker(&self) -> &TaskTracker {
        &self.tracker
    }

    async fn drain(&self, timeout: Duration) {
        self.token.cancel();
        self.tracker.close();
        if tokio::time::timeout(timeout, self.tracker.wait())
            .await
            .is_err()
        {
            tracing::warn!(
                phase = self.name,
                timeout_ms = timeout.as_millis() as u64,
                "phase did not drain in time; durable recovery state covers the rest (plan §15.1)"
            );
        } else {
            tracing::info!(phase = self.name, "phase drained");
        }
    }
}

/// Owns the phase order. Constructed in `main`; the admission watch is the
/// AppState-adjacent shutdown signal HTTP/request tasks consume.
pub struct Supervisor {
    root: CancellationToken,
    admission_tx: watch::Sender<bool>,
    requests: Phase,
    workers: Phase,
    sessions: Phase,
}

impl Default for Supervisor {
    fn default() -> Self {
        Self::new()
    }
}

impl Supervisor {
    #[must_use]
    pub fn new() -> Self {
        let root = CancellationToken::new();
        let (admission_tx, _) = watch::channel(true);
        Self {
            requests: Phase::new("requests", &root),
            workers: Phase::new("workers", &root),
            sessions: Phase::new("sessions", &root),
            root,
            admission_tx,
        }
    }

    /// True while new inference admission is allowed. Flips false as the
    /// FIRST shutdown action (plan §15.1 step 1) and feeds readiness.
    pub fn admission_watch(&self) -> watch::Receiver<bool> {
        self.admission_tx.subscribe()
    }

    /// Request-task phase (one task per logical request, plan §7.2).
    pub fn requests(&self) -> &Phase {
        &self.requests
    }

    /// Background worker phase (catalog refresh, recovery sweepers,
    /// telemetry).
    pub fn workers(&self) -> &Phase {
        &self.workers
    }

    /// Provider session phase (WebSocket read/write loops).
    pub fn sessions(&self) -> &Phase {
        &self.sessions
    }

    /// Root token: fires on any shutdown, before the ordered drain.
    pub fn root_token(&self) -> CancellationToken {
        self.root.clone()
    }

    /// Ordered shutdown (plan §15.1). `going_away` runs between worker stop
    /// and session close — the fleet's provider going-away broadcast plugs
    /// in there at integration time.
    pub async fn shutdown<F>(&self, phase_timeout: Duration, going_away: F)
    where
        F: Future<Output = ()>,
    {
        tracing::info!("ordered shutdown: stopping admission");
        let _ = self.admission_tx.send(false);

        self.requests.drain(phase_timeout).await;
        self.workers.drain(phase_timeout).await;

        tracing::info!("ordered shutdown: broadcasting going-away");
        going_away.await;

        self.sessions.drain(phase_timeout).await;
        self.root.cancel();
        tracing::info!("ordered shutdown: all phases drained");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// The three phases must drain strictly in order: requests, then
    /// workers, then sessions — with the going-away broadcast between the
    /// last two (plan §15.1).
    #[tokio::test]
    async fn shutdown_drains_phases_in_order() {
        let supervisor = Supervisor::new();
        let sequence = Arc::new(AtomicUsize::new(0));
        let (order_tx, mut order_rx) = tokio::sync::mpsc::unbounded_channel::<(&str, usize)>();

        for (name, phase) in [
            ("requests", supervisor.requests()),
            ("workers", supervisor.workers()),
            ("sessions", supervisor.sessions()),
        ] {
            let token = phase.token();
            let sequence = Arc::clone(&sequence);
            let order_tx = order_tx.clone();
            phase.spawn(async move {
                token.cancelled().await;
                let seq = sequence.fetch_add(1, Ordering::SeqCst);
                let _ = order_tx.send((name, seq));
            });
        }

        let mut admission = supervisor.admission_watch();
        assert!(*admission.borrow());

        let going_away_seq = Arc::clone(&sequence);
        let order_tx2 = order_tx.clone();
        supervisor
            .shutdown(Duration::from_secs(5), async move {
                let seq = going_away_seq.fetch_add(1, Ordering::SeqCst);
                let _ = order_tx2.send(("going_away", seq));
            })
            .await;

        assert!(!*admission.borrow_and_update());
        drop(order_tx);
        let mut events = Vec::new();
        while let Some(event) = order_rx.recv().await {
            events.push(event);
        }
        events.sort_by_key(|(_, seq)| *seq);
        let names: Vec<&str> = events.iter().map(|(name, _)| *name).collect();
        assert_eq!(names, vec!["requests", "workers", "going_away", "sessions"]);
    }

    /// A stuck task must not hang shutdown forever: the phase times out and
    /// the rest of the order proceeds.
    #[tokio::test]
    async fn shutdown_bounds_stuck_phases() {
        let supervisor = Supervisor::new();
        supervisor.requests().spawn(async {
            // Ignores cancellation entirely.
            std::future::pending::<()>().await;
        });
        tokio::time::timeout(
            Duration::from_secs(2),
            supervisor.shutdown(Duration::from_millis(50), async {}),
        )
        .await
        .expect("shutdown must be bounded");
    }
}
