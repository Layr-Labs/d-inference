//! Deadline/timer arming, selection, and firing (plan §9.2.5, §16):
//! the reducer refuses early timer events, so all arming stays monotonic
//! against the task [`Clock`](crate::request_task::types::Clock).

use darkbloom_core::ids::AttemptId;
use darkbloom_core::request::{Event, Phase};
use darkbloom_core::time::{DurationMs, TimestampMs};

use super::Driver;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TimerKind {
    FirstContent,
    Total,
    Hedge,
    PrepareDeadline(AttemptId),
    LeaseExpiry(AttemptId),
    StartRetry,
    TerminalWait,
    CancelEvidence,
    StreamIdle,
}

impl Driver {
    /// Re-arms/clears timers after every reducer step (phase-derived
    /// bookkeeping the reducer itself does not own).
    pub(super) fn after_apply(&mut self) {
        let now = self.clock.now();
        let phase = self.machine.phase();
        if self.machine.funded_attempt().is_some() || !matches!(phase, Phase::Preparing) {
            self.hedge_at = None;
        }
        if matches!(phase, Phase::AwaitingTerminal { .. }) && self.terminal_wait_at.is_none() {
            self.terminal_wait_at = Some(now.saturating_add(DurationMs::new(
                self.deps.policy.terminal_wait.as_millis() as u64,
            )));
        }
        if !matches!(phase, Phase::Starting { .. }) {
            self.start_retry_at = None;
        }
        if self.outcome.is_some() && !self.machine.is_finished() {
            self.ensure_cancel_backstop();
        }
    }

    pub(super) fn next_timer(&self) -> Option<(TimestampMs, TimerKind)> {
        let mut best: Option<(TimestampMs, TimerKind)> = None;
        let mut consider = |at: Option<TimestampMs>, kind: TimerKind| {
            if let Some(at) = at {
                if best.is_none_or(|(b, _)| at < b) {
                    best = Some((at, kind));
                }
            }
        };
        if !self.first_content_fired && self.machine.committed_attempt().is_none() {
            consider(Some(self.first_content_deadline), TimerKind::FirstContent);
        }
        if !self.total_fired {
            consider(Some(self.total_deadline), TimerKind::Total);
        }
        consider(self.hedge_at, TimerKind::Hedge);
        for (id, runtime) in &self.runtimes {
            consider(runtime.prepare_deadline_at, TimerKind::PrepareDeadline(*id));
            consider(runtime.lease_expiry_at, TimerKind::LeaseExpiry(*id));
        }
        if matches!(self.machine.phase(), Phase::Starting { .. }) {
            consider(self.start_retry_at, TimerKind::StartRetry);
        }
        consider(self.terminal_wait_at, TimerKind::TerminalWait);
        consider(self.cancel_evidence_at, TimerKind::CancelEvidence);
        if matches!(
            self.machine.phase(),
            Phase::AwaitingContent { .. } | Phase::Streaming { .. }
        ) {
            consider(self.idle_at, TimerKind::StreamIdle);
        }
        best
    }

    pub(super) fn arm_idle_timer(&mut self) {
        self.idle_at = Some(self.clock.now().saturating_add(DurationMs::new(
            self.deps.policy.stream_idle_timeout.as_millis() as u64,
        )));
    }

    pub(super) async fn on_timer(&mut self, kind: TimerKind) {
        match kind {
            TimerKind::FirstContent => {
                self.first_content_fired = true;
                self.feed_now(Event::FirstContentDeadlineElapsed).await;
            }
            TimerKind::Total => {
                self.total_fired = true;
                self.feed_now(Event::TotalDeadlineElapsed).await;
            }
            TimerKind::Hedge => {
                self.hedge_at = None;
                self.hedge_fired = true;
                self.fire_hedge().await;
            }
            TimerKind::PrepareDeadline(attempt) => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.prepare_deadline_at = None;
                }
                self.feed_now(Event::AttemptTimedOut { attempt }).await;
            }
            TimerKind::LeaseExpiry(attempt) => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.lease_expiry_at = None;
                }
                self.feed_now(Event::AttemptTimedOut { attempt }).await;
            }
            TimerKind::StartRetry => {
                self.start_retry_at = None;
                self.feed_now(Event::StartRetryTimerFired).await;
            }
            TimerKind::TerminalWait => {
                self.terminal_wait_at = None;
                self.feed_now(Event::TerminalWaitElapsed).await;
            }
            TimerKind::CancelEvidence => {
                self.cancel_evidence_at = None;
                let open: Vec<AttemptId> = self
                    .machine
                    .attempts()
                    .iter()
                    .filter(|a| !a.state.is_closed())
                    .map(|a| a.id)
                    .collect();
                for attempt in open {
                    self.feed_now(Event::AttemptTimedOut { attempt }).await;
                }
            }
            TimerKind::StreamIdle => {
                self.idle_at = None;
                if let Some(funded) = self.machine.funded_attempt() {
                    self.feed_now(Event::AttemptTimedOut { attempt: funded })
                        .await;
                }
            }
        }
    }
}
