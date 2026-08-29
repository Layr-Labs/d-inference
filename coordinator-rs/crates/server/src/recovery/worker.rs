//! The shared worker loop: jittered interval, bounded work per tick,
//! depth metrics via tracing, clean cancellation (plan §18.1, §15.1).

use std::future::Future;

use rand::Rng;
use tokio_util::sync::CancellationToken;

use super::RecoveryConfig;

/// Runs `tick` on a jittered interval until `cancel` fires. A failing tick
/// is logged and retried on the next interval — recovery work is idempotent
/// by construction, so a crash-and-retry loop is safe.
pub async fn run_worker<F, Fut>(
    name: &'static str,
    config: &RecoveryConfig,
    cancel: CancellationToken,
    mut tick: F,
) where
    F: FnMut() -> Fut,
    Fut: Future<Output = anyhow::Result<usize>>,
{
    tracing::info!(
        worker = name,
        interval_ms = config.interval.as_millis() as u64,
        "recovery worker started"
    );
    loop {
        let jitter_ms = if config.jitter.is_zero() {
            0
        } else {
            rand::thread_rng().gen_range(0..=config.jitter.as_millis() as u64)
        };
        let sleep = config.interval + std::time::Duration::from_millis(jitter_ms);
        tokio::select! {
            () = cancel.cancelled() => {
                tracing::info!(worker = name, "recovery worker stopping");
                return;
            }
            () = tokio::time::sleep(sleep) => {}
        }
        match tick().await {
            Ok(0) => {}
            Ok(processed) => {
                tracing::info!(worker = name, processed, "recovery tick");
            }
            Err(err) => {
                tracing::warn!(worker = name, error = %err, "recovery tick failed; will retry");
            }
        }
    }
}

/// Emits the standard depth/oldest-age gauge for one worker's scan set
/// (plan §14: every limit emits depth and oldest-item age).
pub(super) fn report_depth(worker: &'static str, depth: i64, oldest_age_secs: Option<f64>) {
    if depth > 0 {
        tracing::info!(
            worker,
            depth,
            oldest_age_secs = oldest_age_secs.unwrap_or(0.0),
            "recovery backlog"
        );
    } else {
        tracing::debug!(worker, depth = 0i64, "recovery backlog empty");
    }
}
