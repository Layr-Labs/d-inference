//! Bounded byte pipe for consumer output (plan §13.6 / §14).
//!
//! Sized as the client grace window — multi-second burst absorption.
//! Full pipe cancels the request; never blocks the provider reader.
//! Each accepted chunk advances a monotonic sequence for billing checkpoints.

use bytes::Bytes;
use std::sync::atomic::{AtomicU64, Ordering};
use thiserror::Error;
use tokio::sync::mpsc;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PipeError {
    #[error("pipe full")]
    Full,
    #[error("pipe closed")]
    Closed,
}

#[derive(Debug, Clone)]
pub struct SequencedChunk {
    pub sequence: u64,
    pub bytes: Bytes,
}

pub struct ChunkPipe {
    tx: mpsc::Sender<SequencedChunk>,
    bytes_enqueued: AtomicU64,
    next_sequence: AtomicU64,
    max_bytes: u64,
}

pub struct ChunkPipeReader {
    rx: mpsc::Receiver<SequencedChunk>,
}

/// Default: ~512 KiB — several seconds of typical token throughput.
pub const DEFAULT_PIPE_BYTES: u64 = 512 * 1024;
pub const DEFAULT_PIPE_ITEMS: usize = 1024;

pub fn bounded_chunk_pipe(max_items: usize, max_bytes: u64) -> (ChunkPipe, ChunkPipeReader) {
    let (tx, rx) = mpsc::channel(max_items);
    (
        ChunkPipe {
            tx,
            bytes_enqueued: AtomicU64::new(0),
            next_sequence: AtomicU64::new(1),
            max_bytes,
        },
        ChunkPipeReader { rx },
    )
}

impl ChunkPipe {
    /// Nonblocking enqueue. Provider reader must never await this.
    /// Returns the assigned sequence on success.
    pub fn try_send(&self, chunk: Bytes) -> Result<u64, PipeError> {
        let len = chunk.len() as u64;
        let cur = self.bytes_enqueued.load(Ordering::Relaxed);
        if cur + len > self.max_bytes {
            return Err(PipeError::Full);
        }
        let sequence = self.next_sequence.fetch_add(1, Ordering::Relaxed);
        match self.tx.try_send(SequencedChunk {
            sequence,
            bytes: chunk,
        }) {
            Ok(()) => {
                self.bytes_enqueued.fetch_add(len, Ordering::Relaxed);
                Ok(sequence)
            }
            Err(mpsc::error::TrySendError::Full(_)) => Err(PipeError::Full),
            Err(mpsc::error::TrySendError::Closed(_)) => Err(PipeError::Closed),
        }
    }

    pub fn bytes_enqueued(&self) -> u64 {
        self.bytes_enqueued.load(Ordering::Relaxed)
    }

    pub fn next_sequence(&self) -> u64 {
        self.next_sequence.load(Ordering::Relaxed)
    }
}

impl ChunkPipeReader {
    pub async fn recv(&mut self) -> Option<SequencedChunk> {
        self.rx.recv().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_when_byte_budget_exceeded() {
        let (pipe, _reader) = bounded_chunk_pipe(16, 8);
        assert_eq!(pipe.try_send(Bytes::from_static(b"12345678")).unwrap(), 1);
        assert_eq!(
            pipe.try_send(Bytes::from_static(b"x")).unwrap_err(),
            PipeError::Full
        );
    }

    #[tokio::test]
    async fn sequences_are_monotonic() {
        let (pipe, mut reader) = bounded_chunk_pipe(16, 1024);
        assert_eq!(pipe.try_send(Bytes::from_static(b"a")).unwrap(), 1);
        assert_eq!(pipe.try_send(Bytes::from_static(b"b")).unwrap(), 2);
        let c1 = reader.recv().await.unwrap();
        let c2 = reader.recv().await.unwrap();
        assert_eq!(c1.sequence, 1);
        assert_eq!(c2.sequence, 2);
        assert_eq!(c1.bytes.as_ref(), b"a");
    }
}
