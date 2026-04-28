//! Async telemetry client. Owns the background batcher task.
//!
//! The client is deliberately cheap to clone: it just holds an `mpsc::Sender`.
//! Call-sites never block on the network; overflow spills to disk.

use crate::telemetry::event::{Source, TelemetryBatch, TelemetryEvent};
use crate::telemetry::queue::DiskQueue;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// Configuration for the telemetry client.
#[derive(Debug, Clone)]
pub struct TelemetryConfig {
    /// Coordinator base URL. HTTP(S) bases are used as-is; provider WebSocket
    /// URLs are normalized to the coordinator's HTTPS ingest base.
    pub coordinator_url: String,
    /// Device-linked auth token for `Authorization: Bearer ...`. Optional —
    /// when absent, the client sends events anonymously and accepts stricter
    /// server-side rate limits.
    pub auth_token: Option<String>,
    /// This component's version (e.g. "0.3.10"), stamped on every event.
    pub version: String,
    /// Stable per-machine identifier (usually the provider's SE public key).
    pub machine_id: String,
    /// Account the machine is linked to, if any.
    pub account_id: Option<String>,
    /// Source tag for all events coming through this client.
    pub source: Source,
    /// Path to the disk overflow queue.
    pub disk_queue_path: PathBuf,
    /// Max number of events per HTTP batch. The coordinator accepts up to 100.
    pub max_batch: usize,
    /// How often to flush a partially-filled batch.
    pub flush_interval: Duration,
    /// Max events held in the in-memory queue before events are spilled to disk.
    pub mem_queue_cap: usize,
}

impl TelemetryConfig {
    /// Build a config with sensible defaults.
    pub fn new(coordinator_url: impl Into<String>, source: Source) -> Self {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
        Self {
            coordinator_url: coordinator_url.into(),
            auth_token: None,
            version: env!("CARGO_PKG_VERSION").into(),
            machine_id: String::new(),
            account_id: None,
            source,
            disk_queue_path: home.join(".darkbloom/telemetry-queue.jsonl"),
            max_batch: 50,
            flush_interval: Duration::from_secs(5),
            mem_queue_cap: 1000,
        }
    }
}

/// Cheap-to-clone handle to the telemetry pipeline.
#[derive(Clone)]
pub struct TelemetryClient {
    tx: mpsc::Sender<TelemetryEvent>,
    cfg: Arc<TelemetryConfig>,
}

impl TelemetryClient {
    /// Spawn the background batcher and return a client handle.
    pub fn spawn(cfg: TelemetryConfig) -> Self {
        let (tx, rx) = mpsc::channel::<TelemetryEvent>(cfg.mem_queue_cap);
        let cfg = Arc::new(cfg);

        let worker_cfg = cfg.clone();
        let worker_handle = tokio::runtime::Handle::try_current();
        match worker_handle {
            Ok(h) => {
                h.spawn(run_worker(rx, worker_cfg));
            }
            Err(_) => {
                // No tokio runtime yet — spawn one for telemetry alone.
                std::thread::spawn(move || {
                    let rt = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .expect("telemetry: failed to build fallback runtime");
                    rt.block_on(run_worker(rx, worker_cfg));
                });
            }
        }

        Self { tx, cfg }
    }

    /// Non-blocking emit. Drops the event if the in-memory queue is full —
    /// the disk spill handles persistent backpressure; we must never block
    /// a producer (tracing layers, panic hooks) on the network.
    pub fn emit(&self, mut event: TelemetryEvent) {
        self.stamp(&mut event);
        match self.tx.try_send(event) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(ev)) => {
                // Fall back to a synchronous disk write — losing events is worse
                // than a ~ms of I/O at the call site.
                if let Ok(mut q) = DiskQueue::open(&self.cfg.disk_queue_path) {
                    let _ = q.push(&ev);
                }
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                // Worker gone; silently drop.
            }
        }
    }

    /// Blocking emit for use from panic hooks. Writes directly to the disk
    /// queue if the async channel is unavailable.
    pub fn emit_blocking(&self, mut event: TelemetryEvent) {
        self.stamp(&mut event);
        if self.tx.try_send(event.clone()).is_ok() {
            return;
        }
        if let Ok(mut q) = DiskQueue::open(&self.cfg.disk_queue_path) {
            let _ = q.push(&event);
        }
    }

    /// Stamp server-relevant defaults (version, machine_id, source, account)
    /// that individual call sites don't bother setting.
    fn stamp(&self, ev: &mut TelemetryEvent) {
        if ev.version.is_empty() {
            ev.version = self.cfg.version.clone();
        }
        if ev.machine_id.is_empty() {
            ev.machine_id = self.cfg.machine_id.clone();
        }
        if ev.account_id.is_empty() {
            if let Some(a) = self.cfg.account_id.as_deref() {
                ev.account_id = a.to_string();
            }
        }
        // Source is always the client's configured source — trust the transport,
        // not the call site.
        ev.source = self.cfg.source;
    }

    /// Access the config (for tests and introspection).
    pub fn config(&self) -> &TelemetryConfig {
        &self.cfg
    }
}

/// Background task: batches events, flushes via HTTP, spills on failure.
async fn run_worker(mut rx: mpsc::Receiver<TelemetryEvent>, cfg: Arc<TelemetryConfig>) {
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .expect("telemetry: failed to build HTTP client");

    let endpoint = telemetry_ingest_endpoint(&cfg.coordinator_url);

    let mut buffer: Vec<TelemetryEvent> = Vec::with_capacity(cfg.max_batch);
    let mut ticker = tokio::time::interval(cfg.flush_interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            maybe = rx.recv() => {
                match maybe {
                    Some(ev) => {
                        buffer.push(ev);
                        if buffer.len() >= cfg.max_batch {
                            flush(&http, &endpoint, &cfg, &mut buffer).await;
                        }
                    }
                    None => {
                        // Channel closed — final flush and exit.
                        flush(&http, &endpoint, &cfg, &mut buffer).await;
                        break;
                    }
                }
            }
            _ = ticker.tick() => {
                if !buffer.is_empty() {
                    flush(&http, &endpoint, &cfg, &mut buffer).await;
                } else {
                    // Opportunistically drain the disk queue when we have nothing
                    // to send from memory.
                    drain_disk(&http, &endpoint, &cfg).await;
                }
            }
        }
    }
}

async fn flush(
    http: &reqwest::Client,
    endpoint: &str,
    cfg: &TelemetryConfig,
    buffer: &mut Vec<TelemetryEvent>,
) {
    if buffer.is_empty() {
        return;
    }
    let batch = TelemetryBatch {
        events: std::mem::take(buffer),
    };
    if send_batch(http, endpoint, cfg, &batch).await.is_err() {
        // Persist for later.
        if let Ok(mut q) = DiskQueue::open(&cfg.disk_queue_path) {
            for ev in &batch.events {
                let _ = q.push(ev);
            }
        }
    }
}

async fn send_batch(
    http: &reqwest::Client,
    endpoint: &str,
    cfg: &TelemetryConfig,
    batch: &TelemetryBatch,
) -> anyhow::Result<()> {
    let mut req = http.post(endpoint).json(batch);
    if let Some(tok) = cfg.auth_token.as_deref() {
        req = req.bearer_auth(tok);
    }
    let resp = req.send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("telemetry ingest failed: {}", resp.status());
    }
    Ok(())
}

async fn drain_disk(http: &reqwest::Client, endpoint: &str, cfg: &TelemetryConfig) {
    let Ok(mut q) = DiskQueue::open(&cfg.disk_queue_path) else {
        return;
    };
    let events = q.drain(cfg.max_batch);
    if events.is_empty() {
        return;
    }
    let batch = TelemetryBatch { events };
    if let Err(e) = send_batch(http, endpoint, cfg, &batch).await {
        // Put them back; queue caps size on its own.
        tracing::debug!("telemetry disk drain failed, re-queuing: {e}");
        for ev in batch.events {
            let _ = q.push(&ev);
        }
    }
}

fn telemetry_ingest_endpoint(coordinator_url: &str) -> String {
    let base = coordinator_url.trim_end_matches('/');
    let base = if let Some(rest) = base.strip_prefix("wss://") {
        format!("https://{rest}")
    } else if let Some(rest) = base.strip_prefix("ws://") {
        format!("http://{rest}")
    } else {
        base.to_string()
    };
    let base = base
        .strip_suffix("/ws/provider")
        .unwrap_or(&base)
        .trim_end_matches('/');
    format!("{base}/v1/telemetry/events")
}

#[cfg(test)]
mod tests {
    use super::telemetry_ingest_endpoint;

    #[test]
    fn telemetry_endpoint_uses_https_base_for_provider_wss_url() {
        assert_eq!(
            telemetry_ingest_endpoint("wss://api.darkbloom.dev/ws/provider"),
            "https://api.darkbloom.dev/v1/telemetry/events"
        );
    }

    #[test]
    fn telemetry_endpoint_preserves_http_base_urls() {
        assert_eq!(
            telemetry_ingest_endpoint("http://localhost:8080"),
            "http://localhost:8080/v1/telemetry/events"
        );
        assert_eq!(
            telemetry_ingest_endpoint("https://api.darkbloom.dev/"),
            "https://api.darkbloom.dev/v1/telemetry/events"
        );
    }
}
