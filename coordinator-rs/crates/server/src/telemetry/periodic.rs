use std::{future::Future, time::Duration};

use tokio::time::MissedTickBehavior;
use tokio_util::sync::CancellationToken;

pub const MAX_GAUGE_INTERVAL: Duration = Duration::from_secs(15);

/// Runs an immediate and then periodic publication until cancellation.
///
/// The fixed upper bound prevents healthy processes from becoming silent
/// longer than the monitor no-data window expects.
pub async fn run<F, Fut>(interval: Duration, cancellation: CancellationToken, mut publish: F)
where
    F: FnMut() -> Fut,
    Fut: Future<Output = ()>,
{
    assert!(
        !interval.is_zero() && interval <= MAX_GAUGE_INTERVAL,
        "periodic gauge interval must be in 1ns..=15s"
    );
    let mut ticker = tokio::time::interval(interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => return,
            _ = ticker.tick() => publish().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    use tokio::sync::Notify;

    use super::*;

    #[tokio::test]
    async fn publishes_multiple_intervals_and_stops_on_cancellation() {
        let cancellation = CancellationToken::new();
        let publications = Arc::new(AtomicUsize::new(0));
        let published = Arc::new(Notify::new());
        let task = tokio::spawn({
            let cancellation = cancellation.clone();
            let publications = publications.clone();
            let published = published.clone();
            async move {
                run(Duration::from_millis(5), cancellation, move || {
                    let publications = publications.clone();
                    let published = published.clone();
                    async move {
                        publications.fetch_add(1, Ordering::SeqCst);
                        published.notify_waiters();
                    }
                })
                .await;
            }
        });

        tokio::time::timeout(Duration::from_secs(1), async {
            while publications.load(Ordering::SeqCst) < 3 {
                published.notified().await;
            }
        })
        .await
        .expect("at least three gauge publications");

        cancellation.cancel();
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .expect("publisher stopped after cancellation")
            .expect("publisher task");
        let final_count = publications.load(Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(publications.load(Ordering::SeqCst), final_count);
    }

    #[tokio::test]
    #[should_panic(expected = "periodic gauge interval must be in 1ns..=15s")]
    async fn rejects_intervals_above_monitor_freshness_bound() {
        run(
            MAX_GAUGE_INTERVAL + Duration::from_nanos(1),
            CancellationToken::new(),
            || async {},
        )
        .await;
    }
}
