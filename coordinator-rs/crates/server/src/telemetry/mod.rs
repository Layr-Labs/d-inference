//! Bounded best-effort telemetry and latency evidence.

mod bounded;
pub mod datadog;
mod latency;
pub(crate) mod periodic;
pub mod state;

pub use bounded::{
    BoundedTelemetryReceiver, BoundedTelemetrySender, MAX_TELEMETRY_CAPACITY, TelemetryConfigError,
    TelemetryEmit, bounded_telemetry,
};
pub use latency::{LatencyConfigError, LatencySummary, LatencyWindow, MAX_LATENCY_SAMPLES};
