//! AbortCommand frame builder + hedge-loss abort helper.

use serde_json::{json, Value};
use std::time::Duration;

use crate::provider_hub::{HubError, SharedHub};
#[cfg(test)]
use crate::provider_hub::ProviderHub;

pub fn abort_frame(
    job_id: &str,
    attempt_id: &str,
    lease_id: &str,
    session_epoch: u64,
    coordinator_epoch: u64,
    dispatch_nonce: &str,
    request_digest: &str,
    reason: &str,
) -> Value {
    json!({
        "type": "abort",
        "job_id": job_id,
        "attempt_id": attempt_id,
        "lease_id": lease_id,
        "session_epoch": session_epoch,
        "coordinator_epoch": coordinator_epoch,
        "dispatch_nonce": dispatch_nonce,
        "request_digest": request_digest,
        "reason": reason,
    })
}

/// Abort the losing hedge lease. Safe to call when the provider is gone.
pub async fn abort_losing_hedge(
    hub: &SharedHub,
    provider_id: &str,
    job_id: &str,
    attempt_id: &str,
    lease_id: &str,
    coordinator_epoch: u64,
    dispatch_nonce: &str,
    request_digest: &str,
) -> Result<(), HubError> {
    let frame = abort_frame(
        job_id,
        attempt_id,
        lease_id,
        0,
        coordinator_epoch,
        dispatch_nonce,
        request_digest,
        "hedge_lost",
    );
    match hub
        .abort(provider_id, attempt_id, frame, Duration::from_secs(5))
        .await
    {
        Ok(_) => Ok(()),
        Err(HubError::NotConnected) => Ok(()), // already gone
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider_hub::{InboundReply, OutboundCmd};
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn abort_round_trip() {
        let hub = ProviderHub::new();
        let (tx, mut rx) = mpsc::channel(8);
        hub.attach("p1".into(), 1, tx).await;
        let hub2 = hub.clone();
        tokio::spawn(async move {
            if let Some(OutboundCmd::Text(t)) = rx.recv().await {
                let v: Value = serde_json::from_str(&t).unwrap();
                assert_eq!(v["type"], "abort");
                assert_eq!(v["reason"], "hedge_lost");
                let attempt = v["attempt_id"].as_str().unwrap().to_string();
                hub2.deliver_reply(
                    "p1",
                    &attempt,
                    InboundReply::Aborted(json!({"type":"aborted","attempt_id": attempt})),
                )
                .await;
            }
        });
        abort_losing_hedge(&hub, "p1", "j", "a1", "l", 1, "n", "d")
            .await
            .unwrap();
    }
}
