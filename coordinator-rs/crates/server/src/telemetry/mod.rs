//! Bounded best-effort telemetry and latency evidence.

mod bounded;
mod latency;

pub use bounded::{
    BoundedTelemetryReceiver, BoundedTelemetrySender, MAX_TELEMETRY_CAPACITY, TelemetryConfigError,
    TelemetryEmit, bounded_telemetry,
};
pub use latency::{LatencyConfigError, LatencySummary, LatencyWindow, MAX_LATENCY_SAMPLES};
