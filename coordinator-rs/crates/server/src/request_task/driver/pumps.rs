//! Pump tasks feeding the driver's merged-input channel — owned by the
//! driver's [`JoinSet`](tokio::task::JoinSet) and aborted on drop, so no
//! pump outlives its request.

use tokio::sync::mpsc;

use darkbloom_core::ids::AttemptId;

use crate::contracts::{AttemptEvent, OnWire, WriteError};

use super::events::{TaskInput, WireKind, WireOutcome};
use super::Driver;

impl Driver {
    /// One combined pump per attempt, biased toward the chunk pipe: the
    /// session enqueues a chunk into the pipe (synchronously) BEFORE it
    /// sends a subsequent control event, so draining chunks first preserves
    /// wire order — a terminal can never overtake the accepted chunks that
    /// precede it (the settlement checkpoint depends on this, plan §10.6).
    pub(super) fn spawn_attempt_pump(
        &mut self,
        attempt: AttemptId,
        mut event_rx: mpsc::Receiver<AttemptEvent>,
        mut chunk_rx: crate::contracts::ChunkReceiver,
    ) {
        let tx = self.inputs_tx.clone();
        self.pumps.spawn(async move {
            let mut events_open = true;
            loop {
                tokio::select! {
                    biased;
                    chunk = chunk_rx.recv() => match chunk {
                        Some(frame) => {
                            if tx.send(TaskInput::Chunk(attempt, frame)).await.is_err() {
                                return;
                            }
                        }
                        // Chunk sender dropped: keep serving events.
                        None => {
                            while let Some(event) = event_rx.recv().await {
                                if tx.send(TaskInput::Attempt(attempt, event)).await.is_err() {
                                    return;
                                }
                            }
                            return;
                        }
                    },
                    event = event_rx.recv(), if events_open => match event {
                        Some(event) => {
                            if tx.send(TaskInput::Attempt(attempt, event)).await.is_err() {
                                return;
                            }
                        }
                        None => events_open = false,
                    },
                }
            }
        });
    }

    pub(super) fn spawn_wire_pump(&mut self, attempt: AttemptId, kind: WireKind, on_wire: OnWire) {
        let tx = self.inputs_tx.clone();
        self.pumps.spawn(async move {
            let result = match on_wire.await {
                Ok(Ok(())) => WireOutcome::Confirmed,
                Ok(Err(WriteError::SessionClosed)) => WireOutcome::Failed,
                Ok(Err(WriteError::Ambiguous)) => WireOutcome::Ambiguous,
                // The session dropped the completion without reporting: the
                // write outcome is unknowable (plan §13.2).
                Err(_) => WireOutcome::Ambiguous,
            };
            let _ = tx
                .send(TaskInput::Wire {
                    attempt,
                    kind,
                    result,
                })
                .await;
        });
    }
}
