//! The abort/cancel effect family and the v1 cancel-evidence backstop
//! (plan §9.4.3, §13.5).

use darkbloom_core::ids::{AttemptId, LeaseId};
use darkbloom_core::request::{Event, RequestOutcome};
use darkbloom_core::time::DurationMs;
use darkbloom_protocol::json_v2::AbortReason;

use crate::contracts::ProtocolGen;

use super::events::WireKind;
use super::Driver;

impl Driver {
    /// v1 sessions have no abort/cancel acknowledgement, so once the
    /// consumer has been answered we proactively cancel every open v1
    /// attempt and bound the evidence wait — otherwise a cancelled v1
    /// request would hold its reservation until the total deadline.
    pub(super) fn ensure_cancel_backstop(&mut self) {
        let open: Vec<AttemptId> = self
            .machine
            .attempts()
            .iter()
            .filter(|a| !a.state.is_closed())
            .map(|a| a.id)
            .collect();
        if open.is_empty() {
            return;
        }
        for id in &open {
            if let Some(runtime) = self.runtimes.get_mut(id) {
                if runtime.protocol == ProtocolGen::V1 && !runtime.cancel_sent {
                    runtime.cancel_sent = true;
                    let frame = runtime.cancel_frame();
                    let _ = runtime.session.submit_control(frame);
                }
            }
        }
        if self.cancel_evidence_at.is_none() {
            self.cancel_evidence_at = Some(self.clock.now().saturating_add(DurationMs::new(
                self.deps.policy.terminal_wait.as_millis() as u64,
            )));
        }
    }

    fn abort_reason(&self, attempt: AttemptId) -> AbortReason {
        if self.consumer_gone {
            AbortReason::ClientGone
        } else if matches!(self.outcome, Some(RequestOutcome::FundingFailed)) {
            AbortReason::FundingFailed
        } else if self
            .machine
            .funded_attempt()
            .is_some_and(|funded| funded != attempt)
        {
            AbortReason::HedgeLoss
        } else {
            AbortReason::DeadlineUnreachable
        }
    }

    pub(super) fn send_abort(&mut self, attempt: AttemptId, _lease: LeaseId) {
        let reason = self.abort_reason(attempt);
        let Some(runtime) = self.runtimes.get_mut(&attempt) else {
            return;
        };
        runtime.cancel_sent = true;
        let frame = runtime.abort_frame(reason);
        let session = runtime.session.clone();
        let is_v1 = runtime.protocol == ProtocolGen::V1;
        match session.submit_control(frame) {
            Ok(on_wire) => self.spawn_wire_pump(attempt, WireKind::Abort, on_wire),
            Err(_) => {
                // A full/closed control lane is session-fencing evidence
                // (plan §9.4.3): treat as session loss for this attempt.
                self.push(Event::SessionLost { attempt });
                return;
            }
        }
        if is_v1 && self.cancel_evidence_at.is_none() {
            // v1 has no abort ack; bound the evidence wait.
            self.cancel_evidence_at = Some(self.clock.now().saturating_add(DurationMs::new(
                self.deps.policy.terminal_wait.as_millis() as u64,
            )));
        }
    }

    pub(super) fn send_cancel(&mut self, attempt: AttemptId) {
        let Some(runtime) = self.runtimes.get_mut(&attempt) else {
            return;
        };
        runtime.cancel_sent = true;
        let frame = runtime.cancel_frame();
        let session = runtime.session.clone();
        match session.submit_control(frame) {
            Ok(on_wire) => self.spawn_wire_pump(attempt, WireKind::Cancel, on_wire),
            Err(_) => self.push(Event::SessionLost { attempt }),
        }
    }
}
