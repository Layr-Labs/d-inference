//! Panic hook integration. Captures backtrace on panic and flushes a
//! `KindPanic` event via the blocking emit path, then forwards to the previous
//! hook so the normal abort path still runs.

use crate::telemetry::client::TelemetryClient;
use crate::telemetry::event::{Kind, Severity, Source, TelemetryEvent};
use std::sync::atomic::{AtomicBool, Ordering};

/// Guard against re-entrant panics inside the hook itself.
static IN_HOOK: AtomicBool = AtomicBool::new(false);

/// Install the global panic hook. Idempotent — calling twice overwrites the
/// previous telemetry hook but preserves the hook chain via `take_hook`.
pub fn install(client: TelemetryClient) {
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        // Always run the previous hook even if our path fails.
        if IN_HOOK.swap(true, Ordering::SeqCst) {
            prev(info);
            return;
        }

        let message = panic_message(info);
        let location = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "unknown".into());

        // Capture a backtrace — std::backtrace honors RUST_BACKTRACE env.
        let bt = std::backtrace::Backtrace::force_capture();
        let stack = format!("at {location}\n{bt}");

        let ev = TelemetryEvent::new(
            Source::Provider,
            Severity::Fatal,
            Kind::Panic,
            format!("panic: {message}"),
        )
        .with_stack(stack)
        .with_field("component", "provider");

        client.emit_blocking(ev);

        IN_HOOK.store(false, Ordering::SeqCst);
        prev(info);
    }));
}

fn panic_message(info: &std::panic::PanicHookInfo<'_>) -> String {
    if let Some(s) = info.payload().downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = info.payload().downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".into()
    }
}
