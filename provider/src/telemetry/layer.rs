//! `tracing_subscriber::Layer` that forwards WARN+ events to the telemetry
//! pipeline. Keeps the producer path non-blocking: we extract the fields into
//! a `TelemetryEvent` on the caller's thread and hand it to the mpsc channel.

use crate::telemetry::client::TelemetryClient;
use crate::telemetry::event::{Kind, Severity, Source, TelemetryEvent};
use serde_json::{Map, Value};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::Context;
use tracing_subscriber::{Layer, registry::LookupSpan};

/// Layer that mirrors WARN/ERROR tracing events into telemetry.
pub struct TelemetryLayer {
    client: TelemetryClient,
    source: Source,
}

impl TelemetryLayer {
    pub fn new(client: TelemetryClient, source: Source) -> Self {
        Self { client, source }
    }
}

impl<S> Layer<S> for TelemetryLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let meta = event.metadata();
        let level = *meta.level();
        if level > tracing::Level::WARN {
            // tracing::Level::ERROR < WARN < INFO — numerically, ERROR=1, WARN=2.
            // The comparison `level > WARN` is false for ERROR, true for INFO/DEBUG/TRACE.
            return;
        }

        let severity = match level {
            tracing::Level::ERROR => Severity::Error,
            tracing::Level::WARN => Severity::Warn,
            _ => Severity::Info,
        };

        let mut visitor = FieldVisitor::default();
        event.record(&mut visitor);

        let message = visitor
            .fields
            .remove("message")
            .and_then(|v| v.as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| meta.name().to_string());

        // Allowlist fields here too — only attach keys the coordinator accepts.
        // The coordinator enforces this again; belt-and-suspenders.
        let fields = filter_fields(visitor.fields);

        let mut ev = TelemetryEvent::new(self.source, severity, Kind::Log, message);
        ev.fields = fields;
        ev.fields
            .insert("target".into(), Value::String(meta.target().to_string()));
        self.client.emit(ev);
    }
}

#[derive(Default)]
struct FieldVisitor {
    fields: Map<String, Value>,
}

impl tracing::field::Visit for FieldVisitor {
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        self.fields
            .insert(field.name().to_string(), Value::String(value.to_string()));
    }
    fn record_i64(&mut self, field: &tracing::field::Field, value: i64) {
        self.fields
            .insert(field.name().to_string(), Value::Number(value.into()));
    }
    fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
        self.fields
            .insert(field.name().to_string(), Value::Number(value.into()));
    }
    fn record_bool(&mut self, field: &tracing::field::Field, value: bool) {
        self.fields
            .insert(field.name().to_string(), Value::Bool(value));
    }
    fn record_f64(&mut self, field: &tracing::field::Field, value: f64) {
        if let Some(n) = serde_json::Number::from_f64(value) {
            self.fields
                .insert(field.name().to_string(), Value::Number(n));
        }
    }
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        self.fields.insert(
            field.name().to_string(),
            Value::String(format!("{value:?}")),
        );
    }
    fn record_error(
        &mut self,
        _field: &tracing::field::Field,
        value: &(dyn std::error::Error + 'static),
    ) {
        self.fields
            .insert("error".into(), Value::String(format!("{value}")));
    }
}

/// Client-side allowlist. The coordinator enforces its own, but we preempt
/// bandwidth waste. Keys must match the server list in
/// `coordinator/internal/api/telemetry_handlers.go`.
fn filter_fields(input: Map<String, Value>) -> Map<String, Value> {
    const ALLOW: &[&str] = &[
        "component",
        "operation",
        "duration_ms",
        "attempt",
        "endpoint",
        "status_code",
        "error_class",
        "error",
        "model",
        "backend",
        "exit_code",
        "signal",
        "hardware_chip",
        "memory_gb",
        "macos_version",
        "handler",
        "provider_id",
        "trust_level",
        "queue_depth",
        "reason",
        "runtime_component",
        "reconnect_count",
        "last_error",
        "ws_state",
        "billing_method",
        "payment_failed",
        "target",
    ];
    let mut out = Map::new();
    for (k, v) in input {
        if ALLOW.iter().any(|a| *a == k.as_str()) {
            out.insert(k, v);
        }
    }
    out
}
