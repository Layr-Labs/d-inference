use std::{sync::Arc, time::Duration};

use tokio_util::sync::CancellationToken;

use crate::telemetry::{
    BoundedTelemetryReceiver, BoundedTelemetrySender, LatencyConfigError, LatencySummary,
    LatencyWindow, TelemetryConfigError, bounded_telemetry,
};

const LATENCY_WINDOW_CAPACITY: usize = 4_096;
const LATENCY_MINIMUM_SAMPLES: usize = 32;

/// Payload-free pilot events emitted from bounded hot paths.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PilotTelemetryEvent {
    ProviderConnected,
    ProviderRejected,
    RequestAccepted,
    RequestRejected,
    RequestCompleted { latency: Duration },
    RequestFailed { latency: Duration },
}

/// Cloneable nonblocking pilot telemetry producer.
#[derive(Clone, Debug)]
pub struct PilotTelemetry {
    sender: BoundedTelemetrySender<PilotTelemetryEvent>,
    latency: Arc<LatencyWindow>,
}

impl PilotTelemetry {
    pub fn new(capacity: usize) -> Result<(Self, PilotTelemetryWorker), PilotTelemetryConfigError> {
        let (sender, receiver) = bounded_telemetry(capacity)?;
        let latency = Arc::new(LatencyWindow::new(
            LATENCY_WINDOW_CAPACITY,
            LATENCY_MINIMUM_SAMPLES,
        )?);
        Ok((
            Self {
                sender,
                latency: latency.clone(),
            },
            PilotTelemetryWorker { receiver, latency },
        ))
    }

    pub fn emit(&self, event: PilotTelemetryEvent) {
        let _ = self.sender.try_emit(event);
    }

    #[must_use]
    pub fn dropped(&self) -> u64 {
        self.sender.dropped()
    }

    #[must_use]
    pub fn remaining_capacity(&self) -> usize {
        self.sender.remaining_capacity()
    }

    #[must_use]
    pub fn latency_summary(&self) -> Option<LatencySummary> {
        self.latency.summary()
    }
}

/// Sole owner of telemetry consumption and latency samples.
pub struct PilotTelemetryWorker {
    receiver: BoundedTelemetryReceiver<PilotTelemetryEvent>,
    latency: Arc<LatencyWindow>,
}

impl PilotTelemetryWorker {
    pub async fn run(mut self, cancellation: CancellationToken) -> Result<(), PilotTelemetryError> {
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                event = self.receiver.recv() => {
                    let Some(event) = event else {
                        return Err(PilotTelemetryError::MailboxClosed);
                    };
                    match event {
                        PilotTelemetryEvent::RequestCompleted { latency }
                        | PilotTelemetryEvent::RequestFailed { latency } => {
                            self.latency.record(latency);
                        }
                        PilotTelemetryEvent::ProviderConnected
                        | PilotTelemetryEvent::ProviderRejected
                        | PilotTelemetryEvent::RequestAccepted
                        | PilotTelemetryEvent::RequestRejected => {}
                    }
                }
            }
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum PilotTelemetryConfigError {
    #[error(transparent)]
    Lane(#[from] TelemetryConfigError),
    #[error(transparent)]
    Latency(#[from] LatencyConfigError),
}

#[derive(Clone, Copy, Debug, Eq, thiserror::Error, PartialEq)]
pub enum PilotTelemetryError {
    #[error("pilot telemetry mailbox closed before shutdown")]
    MailboxClosed,
}
