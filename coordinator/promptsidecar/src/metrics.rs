use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

const LATENCY_BOUNDS_US: [u64; 15] = [
    100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000,
    1_000_000, 2_500_000, 5_000_000,
];

pub struct Metrics {
    plans_started: AtomicU64,
    plans_succeeded: AtomicU64,
    plans_cold_only: AtomicU64,
    plans_failed: AtomicU64,
    plans_at_capacity: AtomicU64,
    plans_not_ready: AtomicU64,
    plan_timeouts: AtomicU64,
    cold_loads: AtomicU64,
    warm_loads: AtomicU64,
    load_waits: AtomicU64,
    load_failures: AtomicU64,
    preload_runs: AtomicU64,
    preload_failures: AtomicU64,
    preload_contracts: AtomicU64,
    plan_latency: LatencyHistogram,
    cold_load_latency: LatencyHistogram,
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            plans_started: AtomicU64::new(0),
            plans_succeeded: AtomicU64::new(0),
            plans_cold_only: AtomicU64::new(0),
            plans_failed: AtomicU64::new(0),
            plans_at_capacity: AtomicU64::new(0),
            plans_not_ready: AtomicU64::new(0),
            plan_timeouts: AtomicU64::new(0),
            cold_loads: AtomicU64::new(0),
            warm_loads: AtomicU64::new(0),
            load_waits: AtomicU64::new(0),
            load_failures: AtomicU64::new(0),
            preload_runs: AtomicU64::new(0),
            preload_failures: AtomicU64::new(0),
            preload_contracts: AtomicU64::new(0),
            plan_latency: LatencyHistogram::default(),
            cold_load_latency: LatencyHistogram::default(),
        }
    }
}

impl Metrics {
    pub fn plan_started(&self) {
        self.plans_started.fetch_add(1, Ordering::Relaxed);
    }

    pub fn plan_finished(&self, elapsed: Duration, succeeded: bool) {
        if succeeded {
            self.plans_succeeded.fetch_add(1, Ordering::Relaxed);
        } else {
            self.plans_failed.fetch_add(1, Ordering::Relaxed);
        }
        self.plan_latency.record(elapsed);
    }

    pub fn plan_cold_only(&self, elapsed: Duration) {
        self.plans_cold_only.fetch_add(1, Ordering::Relaxed);
        self.plan_latency.record(elapsed);
    }

    pub fn plan_at_capacity(&self, elapsed: Duration) {
        self.plans_at_capacity.fetch_add(1, Ordering::Relaxed);
        self.plan_latency.record(elapsed);
    }

    pub fn plan_not_ready(&self, elapsed: Duration) {
        self.plans_not_ready.fetch_add(1, Ordering::Relaxed);
        self.plan_latency.record(elapsed);
    }

    pub fn plan_timed_out(&self, elapsed: Duration) {
        self.plan_timeouts.fetch_add(1, Ordering::Relaxed);
        self.plan_latency.record(elapsed);
    }

    pub fn cold_load_finished(&self, elapsed: Duration, succeeded: bool) {
        self.cold_loads.fetch_add(1, Ordering::Relaxed);
        if !succeeded {
            self.load_failures.fetch_add(1, Ordering::Relaxed);
        }
        self.cold_load_latency.record(elapsed);
    }

    pub fn warm_load(&self) {
        self.warm_loads.fetch_add(1, Ordering::Relaxed);
    }

    pub fn load_wait(&self) {
        self.load_waits.fetch_add(1, Ordering::Relaxed);
    }

    pub fn preload_started(&self, contracts: usize) {
        self.preload_runs.fetch_add(1, Ordering::Relaxed);
        saturating_add(&self.preload_contracts, contracts as u64);
    }

    pub fn preload_finished(&self, succeeded: bool) {
        if !succeeded {
            self.preload_failures.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            plans: PlanCounters {
                started: self.plans_started.load(Ordering::Relaxed),
                succeeded: self.plans_succeeded.load(Ordering::Relaxed),
                cold_only: self.plans_cold_only.load(Ordering::Relaxed),
                failed: self.plans_failed.load(Ordering::Relaxed),
                at_capacity: self.plans_at_capacity.load(Ordering::Relaxed),
                not_ready: self.plans_not_ready.load(Ordering::Relaxed),
                timed_out: self.plan_timeouts.load(Ordering::Relaxed),
                latency_us: self.plan_latency.snapshot(),
            },
            contract_loads: ContractLoadCounters {
                cold: self.cold_loads.load(Ordering::Relaxed),
                warm: self.warm_loads.load(Ordering::Relaxed),
                waited: self.load_waits.load(Ordering::Relaxed),
                failed: self.load_failures.load(Ordering::Relaxed),
                cold_latency_us: self.cold_load_latency.snapshot(),
            },
            preloads: PreloadCounters {
                runs: self.preload_runs.load(Ordering::Relaxed),
                failed: self.preload_failures.load(Ordering::Relaxed),
                contracts: self.preload_contracts.load(Ordering::Relaxed),
            },
        }
    }
}

#[derive(Debug, Serialize)]
pub struct MetricsSnapshot {
    pub plans: PlanCounters,
    pub contract_loads: ContractLoadCounters,
    pub preloads: PreloadCounters,
}

#[derive(Debug, Serialize)]
pub struct PlanCounters {
    pub started: u64,
    pub succeeded: u64,
    pub cold_only: u64,
    pub failed: u64,
    pub at_capacity: u64,
    pub not_ready: u64,
    pub timed_out: u64,
    pub latency_us: LatencySnapshot,
}

#[derive(Debug, Serialize)]
pub struct ContractLoadCounters {
    pub cold: u64,
    pub warm: u64,
    pub waited: u64,
    pub failed: u64,
    pub cold_latency_us: LatencySnapshot,
}

#[derive(Debug, Serialize)]
pub struct PreloadCounters {
    pub runs: u64,
    pub failed: u64,
    pub contracts: u64,
}

struct LatencyHistogram {
    count: AtomicU64,
    total_us: AtomicU64,
    max_us: AtomicU64,
    buckets: [AtomicU64; LATENCY_BOUNDS_US.len() + 1],
}

impl Default for LatencyHistogram {
    fn default() -> Self {
        Self {
            count: AtomicU64::new(0),
            total_us: AtomicU64::new(0),
            max_us: AtomicU64::new(0),
            buckets: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }
}

impl LatencyHistogram {
    fn record(&self, duration: Duration) {
        let micros = duration.as_micros().min(u64::MAX as u128) as u64;
        self.count.fetch_add(1, Ordering::Relaxed);
        saturating_add(&self.total_us, micros);
        self.max_us.fetch_max(micros, Ordering::Relaxed);
        let bucket = LATENCY_BOUNDS_US
            .iter()
            .position(|bound| micros <= *bound)
            .unwrap_or(LATENCY_BOUNDS_US.len());
        self.buckets[bucket].fetch_add(1, Ordering::Relaxed);
    }

    fn snapshot(&self) -> LatencySnapshot {
        let mut cumulative = 0u64;
        let buckets = self
            .buckets
            .iter()
            .enumerate()
            .map(|(index, count)| {
                cumulative = cumulative.saturating_add(count.load(Ordering::Relaxed));
                LatencyBucket {
                    less_than_or_equal_us: LATENCY_BOUNDS_US.get(index).copied(),
                    cumulative_count: cumulative,
                }
            })
            .collect();
        LatencySnapshot {
            count: self.count.load(Ordering::Relaxed),
            total_us: self.total_us.load(Ordering::Relaxed),
            max_us: self.max_us.load(Ordering::Relaxed),
            buckets,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct LatencySnapshot {
    pub count: u64,
    pub total_us: u64,
    pub max_us: u64,
    pub buckets: Vec<LatencyBucket>,
}

#[derive(Debug, Serialize)]
pub struct LatencyBucket {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub less_than_or_equal_us: Option<u64>,
    pub cumulative_count: u64,
}

fn saturating_add(target: &AtomicU64, value: u64) {
    let _ = target.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
        Some(current.saturating_add(value))
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn histogram_is_cumulative_and_bounded() {
        let histogram = LatencyHistogram::default();
        histogram.record(Duration::from_micros(99));
        histogram.record(Duration::from_micros(251));
        histogram.record(Duration::from_secs(10));
        let snapshot = histogram.snapshot();

        assert_eq!(snapshot.count, 3);
        assert_eq!(snapshot.max_us, 10_000_000);
        assert_eq!(snapshot.buckets.first().unwrap().cumulative_count, 1);
        assert_eq!(snapshot.buckets.last().unwrap().cumulative_count, 3);
        assert_eq!(snapshot.buckets.last().unwrap().less_than_or_equal_us, None);
    }
}
