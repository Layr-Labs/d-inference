//! Cancel-before-content path (plan §13.1–13.4).

use crate::abort::{abort_losing_hedge, cancel_attempt};
use crate::ledger::{MemoryLedger, OperationKey};
use crate::provider_hub::SharedHub;
use crate::request_task::{ControlEvent, RequestTask};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CancelOutcome {
    /// Never reached the provider wire — release reservation only.
    DiscardedLocal,
    /// Prepared lease aborted.
    Aborted,
    /// Started attempt cancelled; await terminal.
    CancelledAwaitTerminal,
    /// Already past first content — cancel sent, no reroute.
    CancelAfterContent,
}

pub async fn cancel_before_or_after_content(
    task: &mut RequestTask,
    hub: &SharedHub,
    ledger: &Arc<Mutex<MemoryLedger>>,
    account: &str,
    provider_id: &str,
    job_id: &str,
    attempt_id: &str,
    lease_id: &str,
    coordinator_epoch: u64,
    dispatch_nonce: &str,
    request_digest: &str,
    had_first_content: bool,
) -> Result<CancelOutcome, String> {
    let _ = task.apply(ControlEvent::Cancel);
    if had_first_content {
        let _ = cancel_attempt(
            hub,
            provider_id,
            job_id,
            attempt_id,
            lease_id,
            coordinator_epoch,
            dispatch_nonce,
            request_digest,
        )
        .await;
        return Ok(CancelOutcome::CancelAfterContent);
    }
    if task.funded_start {
        let _ = cancel_attempt(
            hub,
            provider_id,
            job_id,
            attempt_id,
            lease_id,
            coordinator_epoch,
            dispatch_nonce,
            request_digest,
        )
        .await;
        return Ok(CancelOutcome::CancelledAwaitTerminal);
    }
    // Pre-start: abort lease if any, release reservation.
    let _ = abort_losing_hedge(
        hub,
        provider_id,
        job_id,
        attempt_id,
        lease_id,
        coordinator_epoch,
        dispatch_nonce,
        request_digest,
    )
    .await;
    let mut g = ledger.lock().map_err(|e| e.to_string())?;
    let _ = g.release(
        OperationKey(format!("cancel_release:{job_id}")),
        job_id,
        account,
    );
    if task.hedge_used {
        Ok(CancelOutcome::Aborted)
    } else {
        Ok(CancelOutcome::DiscardedLocal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider_hub::ProviderHub;
    use crate::request_task::spawn_request_task;
    use darkbloom_core::JobId;
    use std::time::Duration;
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn pre_start_cancel_releases_reservation() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0);
            g.reserve(OperationKey("r".into()), "j1", "a", 50_000)
                .unwrap();
        }
        let (_h, mut task) = spawn_request_task(JobId::new("j1"), Duration::from_secs(30));
        let hub = ProviderHub::new();
        let (tx, mut rx) = mpsc::channel(4);
        hub.attach("p".into(), 1, tx).await;
        let hub2 = hub.clone();
        tokio::spawn(async move {
            while let Some(crate::provider_hub::OutboundCmd::Text(t)) = rx.recv().await {
                let v: serde_json::Value = serde_json::from_str(&t).unwrap();
                let attempt = v["attempt_id"].as_str().unwrap_or("a1").to_string();
                let reply = if v["type"] == "abort" {
                    crate::provider_hub::InboundReply::Aborted(serde_json::json!({
                        "type": "aborted",
                        "attempt_id": attempt
                    }))
                } else {
                    crate::provider_hub::InboundReply::Cancelled(serde_json::json!({
                        "type": "cancelled",
                        "attempt_id": attempt
                    }))
                };
                hub2.deliver_reply("p", &attempt, reply).await;
            }
        });
        let out = cancel_before_or_after_content(
            &mut task, &hub, &led, "a", "p", "j1", "a1", "l1", 1, "n", "d", false,
        )
        .await
        .unwrap();
        assert_eq!(out, CancelOutcome::DiscardedLocal);
        assert_eq!(led.lock().unwrap().balance("a").0, 1_000_000);
    }
}
