//! ProviderHub — maps live provider sessions to outbound command / inbound reply lanes.
//!
//! Chat RequestTasks send prepare/start/abort through the hub; the provider WS
//! task owns the socket and demuxes replies by attempt_id.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::sync::{mpsc, oneshot, Mutex};

#[derive(Debug, Error, PartialEq, Eq)]
pub enum HubError {
    #[error("provider not connected")]
    NotConnected,
    #[error("provider mailbox full")]
    MailboxFull,
    #[error("timeout waiting for provider reply")]
    Timeout,
    #[error("provider disconnected")]
    Disconnected,
    #[error("protocol conflict: {0}")]
    Conflict(String),
}

#[derive(Debug, Clone)]
pub enum OutboundCmd {
    Text(String),
}

#[derive(Debug, Clone)]
pub enum InboundReply {
    Prepared(Value),
    Started(Value),
    Aborted(Value),
    Cancelled(Value),
    Terminal(Value),
    StructuredError(Value),
}

struct Waiter {
    tx: oneshot::Sender<InboundReply>,
}

struct ProviderConn {
    outbound: mpsc::Sender<OutboundCmd>,
    session_epoch: u64,
    waiters: HashMap<String, Waiter>,
}

#[derive(Default)]
pub struct ProviderHub {
    inner: Mutex<HashMap<String, ProviderConn>>,
}

pub type SharedHub = Arc<ProviderHub>;

impl ProviderHub {
    pub fn new() -> SharedHub {
        Arc::new(Self::default())
    }

    /// Register a live provider connection. Returns the outbound receiver the
    /// WS writer must drain. Replaces any prior session for the same id.
    pub async fn attach(
        &self,
        provider_id: String,
        session_epoch: u64,
    ) -> mpsc::Receiver<OutboundCmd> {
        let (tx, rx) = mpsc::channel(64);
        let mut g = self.inner.lock().await;
        g.insert(
            provider_id,
            ProviderConn {
                outbound: tx,
                session_epoch,
                waiters: HashMap::new(),
            },
        );
        rx
    }

    pub async fn detach(&self, provider_id: &str, session_epoch: u64) {
        let mut g = self.inner.lock().await;
        if let Some(conn) = g.get(provider_id) {
            if conn.session_epoch == session_epoch {
                g.remove(provider_id);
            }
        }
    }

    pub async fn deliver_reply(&self, provider_id: &str, attempt_id: &str, reply: InboundReply) {
        let mut g = self.inner.lock().await;
        if let Some(conn) = g.get_mut(provider_id) {
            if let Some(w) = conn.waiters.remove(attempt_id) {
                let _ = w.tx.send(reply);
            }
        }
    }

    async fn send_and_wait(
        &self,
        provider_id: &str,
        attempt_id: &str,
        frame: Value,
        timeout: Duration,
    ) -> Result<InboundReply, HubError> {
        let (tx, rx) = oneshot::channel();
        {
            let mut g = self.inner.lock().await;
            let conn = g.get_mut(provider_id).ok_or(HubError::NotConnected)?;
            conn.waiters.insert(attempt_id.to_string(), Waiter { tx });
            let text = frame.to_string();
            conn.outbound
                .try_send(OutboundCmd::Text(text))
                .map_err(|_| HubError::MailboxFull)?;
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => Err(HubError::Disconnected),
            Err(_) => {
                // Clean up waiter on timeout.
                let mut g = self.inner.lock().await;
                if let Some(conn) = g.get_mut(provider_id) {
                    conn.waiters.remove(attempt_id);
                }
                Err(HubError::Timeout)
            }
        }
    }

    pub async fn prepare(
        &self,
        provider_id: &str,
        attempt_id: &str,
        frame: Value,
        timeout: Duration,
    ) -> Result<Value, HubError> {
        match self
            .send_and_wait(provider_id, attempt_id, frame, timeout)
            .await?
        {
            InboundReply::Prepared(v) => Ok(v),
            InboundReply::StructuredError(v) => Err(HubError::Conflict(format!(
                "structured_error: {v}"
            ))),
            other => Err(HubError::Conflict(format!("expected prepared, got {other:?}"))),
        }
    }

    pub async fn start(
        &self,
        provider_id: &str,
        attempt_id: &str,
        frame: Value,
        timeout: Duration,
    ) -> Result<Value, HubError> {
        match self
            .send_and_wait(provider_id, attempt_id, frame, timeout)
            .await?
        {
            InboundReply::Started(v) => Ok(v),
            InboundReply::Terminal(v) => Ok(v), // fast path: terminal may arrive with started
            InboundReply::StructuredError(v) => Err(HubError::Conflict(format!(
                "structured_error: {v}"
            ))),
            other => Err(HubError::Conflict(format!("expected started, got {other:?}"))),
        }
    }

    pub async fn abort(
        &self,
        provider_id: &str,
        attempt_id: &str,
        frame: Value,
        timeout: Duration,
    ) -> Result<Value, HubError> {
        match self
            .send_and_wait(provider_id, attempt_id, frame, timeout)
            .await?
        {
            InboundReply::Aborted(v) | InboundReply::Cancelled(v) => Ok(v),
            other => Err(HubError::Conflict(format!("expected aborted, got {other:?}"))),
        }
    }

    pub fn prepare_frame(
        job_id: &str,
        attempt_id: &str,
        lease_id: &str,
        session_epoch: u64,
        coordinator_epoch: u64,
        dispatch_nonce: &str,
        request_digest: &str,
        model: &str,
        encrypted_body: Option<&str>,
    ) -> Value {
        let mut v = json!({
            "type": "prepare",
            "job_id": job_id,
            "attempt_id": attempt_id,
            "lease_id": lease_id,
            "session_epoch": session_epoch,
            "coordinator_epoch": coordinator_epoch,
            "dispatch_nonce": dispatch_nonce,
            "request_digest": request_digest,
            "model": model,
        });
        if let Some(body) = encrypted_body {
            v["encrypted_body"] = json!(body);
        }
        v
    }

    pub fn start_frame(
        job_id: &str,
        attempt_id: &str,
        lease_id: &str,
        session_epoch: u64,
        coordinator_epoch: u64,
        dispatch_nonce: &str,
        request_digest: &str,
    ) -> Value {
        json!({
            "type": "start",
            "job_id": job_id,
            "attempt_id": attempt_id,
            "lease_id": lease_id,
            "session_epoch": session_epoch,
            "coordinator_epoch": coordinator_epoch,
            "dispatch_nonce": dispatch_nonce,
            "request_digest": request_digest,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn prepare_round_trip() {
        let hub = ProviderHub::new();
        let mut rx = hub.attach("p1".into(), 1).await;
        let hub2 = hub.clone();
        let writer = tokio::spawn(async move {
            if let Some(OutboundCmd::Text(t)) = rx.recv().await {
                let v: Value = serde_json::from_str(&t).unwrap();
                assert_eq!(v["type"], "prepare");
                let attempt = v["attempt_id"].as_str().unwrap().to_string();
                hub2.deliver_reply(
                    "p1",
                    &attempt,
                    InboundReply::Prepared(json!({
                        "type": "prepared",
                        "attempt_id": attempt,
                        "lease_ttl_ms": 15000,
                        "prompt_tokens": 1,
                        "max_output_tokens": 8,
                        "engine_queue_depth": 0,
                        "prefill_can_begin": true
                    })),
                )
                .await;
            }
        });
        let reply = hub
            .prepare(
                "p1",
                "a1",
                ProviderHub::prepare_frame("j", "a1", "l", 1, 1, "n", "d", "m", None),
                Duration::from_secs(2),
            )
            .await
            .unwrap();
        assert_eq!(reply["type"], "prepared");
        writer.await.unwrap();
    }
}
