//! Cancel-before-content path (plan §13.1–13.4).

use crate::abort::{abort_losing_hedge, cancel_attempt};
use crate::ledger::{MemoryLedger, OperationKey};
use crate::outbox::Outbox;
use crate::ownership::Gate as OwnershipGate;
use crate::provider_hub::SharedHub;
use crate::request_task::{ControlEvent, RequestTask};
use std::sync::{Arc, Mutex};
use tokio::sync::Mutex as AsyncMutex;

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
    outbox: Option<&Arc<AsyncMutex<Outbox>>>,
    ownership: Option<&OwnershipGate>,
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
    // Money-boundary fence: refuse release after ownership loss (DECISIONS #47).
    if let Some(gate) = ownership {
        if gate.assert_holding().is_err() {
            return Err("ownership_lost: refusing cancel release".into());
        }
    }
    let (released, refunded) = {
        let mut g = ledger.lock().map_err(|e| e.to_string())?;
        let reserved = g.job_reserved_total(job_id).map(|m| m.0).unwrap_or(0);
        let ok = g
            .release(
                OperationKey(format!("cancel_release:{job_id}")),
                job_id,
                account,
            )
            .map_err(|e| e.to_string())?;
        (ok, reserved)
    };
    if released {
        if let Some(box_) = outbox {
            let mut b = box_.lock().await;
            let _ = b.enqueue_released(job_id, account, refunded);
        }
    }
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
        let outbox = Arc::new(AsyncMutex::new(Outbox::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
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
            &mut task,
            &hub,
            &led,
            "a",
            "p",
            "j1",
            "a1",
            "l1",
            1,
            "n",
            "d",
            false,
            Some(&outbox),
        None,
        )
        .await
        .unwrap();
        assert_eq!(out, CancelOutcome::DiscardedLocal);
        assert_eq!(led.lock().unwrap().balance("a").0, 1_000_000);
        let box_ = outbox.lock().await;
        assert_eq!(box_.len(), 1);
        // Peek via claim.
        drop(box_);
        let e = outbox.lock().await.try_claim().unwrap();
        assert_eq!(e.kind, "inference.released");
        let payload: serde_json::Value = serde_json::from_str(&e.payload).unwrap();
        assert_eq!(payload["refunded_micro_usd"], 50_000);
    }

    #[tokio::test]
    async fn funded_start_cancel_awaits_terminal_without_release() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        let outbox = Arc::new(AsyncMutex::new(Outbox::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j2", "a", 50_000)
                .unwrap();
            g.mark_start_authorized("j2", "a").unwrap();
        }
        let (_h, mut task) = spawn_request_task(JobId::new("j2"), Duration::from_secs(30));
        task.funded_start = true;
        let hub = ProviderHub::new();
        let (tx, mut rx) = mpsc::channel(4);
        hub.attach("p".into(), 1, tx).await;
        let hub2 = hub.clone();
        tokio::spawn(async move {
            while let Some(crate::provider_hub::OutboundCmd::Text(t)) = rx.recv().await {
                let v: serde_json::Value = serde_json::from_str(&t).unwrap();
                let attempt = v["attempt_id"].as_str().unwrap_or("a1").to_string();
                hub2.deliver_reply(
                    "p",
                    &attempt,
                    crate::provider_hub::InboundReply::Cancelled(serde_json::json!({
                        "type": "cancelled",
                        "attempt_id": attempt
                    })),
                )
                .await;
            }
        });
        let out = cancel_before_or_after_content(
            &mut task,
            &hub,
            &led,
            "a",
            "p",
            "j2",
            "a1",
            "l1",
            1,
            "n",
            "d",
            false,
            Some(&outbox),
        None,
        )
        .await
        .unwrap();
        assert_eq!(out, CancelOutcome::CancelledAwaitTerminal);
        // Money still held — settle/force_settle must clear it.
        assert_eq!(led.lock().unwrap().balance("a").0, 950_000);
        assert_eq!(led.lock().unwrap().active_job_count(), 1);
        assert!(led.lock().unwrap().job_funded_start("j2"));
        assert_eq!(outbox.lock().await.len(), 0);
    }

    #[tokio::test]
    async fn after_content_cancel_does_not_release() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        let outbox = Arc::new(AsyncMutex::new(Outbox::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j3", "a", 50_000)
                .unwrap();
            g.mark_start_authorized("j3", "a").unwrap();
        }
        let (_h, mut task) = spawn_request_task(JobId::new("j3"), Duration::from_secs(30));
        task.funded_start = true;
        let hub = ProviderHub::new();
        let (tx, mut rx) = mpsc::channel(4);
        hub.attach("p".into(), 1, tx).await;
        let hub2 = hub.clone();
        tokio::spawn(async move {
            while let Some(crate::provider_hub::OutboundCmd::Text(t)) = rx.recv().await {
                let v: serde_json::Value = serde_json::from_str(&t).unwrap();
                let attempt = v["attempt_id"].as_str().unwrap_or("a1").to_string();
                hub2.deliver_reply(
                    "p",
                    &attempt,
                    crate::provider_hub::InboundReply::Cancelled(serde_json::json!({
                        "type": "cancelled",
                        "attempt_id": attempt
                    })),
                )
                .await;
            }
        });
        let out = cancel_before_or_after_content(
            &mut task,
            &hub,
            &led,
            "a",
            "p",
            "j3",
            "a1",
            "l1",
            1,
            "n",
            "d",
            true,
            Some(&outbox),
        None,
        )
        .await
        .unwrap();
        assert_eq!(out, CancelOutcome::CancelAfterContent);
        assert_eq!(led.lock().unwrap().balance("a").0, 950_000);
        assert_eq!(led.lock().unwrap().active_job_count(), 1);
        assert_eq!(outbox.lock().await.len(), 0);
    }

    #[tokio::test]
    async fn hedge_pre_start_cancel_returns_aborted() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        let outbox = Arc::new(AsyncMutex::new(Outbox::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j4", "a", 50_000)
                .unwrap();
        }
        let (_h, mut task) = spawn_request_task(JobId::new("j4"), Duration::from_secs(30));
        task.hedge_used = true;
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
            &mut task,
            &hub,
            &led,
            "a",
            "p",
            "j4",
            "a1",
            "l1",
            1,
            "n",
            "d",
            false,
            Some(&outbox),
        None,
        )
        .await
        .unwrap();
        assert_eq!(out, CancelOutcome::Aborted);
        assert_eq!(led.lock().unwrap().balance("a").0, 1_000_000);
        assert_eq!(led.lock().unwrap().active_job_count(), 0);
        assert_eq!(outbox.lock().await.len(), 1);
    }

    #[tokio::test]
    async fn pre_start_cancel_refuses_release_after_ownership_loss() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        let outbox = Arc::new(AsyncMutex::new(Outbox::default()));
        let gate = OwnershipGate::new(true);
        gate.acquire(crate::ownership::Epoch(1)).unwrap();
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j-own", "a", 50_000)
                .unwrap();
        }
        gate.release();
        let (_h, mut task) = spawn_request_task(JobId::new("j-own"), Duration::from_secs(30));
        let hub = ProviderHub::new();
        let err = cancel_before_or_after_content(
            &mut task,
            &hub,
            &led,
            "a",
            "p",
            "j-own",
            "a1",
            "l1",
            1,
            "n",
            "d",
            false,
            Some(&outbox),
            Some(&gate),
        )
        .await
        .unwrap_err();
        assert!(err.contains("ownership_lost"));
        assert_eq!(led.lock().unwrap().balance("a").0, 950_000);
        assert_eq!(led.lock().unwrap().active_job_count(), 1);
        assert_eq!(outbox.lock().await.len(), 0);
    }
}
