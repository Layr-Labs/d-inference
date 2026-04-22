//! Classifier for child-process stderr lines (vllm-mlx, image-bridge).
//!
//! We don't want to re-implement log parsing; we just detect the obvious
//! "something died" signals and forward them as telemetry events. Everything
//! else is left to the normal log forwarding in `backend::mod`.

use crate::telemetry::event::{Kind, Severity, Source, TelemetryEvent};

/// Classification result for a single stderr line.
pub enum Classification {
    /// Ignore — routine log noise.
    Ignore,
    /// Warn-level event worth surfacing (e.g. "retrying...").
    Warn(String),
    /// Error-level event (Python traceback, unhandled exception).
    Error(String),
}

/// Inspect a stderr line and return a classification.
pub fn classify(line: &str) -> Classification {
    let lower = line.to_ascii_lowercase();
    // Python tracebacks
    if line.starts_with("Traceback (most recent call last)") {
        return Classification::Error("python_traceback".into());
    }
    if line.contains("CRITICAL") || line.contains("FATAL") {
        return Classification::Error("critical_log".into());
    }
    // vllm-mlx common panics
    if lower.contains("runtimeerror") || lower.contains("segmentation fault") {
        return Classification::Error("runtime_error".into());
    }
    if lower.contains("out of memory") || lower.contains("oom") {
        return Classification::Error("oom".into());
    }
    // Warnings
    if line.contains("WARNING") || line.contains("warn:") {
        return Classification::Warn("warning_log".into());
    }
    Classification::Ignore
}

/// Convert a classification + source context into a `TelemetryEvent`.
pub fn event_for(
    source: Source,
    component: &str,
    model: Option<&str>,
    line: &str,
    c: Classification,
) -> Option<TelemetryEvent> {
    let (severity, reason) = match c {
        Classification::Ignore => return None,
        Classification::Warn(r) => (Severity::Warn, r),
        Classification::Error(r) => (Severity::Error, r),
    };

    let truncated = truncate(line, 2048);
    let mut ev = TelemetryEvent::new(source, severity, Kind::Log, truncated)
        .with_field("component", component)
        .with_field("reason", reason);
    if let Some(m) = model {
        ev = ev.with_field("model", m);
    }
    Some(ev)
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut out = s[..max].to_string();
    out.push_str("... [truncated]");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_python_traceback() {
        matches!(
            classify("Traceback (most recent call last):"),
            Classification::Error(_)
        );
    }

    #[test]
    fn detects_oom() {
        matches!(classify("CUDA out of memory"), Classification::Error(_));
    }

    #[test]
    fn ignores_noise() {
        matches!(classify("INFO: started"), Classification::Ignore);
    }
}
