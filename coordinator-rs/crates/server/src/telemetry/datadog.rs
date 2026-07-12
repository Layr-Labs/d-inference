//! Bounded, best-effort Datadog Agent bridge.
//!
//! Request paths only perform `try_send` into a finite mailbox. A single
//! worker owns DogStatsD UDP I/O, while `tracing-opentelemetry` exports spans
//! through the Agent's local APM listener. Tag keys are an enum so callers
//! cannot accidentally attach account, request, key, prompt, or provider IDs.

use std::{
    cmp::Ordering as CmpOrdering,
    fmt::Write as _,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::{
        Arc, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use opentelemetry::{KeyValue, trace::TracerProvider as _};
use opentelemetry_datadog::{ApiVersion, DatadogPropagator};
use opentelemetry_sdk::{
    Resource,
    trace::{Config as TraceConfig, SdkTracerProvider},
};
use serde::Serialize;
use thiserror::Error;
use tokio::{
    net::{UdpSocket, lookup_host},
    task::JoinHandle,
};
use tokio_util::sync::CancellationToken;
use tracing_subscriber::{EnvFilter, layer::SubscriberExt as _, util::SubscriberInitExt as _};

use super::{
    BoundedTelemetryReceiver, BoundedTelemetrySender, TelemetryConfigError, TelemetryEmit,
    bounded_telemetry,
};

mod config;
mod tags;

pub use config::DatadogConfigError;
pub use tags::{Tag, TagKey};

use config::{DatadogConfig, UnifiedTags};

const MAX_TAGS: usize = 8;
const MAX_DATAGRAM_BYTES: usize = 1_432;

static GLOBAL: OnceLock<DatadogEmitter> = OnceLock::new();

/// Every custom Rust coordinator metric accepted by the bridge.
///
/// Keep this list synchronized with
/// `deploy/datadog/rust-metrics-allowlist.json`; the smoke validator enforces
/// dashboard and monitor references against that catalog.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Metric {
    HttpRequests,
    HttpStageDurationMs,
    HttpStageBudgetExceeded,
    AuthAttempts,
    FleetAdmission,
    ProviderSessions,
    ProviderVersion,
    ProviderTrust,
    WriterQueueItems,
    WriterQueueBytes,
    WriterDelivery,
    WriterTimeout,
    BytePipeOverflow,
    JobsState,
    JobsAgeSeconds,
    LedgerTransition,
    AmbiguousCommit,
    RecoveryAction,
    ExternalUnknown,
    OutboxState,
    FeeState,
    OwnershipHealthy,
    OwnershipEpoch,
    SchemaVersion,
    SchemaChecksumValid,
    DrainState,
    Quiescent,
    RollbackGuard,
}

impl Metric {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::HttpRequests => "d_inference.rust.http.requests",
            Self::HttpStageDurationMs => "d_inference.rust.http.stage.duration_ms",
            Self::HttpStageBudgetExceeded => "d_inference.rust.http.stage.budget_exceeded",
            Self::AuthAttempts => "d_inference.rust.auth.attempts",
            Self::FleetAdmission => "d_inference.rust.fleet.admission",
            Self::ProviderSessions => "d_inference.rust.provider.sessions",
            Self::ProviderVersion => "d_inference.rust.provider.version",
            Self::ProviderTrust => "d_inference.rust.provider.trust",
            Self::WriterQueueItems => "d_inference.rust.writer.queue.items",
            Self::WriterQueueBytes => "d_inference.rust.writer.queue.bytes",
            Self::WriterDelivery => "d_inference.rust.writer.delivery",
            Self::WriterTimeout => "d_inference.rust.writer.timeout",
            Self::BytePipeOverflow => "d_inference.rust.byte_pipe.overflow",
            Self::JobsState => "d_inference.rust.jobs.state",
            Self::JobsAgeSeconds => "d_inference.rust.jobs.age_seconds",
            Self::LedgerTransition => "d_inference.rust.ledger.transition",
            Self::AmbiguousCommit => "d_inference.rust.ledger.ambiguous_commit",
            Self::RecoveryAction => "d_inference.rust.recovery.action",
            Self::ExternalUnknown => "d_inference.rust.billing.external_unknown",
            Self::OutboxState => "d_inference.rust.outbox.state",
            Self::FeeState => "d_inference.rust.fee.state",
            Self::OwnershipHealthy => "d_inference.rust.ownership.healthy",
            Self::OwnershipEpoch => "d_inference.rust.ownership.epoch",
            Self::SchemaVersion => "d_inference.rust.schema.version",
            Self::SchemaChecksumValid => "d_inference.rust.schema.checksum_valid",
            Self::DrainState => "d_inference.rust.drain.state",
            Self::Quiescent => "d_inference.rust.quiescent",
            Self::RollbackGuard => "d_inference.rust.rollback_guard",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MetricKind {
    Counter,
    Gauge,
    Histogram,
}

#[derive(Clone, Debug)]
struct MetricEvent {
    metric: Metric,
    kind: MetricKind,
    value: f64,
    tags: Vec<Tag>,
}

impl MetricEvent {
    fn new(metric: Metric, kind: MetricKind, value: f64, tags: &[Tag]) -> Self {
        Self {
            metric,
            kind,
            value,
            tags: tags.iter().take(MAX_TAGS).cloned().collect(),
        }
    }
}

/// Agent bridge counters exposed through `/v1/admin/metrics`.
#[derive(Clone, Copy, Debug, Default, Serialize)]
pub struct DatadogBridgeSnapshot {
    pub enabled: bool,
    pub accepted: u64,
    pub dropped_full: u64,
    pub dropped_closed: u64,
    pub dropped_transport: u64,
    pub send_failures: u64,
    pub remaining_capacity: usize,
}

#[derive(Debug, Default)]
struct EmitterCounters {
    accepted: AtomicU64,
    dropped_full: AtomicU64,
    dropped_closed: AtomicU64,
    dropped_transport: AtomicU64,
    send_failures: AtomicU64,
}

/// Cloneable request-path handle for finite, immediate metric publication.
#[derive(Clone, Debug)]
pub struct DatadogEmitter {
    sender: BoundedTelemetrySender<MetricEvent>,
    counters: Arc<EmitterCounters>,
    enabled: bool,
}

impl DatadogEmitter {
    fn new(
        capacity: usize,
        enabled: bool,
    ) -> Result<(Self, BoundedTelemetryReceiver<MetricEvent>), TelemetryConfigError> {
        let (sender, receiver) = bounded_telemetry(capacity)?;
        Ok((
            Self {
                sender,
                counters: Arc::new(EmitterCounters::default()),
                enabled,
            },
            receiver,
        ))
    }

    fn try_emit(&self, event: MetricEvent) -> TelemetryEmit {
        match self.sender.try_emit(event) {
            TelemetryEmit::Accepted => {
                self.counters.accepted.fetch_add(1, Ordering::Relaxed);
                TelemetryEmit::Accepted
            }
            TelemetryEmit::DroppedFull => {
                self.counters.dropped_full.fetch_add(1, Ordering::Relaxed);
                TelemetryEmit::DroppedFull
            }
            TelemetryEmit::DroppedClosed => {
                self.counters.dropped_closed.fetch_add(1, Ordering::Relaxed);
                TelemetryEmit::DroppedClosed
            }
        }
    }

    #[must_use]
    pub fn snapshot(&self) -> DatadogBridgeSnapshot {
        DatadogBridgeSnapshot {
            enabled: self.enabled,
            accepted: self.counters.accepted.load(Ordering::Relaxed),
            dropped_full: self.counters.dropped_full.load(Ordering::Relaxed),
            dropped_closed: self.counters.dropped_closed.load(Ordering::Relaxed),
            dropped_transport: self.counters.dropped_transport.load(Ordering::Relaxed),
            send_failures: self.counters.send_failures.load(Ordering::Relaxed),
            remaining_capacity: self.sender.remaining_capacity(),
        }
    }
}

/// Process-lifetime telemetry resources.
pub struct Observability {
    cancellation: CancellationToken,
    metrics_worker: JoinHandle<()>,
    tracer_provider: Option<SdkTracerProvider>,
}

impl Observability {
    /// Installs JSON tracing, optional APM export, and the DogStatsD worker.
    pub fn install() -> Result<Self, DatadogInitError> {
        let config = DatadogConfig::from_env()?;
        let tracer_provider = install_tracing(&config)?;
        let (emitter, receiver) = DatadogEmitter::new(config.capacity, config.metrics_enabled)?;
        GLOBAL
            .set(emitter.clone())
            .map_err(|_| DatadogInitError::AlreadyInstalled)?;
        let cancellation = CancellationToken::new();
        let metrics_worker = tokio::spawn(run_metrics_worker(
            receiver,
            emitter.counters.clone(),
            config.clone(),
            cancellation.clone(),
        ));
        tracing::info!(
            dd_service = %config.tags.service,
            dd_env = %config.tags.environment,
            dd_version = %config.tags.version,
            git_commit = %config.tags.commit,
            dogstatsd_enabled = config.metrics_enabled,
            apm_enabled = config.traces_enabled,
            telemetry_capacity = config.capacity,
            "Rust coordinator structured observability initialized"
        );
        Ok(Self {
            cancellation,
            metrics_worker,
            tracer_provider,
        })
    }

    /// Stops accepting worker work and performs a bounded APM flush.
    pub async fn shutdown(self, grace: Duration) {
        self.cancellation.cancel();
        let _ = tokio::time::timeout(grace, self.metrics_worker).await;
        if let Some(provider) = self.tracer_provider
            && let Err(error) = provider.shutdown()
        {
            eprintln!("Datadog APM shutdown failed: {error}");
        }
    }
}

/// Emits a monotonic counter delta without blocking.
pub fn counter(metric: Metric, value: u64, tags: &[Tag]) {
    emit(MetricEvent::new(
        metric,
        MetricKind::Counter,
        value as f64,
        tags,
    ));
}

/// Emits a latest-value gauge without blocking.
pub fn gauge(metric: Metric, value: f64, tags: &[Tag]) {
    emit(MetricEvent::new(metric, MetricKind::Gauge, value, tags));
}

/// Emits a DogStatsD histogram sample without blocking.
pub fn histogram(metric: Metric, value: f64, tags: &[Tag]) {
    emit(MetricEvent::new(metric, MetricKind::Histogram, value, tags));
}

/// Current process bridge accounting, including intentional overload drops.
#[must_use]
pub fn snapshot() -> DatadogBridgeSnapshot {
    GLOBAL
        .get()
        .map_or_else(DatadogBridgeSnapshot::default, DatadogEmitter::snapshot)
}

fn emit(event: MetricEvent) {
    if let Some(emitter) = GLOBAL.get() {
        let _ = emitter.try_emit(event);
    }
}

fn install_tracing(config: &DatadogConfig) -> Result<Option<SdkTracerProvider>, DatadogInitError> {
    opentelemetry::global::set_text_map_propagator(DatadogPropagator::new());
    let mut trace_config = TraceConfig::default();
    trace_config.resource = std::borrow::Cow::Owned(
        Resource::builder()
            .with_attribute(KeyValue::new(
                "git.commit.sha",
                config.tags.commit.to_string(),
            ))
            .build(),
    );
    let tracer_provider = config
        .traces_enabled
        .then(|| {
            opentelemetry_datadog::new_pipeline()
                .with_service_name(config.tags.service.to_string())
                .with_env(config.tags.environment.to_string())
                .with_version(config.tags.version.to_string())
                .with_agent_endpoint(format!(
                    "http://{}:{}",
                    config.agent_host, config.trace_port
                ))
                .with_api_version(ApiVersion::Version05)
                .with_trace_config(trace_config)
                .install_batch()
        })
        .transpose()?;
    let telemetry_layer = tracer_provider.as_ref().map(|provider| {
        let tracer = provider.tracer("darkbloom-coordinator-server");
        tracing_opentelemetry::layer().with_tracer(tracer)
    });
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_target(true)
                .flatten_event(true),
        )
        .with(telemetry_layer)
        .try_init()?;
    Ok(tracer_provider)
}

async fn run_metrics_worker(
    mut receiver: BoundedTelemetryReceiver<MetricEvent>,
    counters: Arc<EmitterCounters>,
    config: DatadogConfig,
    cancellation: CancellationToken,
) {
    let mut socket = None;
    loop {
        let event = tokio::select! {
            biased;
            () = cancellation.cancelled() => break,
            event = receiver.recv() => event,
        };
        let Some(event) = event else {
            break;
        };
        if !config.metrics_enabled {
            continue;
        }
        let packet = render_event(&event, &config.tags);
        if packet.len() > MAX_DATAGRAM_BYTES {
            counters.send_failures.fetch_add(1, Ordering::Relaxed);
            counters.dropped_transport.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        if !send_packet(&mut socket, &config, packet.as_bytes(), &counters).await {
            counters.dropped_transport.fetch_add(1, Ordering::Relaxed);
        }
    }
}

async fn send_packet(
    socket: &mut Option<UdpSocket>,
    config: &DatadogConfig,
    packet: &[u8],
    counters: &EmitterCounters,
) -> bool {
    for _ in 0..2 {
        if socket.is_none() {
            match connected_socket(&config.agent_host, config.dogstatsd_port).await {
                Ok(connected) => *socket = Some(connected),
                Err(_) => {
                    counters.send_failures.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
            }
        }
        let result = socket
            .as_ref()
            .expect("socket was connected")
            .send(packet)
            .await;
        match result {
            Ok(sent) if sent == packet.len() => return true,
            Ok(sent) => {
                counters.send_failures.fetch_add(1, Ordering::Relaxed);
                debug_assert_ne!(sent, packet.len());
            }
            Err(_) => {
                counters.send_failures.fetch_add(1, Ordering::Relaxed);
            }
        }
        *socket = None;
    }
    false
}

async fn connected_socket(host: &str, port: u16) -> std::io::Result<UdpSocket> {
    let candidates = lookup_host((host, port)).await?.collect::<Vec<_>>();
    connected_socket_to(candidates).await
}

async fn connected_socket_to(mut candidates: Vec<SocketAddr>) -> std::io::Result<UdpSocket> {
    candidates.sort_by(|left, right| match (left.is_ipv4(), right.is_ipv4()) {
        (true, false) => CmpOrdering::Less,
        (false, true) => CmpOrdering::Greater,
        _ => CmpOrdering::Equal,
    });
    candidates.dedup();
    if candidates.is_empty() {
        return Err(std::io::Error::other("DogStatsD host did not resolve"));
    }
    let mut last_error = None;
    for remote in candidates {
        let bind = match remote {
            SocketAddr::V4(_) => SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0),
            SocketAddr::V6(_) => SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0),
        };
        let socket = match UdpSocket::bind(bind).await {
            Ok(socket) => socket,
            Err(error) => {
                last_error = Some(error);
                continue;
            }
        };
        match socket.connect(remote).await {
            Ok(()) => return Ok(socket),
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error
        .unwrap_or_else(|| std::io::Error::other("DogStatsD had no connectable resolved address")))
}

fn render_event(event: &MetricEvent, unified: &UnifiedTags) -> String {
    let kind = match event.kind {
        MetricKind::Counter => "c",
        MetricKind::Gauge => "g",
        MetricKind::Histogram => "h",
    };
    let mut output = String::with_capacity(256);
    let _ = write!(output, "{}:{}|{}", event.metric.as_str(), event.value, kind);
    let _ = write!(
        output,
        "|#service:{},env:{},version:{},git_commit:{}",
        unified.service, unified.environment, unified.version, unified.commit
    );
    for tag in &event.tags {
        let _ = write!(output, ",{}:{}", tag.key.as_str(), tag.value);
    }
    output
}

#[derive(Debug, Error)]
pub enum DatadogInitError {
    #[error(transparent)]
    Config(#[from] DatadogConfigError),
    #[error(transparent)]
    Lane(#[from] TelemetryConfigError),
    #[error("Datadog observability was installed more than once")]
    AlreadyInstalled,
    #[error("build Datadog APM exporter: {0}")]
    Exporter(#[from] opentelemetry_datadog::Error),
    #[error("install tracing subscriber: {0}")]
    Subscriber(#[from] tracing_subscriber::util::TryInitError),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(host: &str, port: u16) -> DatadogConfig {
        DatadogConfig {
            agent_host: Arc::from(host),
            dogstatsd_port: port,
            trace_port: 8_126,
            metrics_enabled: true,
            traces_enabled: false,
            capacity: 8,
            tags: UnifiedTags {
                service: Arc::from("test-service"),
                environment: Arc::from("test"),
                version: Arc::from("test"),
                commit: Arc::from("test"),
            },
        }
    }

    fn event() -> MetricEvent {
        MetricEvent::new(
            Metric::AuthAttempts,
            MetricKind::Counter,
            1.0,
            &[Tag::new(TagKey::Outcome, "success")],
        )
    }

    #[test]
    fn emitter_full_and_closed_drops_are_bounded_and_distinct() {
        let (emitter, receiver) = DatadogEmitter::new(1, true).expect("emitter");
        assert_eq!(emitter.try_emit(event()), TelemetryEmit::Accepted);
        assert_eq!(emitter.try_emit(event()), TelemetryEmit::DroppedFull);
        let snapshot = emitter.snapshot();
        assert_eq!(snapshot.accepted, 1);
        assert_eq!(snapshot.dropped_full, 1);
        assert_eq!(snapshot.dropped_closed, 0);
        assert_eq!(snapshot.remaining_capacity, 0);

        drop(receiver);
        assert_eq!(emitter.try_emit(event()), TelemetryEmit::DroppedClosed);
        let snapshot = emitter.snapshot();
        assert_eq!(snapshot.dropped_full, 1);
        assert_eq!(snapshot.dropped_closed, 1);
    }

    #[tokio::test]
    async fn ipv4_is_preferred_when_resolution_returns_ipv6_first() {
        let listener = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("IPv4 listener");
        let ipv4 = listener.local_addr().expect("IPv4 listener address");
        let ipv6 = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), ipv4.port());
        let socket = connected_socket_to(vec![ipv6, ipv4])
            .await
            .expect("connect preferred IPv4");

        assert!(socket.peer_addr().expect("peer address").is_ipv4());
        socket.send(b"probe").await.expect("send probe");
        let mut buffer = [0_u8; 16];
        let (size, _) = listener
            .recv_from(&mut buffer)
            .await
            .expect("receive probe");
        assert_eq!(&buffer[..size], b"probe");
    }

    #[tokio::test]
    async fn send_error_reconnects_after_ipv4_agent_restart() {
        let listener = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .expect("initial Agent listener");
        let address = listener.local_addr().expect("Agent address");
        let config = config("127.0.0.1", address.port());
        let counters = EmitterCounters::default();
        let mut socket = None;

        assert!(send_packet(&mut socket, &config, b"before", &counters).await);
        let mut buffer = [0_u8; 32];
        let (size, _) = listener
            .recv_from(&mut buffer)
            .await
            .expect("initial packet");
        assert_eq!(&buffer[..size], b"before");
        drop(listener);

        for _ in 0..20 {
            let _ = send_packet(&mut socket, &config, b"during", &counters).await;
            if counters.send_failures.load(Ordering::Relaxed) > 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(
            counters.send_failures.load(Ordering::Relaxed) > 0,
            "connected UDP send must surface the unavailable Agent"
        );

        let restarted = UdpSocket::bind(address)
            .await
            .expect("restarted Agent listener");
        let received = tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let _ = send_packet(&mut socket, &config, b"after", &counters).await;
                let mut buffer = [0_u8; 32];
                if let Ok(Ok((size, _))) = tokio::time::timeout(
                    Duration::from_millis(50),
                    restarted.recv_from(&mut buffer),
                )
                .await
                {
                    break buffer[..size].to_vec();
                }
            }
        })
        .await
        .expect("packet after Agent restart");
        assert_eq!(received, b"after");
    }

    #[tokio::test]
    async fn worker_records_locally_dropped_transport_errors() {
        let (emitter, receiver) = DatadogEmitter::new(2, true).expect("emitter");
        let cancellation = CancellationToken::new();
        let worker = tokio::spawn(run_metrics_worker(
            receiver,
            emitter.counters.clone(),
            config("not a valid host", 8_125),
            cancellation.clone(),
        ));
        assert_eq!(emitter.try_emit(event()), TelemetryEmit::Accepted);

        tokio::time::timeout(Duration::from_secs(1), async {
            while emitter.snapshot().dropped_transport == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("transport drop");
        let snapshot = emitter.snapshot();
        assert_eq!(snapshot.dropped_transport, 1);
        assert!(snapshot.send_failures >= 1);

        cancellation.cancel();
        worker.await.expect("worker stopped");
    }
}
