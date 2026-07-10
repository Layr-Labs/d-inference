//! ProviderSession: one WebSocket connection, one connection epoch.
//!
//! Milestone 3 scaffolding — writer lanes and attempt routing without full
//! tungstenite integration tests (those land with the dual-stack E2E).

use bytes::Bytes;
use std::collections::HashMap;
use tokio::sync::{mpsc, oneshot};

const CONTROL_CAP: usize = 64;
const DATA_CAP: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lane {
    Control,
    Data,
}

#[derive(Debug)]
pub struct OutboundFrame {
    pub lane: Lane,
    pub bytes: Bytes,
    pub done: Option<oneshot::Sender<Result<(), SessionError>>>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SessionError {
    #[error("control lane full — fencing session")]
    ControlLaneFull,
    #[error("data lane full")]
    DataLaneFull,
    #[error("session closed")]
    Closed,
    #[error("stale session epoch")]
    StaleEpoch,
}

/// Process-local session handle used by RequestTask to enqueue frames.
#[derive(Clone)]
pub struct ProviderSessionHandle {
    pub provider_id: String,
    pub session_epoch: u64,
    control_tx: mpsc::Sender<OutboundFrame>,
    data_tx: mpsc::Sender<OutboundFrame>,
}

impl ProviderSessionHandle {
    pub async fn enqueue(
        &self,
        lane: Lane,
        bytes: Bytes,
    ) -> Result<oneshot::Receiver<Result<(), SessionError>>, SessionError> {
        let (tx, rx) = oneshot::channel();
        let frame = OutboundFrame {
            lane,
            bytes,
            done: Some(tx),
        };
        match lane {
            Lane::Control => self
                .control_tx
                .try_send(frame)
                .map_err(|_| SessionError::ControlLaneFull)?,
            Lane::Data => self
                .data_tx
                .try_send(frame)
                .map_err(|_| SessionError::DataLaneFull)?,
        }
        Ok(rx)
    }

    pub fn data_lane_full(&self) -> bool {
        self.data_tx.capacity() == 0
    }
}

pub struct ProviderSession {
    pub provider_id: String,
    pub session_epoch: u64,
    control_rx: mpsc::Receiver<OutboundFrame>,
    data_rx: mpsc::Receiver<OutboundFrame>,
    /// attempt_id → sink for control events (not content chunks).
    attempt_sinks: HashMap<String, mpsc::Sender<SessionEvent>>,
}

#[derive(Debug, Clone)]
pub enum SessionEvent {
    Prepared,
    Started,
    Aborted,
    Terminal { digest: String },
    StructuredError { class: String },
    Closed,
}

pub fn spawn_session(provider_id: String, session_epoch: u64) -> (ProviderSessionHandle, ProviderSession) {
    let (control_tx, control_rx) = mpsc::channel(CONTROL_CAP);
    let (data_tx, data_rx) = mpsc::channel(DATA_CAP);
    let handle = ProviderSessionHandle {
        provider_id: provider_id.clone(),
        session_epoch,
        control_tx,
        data_tx,
    };
    let session = ProviderSession {
        provider_id,
        session_epoch,
        control_rx,
        data_rx,
        attempt_sinks: HashMap::new(),
    };
    (handle, session)
}

impl ProviderSession {
    /// Writer loop: control has non-preemptive priority over data.
    pub async fn run_writer<F>(mut self, mut write: F)
    where
        F: FnMut(Bytes) -> Result<(), SessionError> + Send,
    {
        loop {
            tokio::select! {
                biased;
                frame = self.control_rx.recv() => {
                    match frame {
                        None => break,
                        Some(frame) => {
                            let res = write(frame.bytes);
                            if let Some(done) = frame.done {
                                let _ = done.send(res);
                            }
                        }
                    }
                }
                frame = self.data_rx.recv(), if self.control_rx.is_empty() => {
                    match frame {
                        None => break,
                        Some(frame) => {
                            let res = write(frame.bytes);
                            if let Some(done) = frame.done {
                                let _ = done.send(res);
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn register_attempt(&mut self, attempt_id: String, tx: mpsc::Sender<SessionEvent>) {
        self.attempt_sinks.insert(attempt_id, tx);
    }

    pub fn route_event(&self, attempt_id: &str, event: SessionEvent) {
        if let Some(tx) = self.attempt_sinks.get(attempt_id) {
            let _ = tx.try_send(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[tokio::test]
    async fn control_priority_over_data() {
        let (handle, session) = spawn_session("p1".into(), 1);
        let order = Arc::new(Mutex::new(Vec::new()));
        let order2 = order.clone();
        let writer = tokio::spawn(async move {
            session
                .run_writer(move |bytes| {
                    order2
                        .lock()
                        .unwrap()
                        .push(String::from_utf8_lossy(&bytes).to_string());
                    Ok(())
                })
                .await;
        });

        // Fill data first, then control — control should still flush first when
        // the writer wakes because select is biased to control.
        let _ = handle
            .enqueue(Lane::Data, Bytes::from_static(b"data"))
            .await
            .unwrap();
        let _ = handle
            .enqueue(Lane::Control, Bytes::from_static(b"ctrl"))
            .await
            .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        drop(handle);
        let _ = writer.await;
        let got = order.lock().unwrap().clone();
        assert!(got.contains(&"ctrl".to_string()));
        assert!(got.contains(&"data".to_string()));
        // First written frame should be control due to biased select.
        assert_eq!(got.first().map(String::as_str), Some("ctrl"));
    }

    #[tokio::test]
    async fn data_lane_full_errors() {
        let (handle, _session) = spawn_session("p1".into(), 1);
        for _ in 0..DATA_CAP {
            handle
                .enqueue(Lane::Data, Bytes::from_static(b"x"))
                .await
                .unwrap();
        }
        let err = handle
            .enqueue(Lane::Data, Bytes::from_static(b"y"))
            .await
            .unwrap_err();
        assert_eq!(err, SessionError::DataLaneFull);
    }
}
