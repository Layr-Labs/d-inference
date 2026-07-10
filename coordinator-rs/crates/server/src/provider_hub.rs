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
    /// WebSocket protocol pong payload (may be empty).
    Pong(Vec<u8>),
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
    /// Terminals that arrived with no waiter (between start ACK and wait_terminal).
    pending_terminals: HashMap<String, Value>,
}

#[derive(Default)]
pub struct ProviderHub {
    inner: Mutex<HashMap<String, ProviderConn>>,
}

pub type SharedHub = Arc<ProviderHub>;

/// Result of a start round-trip (DECISIONS #44).
#[derive(Debug, Clone)]
pub enum StartResult {
    Started(Value),
    /// Provider finished before/with start ACK — settle from this terminal only.
    Terminal(Value),
}

impl ProviderHub {
    pub fn new() -> SharedHub {
        Arc::new(Self::default())
    }

    /// Register a live provider connection using the session's writer sender.
    pub async fn attach(
        &self,
        provider_id: String,
        session_epoch: u64,
        outbound: mpsc::Sender<OutboundCmd>,
    ) {
        let mut g = self.inner.lock().await;
        g.insert(
            provider_id,
            ProviderConn {
                outbound,
                session_epoch,
                waiters: HashMap::new(),
                pending_terminals: HashMap::new(),
            },
        );
    }

    /// Fire-and-forget outbound (e.g. terminal_ack). No waiter.
    pub fn attach_send_best_effort(&self, provider_id: &str, cmd: OutboundCmd) {
        // Use try_lock to avoid blocking the HTTP path if the hub is busy.
        if let Ok(g) = self.inner.try_lock() {
            if let Some(conn) = g.get(provider_id) {
                let _ = conn.outbound.try_send(cmd);
            }
        }
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
            } else if let InboundReply::Terminal(v) = reply {
                // Buffer until wait_terminal claims it (DECISIONS #44).
                conn.pending_terminals.insert(attempt_id.to_string(), v);
            } else {
                tracing::warn!(
                    provider_id,
                    attempt_id,
                    waiters = conn.waiters.len(),
                    "no waiter for provider reply"
                );
            }
        } else {
            tracing::warn!(provider_id, attempt_id, "deliver_reply: provider not in hub");
        }
    }

    /// Classify a structured_error class for admission/health side effects.
    pub fn structured_error_class(v: &Value) -> Option<&str> {
        v.get("class").and_then(|c| c.as_str())
    }

    async fn send_and_wait(
        &self,
        provider_id: &str,
        attempt_id: &str,
        frame: Value,
        timeout: Duration,
    ) -> Result<InboundReply, HubError> {
        let (tx, rx) = oneshot::channel();
        let outbound = {
            let mut g = self.inner.lock().await;
            let conn = g.get_mut(provider_id).ok_or(HubError::NotConnected)?;
            conn.waiters.insert(attempt_id.to_string(), Waiter { tx });
            conn.outbound.clone()
        };
        // Send outside the hub lock so the WS writer never contends with deliver_reply.
        outbound
            .send(OutboundCmd::Text(frame.to_string()))
            .await
            .map_err(|_| HubError::Disconnected)?;
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => Err(HubError::Disconnected),
            Err(_) => {
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
    ) -> Result<StartResult, HubError> {
        match self
            .send_and_wait(provider_id, attempt_id, frame, timeout)
            .await?
        {
            InboundReply::Started(v) => Ok(StartResult::Started(v)),
            InboundReply::Terminal(v) => Ok(StartResult::Terminal(v)),
            InboundReply::StructuredError(v) => Err(HubError::Conflict(format!(
                "structured_error: {v}"
            ))),
            other => Err(HubError::Conflict(format!("expected started, got {other:?}"))),
        }
    }

    /// Wait for a provider_terminal after start (DECISIONS #44).
    /// Checks the pending buffer first so a fast terminal is not lost.
    pub async fn wait_terminal(
        &self,
        provider_id: &str,
        attempt_id: &str,
        timeout: Duration,
    ) -> Result<Value, HubError> {
        let (tx, rx) = oneshot::channel();
        {
            let mut g = self.inner.lock().await;
            let conn = g.get_mut(provider_id).ok_or(HubError::NotConnected)?;
            if let Some(v) = conn.pending_terminals.remove(attempt_id) {
                return Ok(v);
            }
            conn.waiters.insert(attempt_id.to_string(), Waiter { tx });
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(InboundReply::Terminal(v))) => Ok(v),
            Ok(Ok(InboundReply::StructuredError(v))) => Err(HubError::Conflict(format!(
                "structured_error: {v}"
            ))),
            Ok(Ok(other)) => Err(HubError::Conflict(format!(
                "expected terminal, got {other:?}"
            ))),
            Ok(Err(_)) => Err(HubError::Disconnected),
            Err(_) => {
                let mut g = self.inner.lock().await;
                if let Some(conn) = g.get_mut(provider_id) {
                    conn.waiters.remove(attempt_id);
                    // Terminal may have raced into the buffer after timeout started.
                    if let Some(v) = conn.pending_terminals.remove(attempt_id) {
                        return Ok(v);
                    }
                }
                Err(HubError::Timeout)
            }
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
        let (tx, mut rx) = mpsc::channel(8);
        hub.attach("p1".into(), 1, tx).await;
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

    #[tokio::test]
    async fn wait_terminal_claims_pending_buffer() {
        let hub = ProviderHub::new();
        let (tx, _rx) = mpsc::channel(8);
        hub.attach("p1".into(), 1, tx).await;
        hub.deliver_reply(
            "p1",
            "a1",
            InboundReply::Terminal(json!({
                "type": "provider_terminal",
                "attempt_id": "a1",
                "terminal_digest": "sha256:t1",
                "completion_tokens": 4,
                "outcome": "completed"
            })),
        )
        .await;
        let v = hub
            .wait_terminal("p1", "a1", Duration::from_millis(200))
            .await
            .unwrap();
        assert_eq!(v["terminal_digest"], "sha256:t1");
    }

    #[tokio::test]
    async fn start_then_wait_terminal_round_trip() {
        let hub = ProviderHub::new();
        let (tx, mut rx) = mpsc::channel(8);
        hub.attach("p1".into(), 1, tx).await;
        let hub2 = hub.clone();
        tokio::spawn(async move {
            while let Some(OutboundCmd::Text(t)) = rx.recv().await {
                let v: Value = serde_json::from_str(&t).unwrap();
                let attempt = v["attempt_id"].as_str().unwrap().to_string();
                if v["type"] == "start" {
                    hub2.deliver_reply(
                        "p1",
                        &attempt,
                        InboundReply::Started(json!({ "type": "started", "attempt_id": attempt })),
                    )
                    .await;
                    hub2.deliver_reply(
                        "p1",
                        &attempt,
                        InboundReply::Terminal(json!({
                            "type": "provider_terminal",
                            "attempt_id": attempt,
                            "terminal_digest": "sha256:live",
                            "completion_tokens": 8,
                            "prompt_tokens": 2,
                            "outcome": "completed"
                        })),
                    )
                    .await;
                }
            }
        });
        let started = hub
            .start(
                "p1",
                "a1",
                ProviderHub::start_frame("j", "a1", "l", 1, 1, "n", "d"),
                Duration::from_secs(2),
            )
            .await
            .unwrap();
        assert!(matches!(started, StartResult::Started(_)));
        let term = hub
            .wait_terminal("p1", "a1", Duration::from_secs(2))
            .await
            .unwrap();
        assert_eq!(term["terminal_digest"], "sha256:live");
    }
}
