use super::Readiness;
use crate::metrics::Metrics;
use crate::preload::{PreloadError, PreloadReport, PreloadStatus};
use std::collections::HashSet;
use std::sync::{Arc, Mutex, MutexGuard};

enum Mode {
    // Only direct library/fixture construction may lazily load before the first
    // explicit operation. The production server marks Starting before listening.
    LegacyLazy,
    Starting,
    Usable(HashSet<String>),
    Degraded,
}

struct State {
    operation: u64,
    mode: Mode,
}

pub(super) struct ReadinessGate(Mutex<State>);

impl ReadinessGate {
    pub(super) fn new() -> Self {
        Self(Mutex::new(State {
            operation: 0,
            mode: Mode::LegacyLazy,
        }))
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        match self.0.lock() {
            Ok(state) => state,
            Err(poisoned) => {
                let mut state = poisoned.into_inner();
                state.mode = Mode::Degraded;
                state
            }
        }
    }

    pub(super) fn mark_starting(&self) {
        let mut state = self.lock();
        match state.operation.checked_add(1) {
            Some(next) => {
                state.operation = next;
                state.mode = Mode::Starting;
            }
            None => state.mode = Mode::Degraded,
        }
    }

    pub(super) fn status(&self) -> Readiness {
        match &self.lock().mode {
            Mode::LegacyLazy | Mode::Usable(_) => Readiness::Ready,
            Mode::Starting => Readiness::Starting,
            Mode::Degraded => Readiness::Degraded,
        }
    }

    pub(super) fn allows(&self, id: &str) -> bool {
        match &self.lock().mode {
            Mode::LegacyLazy => true,
            Mode::Usable(successful) => successful.contains(id),
            Mode::Starting | Mode::Degraded => false,
        }
    }

    fn begin(&self) -> Option<u64> {
        let mut state = self.lock();
        let Some(next) = state.operation.checked_add(1) else {
            state.mode = Mode::Degraded;
            return None;
        };
        state.operation = next;
        state.mode = Mode::Starting;
        Some(next)
    }

    fn finish(&self, operation: u64, successful: HashSet<String>) {
        let mut state = self.lock();
        if state.operation != operation || !matches!(state.mode, Mode::Starting) {
            return;
        }
        state.mode = if successful.is_empty() {
            Mode::Degraded
        } else {
            Mode::Usable(successful)
        };
    }
}

// The requesting future owns publication authority, independently of blocking
// loader work. Dropping that future closes participation and classifies the
// failed operation once; detached work may populate the LRU but cannot publish.
pub(super) struct PreloadOperation {
    gate: Arc<ReadinessGate>,
    metrics: Arc<Metrics>,
    operation: u64,
    finished: bool,
}

impl PreloadOperation {
    pub(super) fn begin(
        gate: Arc<ReadinessGate>,
        metrics: Arc<Metrics>,
        count: usize,
    ) -> Result<Self, PreloadError> {
        metrics.preload_started(count);
        let Some(operation) = gate.begin() else {
            metrics.preload_finished(false);
            return Err(PreloadError::Worker);
        };
        Ok(Self {
            gate,
            metrics,
            operation,
            finished: false,
        })
    }

    pub(super) fn finish(mut self, report: &PreloadReport) {
        let successful = report
            .results
            .iter()
            .filter(|result| matches!(result.status, PreloadStatus::Warm | PreloadStatus::Cold))
            .map(|result| result.prompt_contract_id.clone())
            .collect();
        self.gate.finish(self.operation, successful);
        // Report.ready still means ALL submitted contracts succeeded. Partial
        // runtime usefulness does not turn a degraded preload into full success.
        self.metrics.preload_finished(report.ready);
        self.finished = true;
    }
}

impl Drop for PreloadOperation {
    fn drop(&mut self) {
        if !self.finished {
            self.gate.finish(self.operation, HashSet::new());
            self.metrics.preload_finished(false);
        }
    }
}

#[cfg(test)]
#[path = "readiness_state_tests.rs"]
mod tests;
