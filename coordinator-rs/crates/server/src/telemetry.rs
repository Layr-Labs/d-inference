//! Bounded telemetry sink (plan §9.4 / §14) — drop with counter, never block.

use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub struct TelemetryEvent {
    pub name: String,
    pub tags: Vec<(String, String)>,
}

pub struct TelemetrySink {
    tx: mpsc::Sender<TelemetryEvent>,
    dropped: AtomicU64,
    emitted: AtomicU64,
}

pub struct TelemetryWorker {
    rx: mpsc::Receiver<TelemetryEvent>,
}

pub fn bounded_telemetry(capacity: usize) -> (TelemetrySink, TelemetryWorker) {
    let (tx, rx) = mpsc::channel(capacity);
    (
        TelemetrySink {
            tx,
            dropped: AtomicU64::new(0),
            emitted: AtomicU64::new(0),
        },
        TelemetryWorker { rx },
    )
}

impl TelemetrySink {
    /// Nonblocking emit. Overflow increments drop counter.
    pub fn try_emit(&self, event: TelemetryEvent) {
        match self.tx.try_send(event) {
            Ok(()) => {
                self.emitted.fetch_add(1, Ordering::Relaxed);
            }
            Err(_) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    pub fn emitted(&self) -> u64 {
        self.emitted.load(Ordering::Relaxed)
    }
}

impl TelemetryWorker {
    pub async fn drain_one(&mut self) -> Option<TelemetryEvent> {
        self.rx.recv().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn drops_when_full() {
        let (sink, mut worker) = bounded_telemetry(1);
        sink.try_emit(TelemetryEvent {
            name: "a".into(),
            tags: vec![],
        });
        sink.try_emit(TelemetryEvent {
            name: "b".into(),
            tags: vec![],
        });
        assert_eq!(sink.emitted(), 1);
        assert_eq!(sink.dropped(), 1);
        let ev = worker.drain_one().await.unwrap();
        assert_eq!(ev.name, "a");
    }
}
