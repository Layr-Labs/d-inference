//! The bounded, byte-accounted consumer chunk pipe (plan §13.6, §14).
//! Invariant: `try_send` never blocks and never silently drops — a `Full`
//! pipe is the grace-window boundary the caller must act on.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use bytes::Bytes;
use tokio::sync::mpsc;

/// One content chunk flowing provider -> consumer.
#[derive(Debug, Clone)]
pub struct ChunkFrame {
    /// SSE-ready plaintext payload (v1: decrypted chunk JSON; v2: decrypted
    /// or relay bytes depending on the egress mode).
    pub payload: Bytes,
    /// v2 sequence number; 0 for v1.
    pub sequence: u64,
    /// v2 cumulative completion tokens at this chunk; 0 for v1.
    pub cumulative_tokens: u64,
}

/// Byte-accounted bounded pipe. `try_send` never blocks: the pipe IS the
/// grace window (plan §13.6) — size it for multi-second burst absorption.
pub fn chunk_pipe(max_items: usize, max_bytes: usize) -> (ChunkSender, ChunkReceiver) {
    let (tx, rx) = mpsc::channel(max_items.max(1));
    let bytes = Arc::new(AtomicUsize::new(0));
    (
        ChunkSender {
            tx,
            bytes: bytes.clone(),
            max_bytes,
        },
        ChunkReceiver { rx, bytes },
    )
}

#[derive(Clone)]
pub struct ChunkSender {
    tx: mpsc::Sender<ChunkFrame>,
    bytes: Arc<AtomicUsize>,
    max_bytes: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum PipeError {
    #[error("pipe full")]
    Full,
    #[error("pipe closed")]
    Closed,
}

impl ChunkSender {
    /// Nonblocking send with byte accounting. On `Full` the caller cancels
    /// the provider and fails the request — never silently drops (plan §13.6).
    pub fn try_send(&self, frame: ChunkFrame) -> Result<(), PipeError> {
        let len = frame.payload.len();
        let prev = self.bytes.fetch_add(len, Ordering::AcqRel);
        if prev + len > self.max_bytes {
            self.bytes.fetch_sub(len, Ordering::AcqRel);
            return Err(PipeError::Full);
        }
        match self.tx.try_send(frame) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(f)) => {
                self.bytes.fetch_sub(f.payload.len(), Ordering::AcqRel);
                Err(PipeError::Full)
            }
            Err(mpsc::error::TrySendError::Closed(f)) => {
                self.bytes.fetch_sub(f.payload.len(), Ordering::AcqRel);
                Err(PipeError::Closed)
            }
        }
    }
}

pub struct ChunkReceiver {
    rx: mpsc::Receiver<ChunkFrame>,
    bytes: Arc<AtomicUsize>,
}

impl ChunkReceiver {
    pub async fn recv(&mut self) -> Option<ChunkFrame> {
        let frame = self.rx.recv().await?;
        self.bytes.fetch_sub(frame.payload.len(), Ordering::AcqRel);
        Some(frame)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn chunk_pipe_enforces_byte_budget() {
        let (tx, mut rx) = chunk_pipe(16, 10);
        tx.try_send(ChunkFrame {
            payload: Bytes::from_static(b"123456"),
            sequence: 1,
            cumulative_tokens: 1,
        })
        .unwrap();
        // 6 + 6 > 10: second send must fail without dropping the first.
        let err = tx
            .try_send(ChunkFrame {
                payload: Bytes::from_static(b"123456"),
                sequence: 2,
                cumulative_tokens: 2,
            })
            .unwrap_err();
        assert!(matches!(err, PipeError::Full));
        let got = rx.recv().await.unwrap();
        assert_eq!(got.sequence, 1);
        // Draining frees budget.
        tx.try_send(ChunkFrame {
            payload: Bytes::from_static(b"123456"),
            sequence: 3,
            cumulative_tokens: 3,
        })
        .unwrap();
    }
}
