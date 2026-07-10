//! RequestTask — one supervised logical request (plan §7.2).
//!
//! Content chunks do not flow through this mailbox; only control events do.
//! Chunks use a bounded byte pipe (see `chunk_pipe`).

use darkbloom_core::{
    admission::DispatchPermit, AttemptId, JobId, LeaseId, RequestEvent, RequestState,
};
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::mpsc;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum RequestTaskError {
    #[error("invalid request transition")]
    InvalidTransition,
    #[error("absolute first-content deadline exceeded")]
    DeadlineExceeded,
    #[error("chunk pipe full — client backpressure")]
    Backpressure,
    #[error("task finished")]
    Finished,
}

#[derive(Debug, Clone)]
pub enum ControlEvent {
    Reserved { job: JobId },
    Admitted { attempt: AttemptId, permit: DispatchPermit },
    Prepared { attempt: AttemptId, lease: LeaseId },
    StartAuthorized { attempt: AttemptId, lease: LeaseId },
    Started { attempt: AttemptId, lease: LeaseId },
    FirstContent { attempt: AttemptId, lease: LeaseId },
    ProviderTerminal { attempt: AttemptId, lease: LeaseId },
    BackpressureFailed,
    Cancel,
    FinalizeDone,
    /// Prepared lease TTL elapsed — release and optionally alternate.
    PrepareExpired,
}

pub struct RequestTask {
    pub job_id: JobId,
    pub state: RequestState,
    pub deadline: Instant,
    pub funded_start: bool,
    pub sequential_alternate_used: bool,
    pub hedge_used: bool,
    pub hedge_budget: darkbloom_core::HedgeBudget,
    pub hedge_policy: darkbloom_core::HedgePolicy,
    control_rx: mpsc::Receiver<ControlEvent>,
}

pub struct RequestTaskHandle {
    pub job_id: JobId,
    control_tx: mpsc::Sender<ControlEvent>,
}

impl RequestTaskHandle {
    pub async fn send(&self, event: ControlEvent) -> Result<(), RequestTaskError> {
        self.control_tx
            .try_send(event)
            .map_err(|_| RequestTaskError::Finished)
    }
}

pub fn spawn_request_task(job_id: JobId, absolute_deadline: Duration) -> (RequestTaskHandle, RequestTask) {
    let (tx, rx) = mpsc::channel(32);
    let handle = RequestTaskHandle {
        job_id: job_id.clone(),
        control_tx: tx,
    };
    let task = RequestTask {
        job_id,
        state: RequestState::Reserving,
        deadline: Instant::now() + absolute_deadline,
        funded_start: false,
        sequential_alternate_used: false,
        hedge_used: false,
        hedge_budget: darkbloom_core::HedgeBudget::default(),
        hedge_policy: darkbloom_core::HedgePolicy::default(),
        control_rx: rx,
    };
    (handle, task)
}

impl RequestTask {
    pub fn apply(&mut self, event: ControlEvent) -> Result<(), RequestTaskError> {
        if Instant::now() > self.deadline
            && !matches!(
                self.state,
                RequestState::Streaming { .. }
                    | RequestState::AwaitingTerminal { .. }
                    | RequestState::Finalizing
                    | RequestState::Finished
            )
        {
            // Absolute first-content deadline — shared across attempts, never resets.
            if matches!(
                self.state,
                RequestState::Preparing { .. }
                    | RequestState::FundingPrepared { .. }
                    | RequestState::Starting { .. }
                    | RequestState::AwaitingContent { .. }
                    | RequestState::Admitting
                    | RequestState::Reserving
            ) {
                return Err(RequestTaskError::DeadlineExceeded);
            }
        }

        match event {
            ControlEvent::BackpressureFailed => return Err(RequestTaskError::Backpressure),
            ControlEvent::Cancel => {
                self.state = RequestState::Finalizing;
                return Ok(());
            }
            other => {
                let mapped = map_event(other)?;
                if matches!(mapped, RequestEvent::StartAuthorized { .. }) {
                    self.funded_start = true;
                }
                self.state = self
                    .state
                    .clone()
                    .transition(mapped)
                    .map_err(|_| RequestTaskError::InvalidTransition)?;
            }
        }
        Ok(())
    }

    /// Decide whether to fire a prepare hedge for a slow primary.
    pub fn maybe_hedge(&mut self, primary_prepare_elapsed: Duration) -> bool {
        self.hedge_budget.record_admit();
        let fire = self.hedge_budget.should_hedge_on_timer(
            &self.hedge_policy,
            primary_prepare_elapsed,
            self.hedge_used,
            self.funded_start,
        );
        if fire {
            self.hedge_used = true;
        }
        fire
    }

    pub async fn run(mut self) -> RequestState {
        while let Some(event) = self.control_rx.recv().await {
            if let Err(err) = self.apply(event) {
                tracing::warn!(?err, job = %self.job_id, "request task control error");
                self.state = RequestState::Finalizing;
                break;
            }
            if matches!(self.state, RequestState::Finished) {
                break;
            }
        }
        self.state
    }
}

fn map_event(event: ControlEvent) -> Result<RequestEvent, RequestTaskError> {
    Ok(match event {
        ControlEvent::Reserved { job } => RequestEvent::Reserved { job },
        ControlEvent::Admitted { attempt, .. } => RequestEvent::Admitted { attempt },
        ControlEvent::Prepared { attempt, lease } => RequestEvent::Prepared { attempt, lease },
        ControlEvent::StartAuthorized { attempt, lease } => {
            RequestEvent::StartAuthorized { attempt, lease }
        }
        ControlEvent::Started { attempt, lease } => RequestEvent::Started { attempt, lease },
        ControlEvent::FirstContent { attempt, lease } => {
            RequestEvent::FirstContent { attempt, lease }
        }
        ControlEvent::ProviderTerminal { attempt, lease } => {
            RequestEvent::ProviderTerminal { attempt, lease }
        }
        ControlEvent::FinalizeDone => RequestEvent::FinalizeDone,
        ControlEvent::PrepareExpired => RequestEvent::PrepareExpired,
        ControlEvent::BackpressureFailed | ControlEvent::Cancel => {
            return Err(RequestTaskError::InvalidTransition)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use darkbloom_core::admission::DispatchPermit;
    use std::time::Duration;

    #[tokio::test]
    async fn happy_path_control_events() {
        let (handle, mut task) = spawn_request_task(JobId::new("j1"), Duration::from_secs(30));
        let attempt = AttemptId::new("a1");
        let lease = LeaseId::new("l1");
        let permit = DispatchPermit {
            attempt: attempt.clone(),
            provider_id: "p".into(),
            model: "m".into(),
            expires_after: Duration::from_secs(2),
        };
        handle
            .send(ControlEvent::Reserved {
                job: JobId::new("j1"),
            })
            .await
            .unwrap();
        // Drive synchronously for unit test determinism.
        while let Ok(ev) = task.control_rx.try_recv() {
            task.apply(ev).unwrap();
        }
        task.apply(ControlEvent::Admitted {
            attempt: attempt.clone(),
            permit,
        })
        .unwrap();
        task.apply(ControlEvent::Prepared {
            attempt: attempt.clone(),
            lease: lease.clone(),
        })
        .unwrap();
        task.apply(ControlEvent::StartAuthorized {
            attempt: attempt.clone(),
            lease: lease.clone(),
        })
        .unwrap();
        assert!(task.funded_start);
        task.apply(ControlEvent::Started {
            attempt: attempt.clone(),
            lease: lease.clone(),
        })
        .unwrap();
        task.apply(ControlEvent::FirstContent {
            attempt: attempt.clone(),
            lease: lease.clone(),
        })
        .unwrap();
        task.apply(ControlEvent::ProviderTerminal {
            attempt: attempt.clone(),
            lease: lease.clone(),
        })
        .unwrap();
        task.apply(ControlEvent::FinalizeDone).unwrap();
        assert_eq!(task.state, RequestState::Finished);
    }

    #[tokio::test]
    async fn prepare_expired_returns_to_admitting() {
        let (_handle, mut task) = spawn_request_task(JobId::new("j-exp"), Duration::from_secs(30));
        let attempt = AttemptId::new("a1");
        let lease = LeaseId::new("l1");
        let permit = DispatchPermit {
            attempt: attempt.clone(),
            provider_id: "p".into(),
            model: "m".into(),
            expires_after: Duration::from_secs(2),
        };
        task.apply(ControlEvent::Reserved {
            job: JobId::new("j-exp"),
        })
        .unwrap();
        task.apply(ControlEvent::Admitted {
            attempt: attempt.clone(),
            permit,
        })
        .unwrap();
        task.apply(ControlEvent::Prepared {
            attempt: attempt.clone(),
            lease: lease.clone(),
        })
        .unwrap();
        assert!(matches!(
            task.state,
            RequestState::FundingPrepared { .. }
        ));
        task.apply(ControlEvent::PrepareExpired).unwrap();
        assert_eq!(task.state, RequestState::Admitting);
        assert!(!task.funded_start);
    }
}

#[cfg(test)]
mod hedge_abort_tests {
    use super::*;
    use crate::abort::abort_losing_hedge;
    use crate::provider_hub::{InboundReply, OutboundCmd, ProviderHub};
    use darkbloom_core::JobId;
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn hedge_loss_aborts_loser() {
        let (handle, mut task) = spawn_request_task(JobId::new("j-hedge"), Duration::from_secs(30));
        let _ = handle;
        task.hedge_budget.record_admit();
        assert!(task.maybe_hedge(Duration::from_secs(1)));
        assert!(task.hedge_used);

        let hub = ProviderHub::new();
        let (tx, mut rx) = mpsc::channel(8);
        hub.attach("loser".into(), 1, tx).await;
        let hub2 = hub.clone();
        tokio::spawn(async move {
            if let Some(OutboundCmd::Text(t)) = rx.recv().await {
                let v: serde_json::Value = serde_json::from_str(&t).unwrap();
                assert_eq!(v["type"], "abort");
                assert_eq!(v["reason"], "hedge_lost");
                let attempt = v["attempt_id"].as_str().unwrap().to_string();
                hub2.deliver_reply(
                    "loser",
                    &attempt,
                    InboundReply::Aborted(serde_json::json!({"type":"aborted","attempt_id":attempt})),
                )
                .await;
            }
        });
        abort_losing_hedge(&hub, "loser", "j-hedge", "a-loser", "l-loser", 1, "n", "d")
            .await
            .unwrap();
    }
}
