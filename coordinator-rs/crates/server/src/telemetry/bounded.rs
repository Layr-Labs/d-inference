//! Nonblocking bounded best-effort telemetry lane.

use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

use thiserror::Error;
use tokio::sync::mpsc;

/// Hard maximum for one telemetry lane.
pub const MAX_TELEMETRY_CAPACITY: usize = 65_536;

/// Result of a best-effort telemetry emission.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TelemetryEmit {
    /// Event entered the finite lane.
    Accepted,
    /// Lane was full and the event was intentionally dropped.
    DroppedFull,
    /// Worker had exited and the event was intentionally dropped.
    DroppedClosed,
}

/// Cloneable producer with shared drop accounting.
#[derive(Debug)]
pub struct BoundedTelemetrySender<T> {
    sender: mpsc::Sender<T>,
    dropped: Arc<AtomicU64>,
}

impl<T> Clone for BoundedTelemetrySender<T> {
    fn clone(&self) -> Self {
        Self {
            sender: self.sender.clone(),
            dropped: Arc::clone(&self.dropped),
        }
    }
}

impl<T> BoundedTelemetrySender<T> {
    /// Attempts immediate publication and never blocks a request path.
    pub fn try_emit(&self, event: T) -> TelemetryEmit {
        match self.sender.try_send(event) {
            Ok(()) => TelemetryEmit::Accepted,
            Err(mpsc::error::TrySendError::Full(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                TelemetryEmit::DroppedFull
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                TelemetryEmit::DroppedClosed
            }
        }
    }

    /// Total intentionally dropped events across sender clones.
    #[must_use]
    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    /// Remaining bounded channel slots.
    #[must_use]
    pub fn remaining_capacity(&self) -> usize {
        self.sender.capacity()
    }
}

/// Sole telemetry worker input.
#[derive(Debug)]
pub struct BoundedTelemetryReceiver<T> {
    receiver: mpsc::Receiver<T>,
}

impl<T> BoundedTelemetryReceiver<T> {
    /// Receives one event or `None` after all producers exit.
    pub async fn recv(&mut self) -> Option<T> {
        self.receiver.recv().await
    }

    /// Current queued event count.
    #[must_use]
    pub fn len(&self) -> usize {
        self.receiver.len()
    }

    /// Whether the lane currently contains no event.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.receiver.is_empty()
    }
}

/// Creates one finite best-effort telemetry lane.
pub fn bounded_telemetry<T>(
    capacity: usize,
) -> Result<(BoundedTelemetrySender<T>, BoundedTelemetryReceiver<T>), TelemetryConfigError> {
    if capacity == 0 {
        return Err(TelemetryConfigError::ZeroCapacity);
    }
    if capacity > MAX_TELEMETRY_CAPACITY {
        return Err(TelemetryConfigError::CapacityTooLarge {
            actual: capacity,
            maximum: MAX_TELEMETRY_CAPACITY,
        });
    }
    let (sender, receiver) = mpsc::channel(capacity);
    let dropped = Arc::new(AtomicU64::new(0));
    Ok((
        BoundedTelemetrySender { sender, dropped },
        BoundedTelemetryReceiver { receiver },
    ))
}

/// Invalid telemetry lane configuration.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum TelemetryConfigError {
    /// Tokio channels cannot have zero slots.
    #[error("telemetry capacity must be greater than zero")]
    ZeroCapacity,
    /// Configuration exceeds the defensive hard cap.
    #[error("telemetry capacity {actual} exceeds hard maximum {maximum}")]
    CapacityTooLarge {
        /// Configured size.
        actual: usize,
        /// Hard cap.
        maximum: usize,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_lane_drops_and_counts_without_growing() {
        let (sender, receiver) = bounded_telemetry(1).expect("lane");
        assert_eq!(sender.try_emit(1), TelemetryEmit::Accepted);
        assert_eq!(sender.try_emit(2), TelemetryEmit::DroppedFull);
        assert_eq!(receiver.len(), 1);
        assert_eq!(sender.dropped(), 1);
    }
}
