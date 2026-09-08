//! Attempt-event delivery with the lane-overflow policy (plan §9.4.5).
//! Invariant: terminal-class events are never silently dropped — on a full
//! events lane they ride the permit reserved at attach.

use tokio::sync::mpsc;

use crate::contracts::AttemptEvent;

use super::attempts;
use super::reader::Reader;

/// Why one delivered event could not be handed to the request task.
pub(super) enum Deliver {
    Ok,
    NoAttempt,
    /// Events lane overflow: the attempt was dropped with `SessionLost`
    /// semantics per the contract, without blocking the read loop.
    Dropped,
}

impl Reader {
    /// Delivers one control event to an attached attempt with the contract
    /// overflow policy, never blocking the read loop. On a full events lane
    /// (plan §9.4.5 — terminal/cancel-class events must not be silently
    /// dropped):
    ///
    /// - a terminal-class event (`Terminal`, `Aborted`, `Cancelled`,
    ///   `SessionLost`, and the v1 terminals) is delivered through the
    ///   permit reserved at attach — guaranteed capacity — and the attempt
    ///   detaches (it has its final event);
    /// - a normal event drops the attempt, with the mandatory `SessionLost`
    ///   delivered through that same reserved slot (the old fallback of
    ///   `try_send`ing into the full channel provably could not deliver).
    pub(super) fn deliver_event(&mut self, wire_id: &str, event: AttemptEvent) -> Deliver {
        let mut table = attempts::lock(&self.attempts);
        let Some(entry) = table.entry_mut(wire_id) else {
            return Deliver::NoAttempt;
        };
        let Some(sinks) = entry.sinks.as_ref() else {
            return Deliver::NoAttempt;
        };
        match sinks.events.try_send(event) {
            Ok(()) => Deliver::Ok,
            Err(mpsc::error::TrySendError::Full(event)) => {
                let terminal_class = is_terminal_class(&event);
                let fallback = if terminal_class {
                    event
                } else {
                    AttemptEvent::SessionLost
                };
                match entry.reserved.take() {
                    Some(permit) => {
                        let _ = permit.send(fallback);
                    }
                    None => {
                        // No permit could be reserved at attach: the lossy
                        // legacy fallback, kept as the last resort.
                        if let Some(sinks) = entry.sinks.take() {
                            let _ = sinks.events.try_send(fallback);
                        }
                    }
                }
                table.detach(wire_id);
                if terminal_class {
                    tracing::warn!(
                        wire_id,
                        "event lane overflow; terminal-class event took the reserved slot"
                    );
                    Deliver::Ok
                } else {
                    tracing::warn!(wire_id, "attempt event lane overflow; attempt dropped");
                    Deliver::Dropped
                }
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                table.detach(wire_id);
                Deliver::NoAttempt
            }
        }
    }
}

/// Terminal-class events end an attempt; they ride the reserved permit on
/// lane overflow instead of ever being dropped (plan §9.4.5).
fn is_terminal_class(event: &AttemptEvent) -> bool {
    matches!(
        event,
        AttemptEvent::Terminal(_)
            | AttemptEvent::Aborted { .. }
            | AttemptEvent::Cancelled
            | AttemptEvent::SessionLost
            | AttemptEvent::CompleteV1 { .. }
            | AttemptEvent::ErrorV1 { .. }
    )
}
