//! Telemetry subsystem for the provider agent.
//!
//! Architecture:
//!
//! ```text
//!   tracing::Layer ─┐
//!   panic hook ─────┤
//!   backend scraper ┼──► mpsc queue ──► async batcher ──► HTTPS POST to coordinator
//!   direct emit ────┘                               └──► disk overflow (~/.darkbloom/telemetry-queue.jsonl)
//! ```
//!
//! No free-form user content ever flows through telemetry. The coordinator
//! additionally enforces a field allowlist, but we also keep call sites clean.

pub mod client;
pub mod event;
pub mod layer;
pub mod panic_hook;
pub mod queue;
pub mod stderr_scraper;

pub use client::{TelemetryClient, TelemetryConfig};
pub use event::{Kind, Severity, Source, TelemetryBatch, TelemetryEvent};

use once_cell::sync::OnceCell;

static GLOBAL_CLIENT: OnceCell<TelemetryClient> = OnceCell::new();

/// Initialize the global telemetry client. Safe to call once per process.
/// Subsequent calls are no-ops.
pub fn init(cfg: TelemetryConfig) -> &'static TelemetryClient {
    GLOBAL_CLIENT.get_or_init(|| TelemetryClient::spawn(cfg))
}

/// Get the globally-installed client, if any.
pub fn global() -> Option<&'static TelemetryClient> {
    GLOBAL_CLIENT.get()
}

/// Emit an event through the global client. No-op if telemetry is not
/// initialized yet (e.g. during early CLI commands).
pub fn emit(event: TelemetryEvent) {
    if let Some(c) = GLOBAL_CLIENT.get() {
        c.emit(event);
    }
}
