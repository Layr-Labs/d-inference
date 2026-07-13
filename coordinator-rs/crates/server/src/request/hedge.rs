//! Deterministic pre-authorization alternate and hedge scheduling.

use darkbloom_coordinator_core::{
    deadline::{AbsoluteDeadline, EpochMillis},
    ids::AttemptId,
};

use super::error::HedgeError;

/// A deterministic scheduler notification.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PreAuthorizationAction {
    /// Renew the prepared base attempt before its finite lease expires.
    RenewLease { attempt_id: AttemptId },
    /// Pre-authorize the one allowed speculative hedge.
    LaunchHedge,
    /// The immutable request deadline has elapsed.
    DeadlineExpired,
}

/// One logical request's bounded pre-authorization planner.
///
/// It does not create tasks or sleep. The owner asks for the next timestamp and
/// calls [`Self::action_at`] using its clock, which makes races testable under a
/// deterministic clock.
#[derive(Debug)]
pub struct PreAuthorizationPlanner {
    deadline: AbsoluteDeadline,
    base_attempt: AttemptId,
    hedge_at: EpochMillis,
    lease_expires_at: EpochMillis,
    renewal_lead_ms: u64,
    renewal_pending: bool,
    alternate_consumed: bool,
    hedge_launched: bool,
    start_authorized: bool,
    content_committed: bool,
    deadline_reported: bool,
}

impl PreAuthorizationPlanner {
    /// Creates a schedule from absolute wall-clock observations.
    pub fn new(
        now: EpochMillis,
        deadline: AbsoluteDeadline,
        base_attempt: AttemptId,
        hedge_delay_ms: u64,
        lease_ttl_ms: u64,
        renewal_lead_ms: u64,
    ) -> Result<Self, HedgeError> {
        let hedge_at = add_millis(now, hedge_delay_ms)?;
        let lease_expires_at = add_millis(now, lease_ttl_ms)?;
        Ok(Self {
            deadline,
            base_attempt,
            hedge_at,
            lease_expires_at,
            renewal_lead_ms,
            renewal_pending: false,
            alternate_consumed: false,
            hedge_launched: false,
            start_authorized: false,
            content_committed: false,
            deadline_reported: false,
        })
    }

    /// Returns the next absolute time at which the owner should poll.
    #[must_use]
    pub fn next_notification_at(&self) -> Option<EpochMillis> {
        if self.start_authorized || self.content_committed || self.deadline_reported {
            return None;
        }
        let deadline = self.deadline.epoch_millis();
        if self.renewal_pending {
            return Some(deadline);
        }
        let renewal_at = EpochMillis::new(
            self.lease_expires_at
                .get()
                .saturating_sub(self.renewal_lead_ms),
        );
        Some(self.hedge_at.min(renewal_at).min(deadline))
    }

    /// Returns at most one action for this clock observation.
    pub fn action_at(&mut self, now: EpochMillis) -> Option<PreAuthorizationAction> {
        if self.start_authorized || self.content_committed || self.deadline_reported {
            return None;
        }
        if self.deadline.is_expired_at(now) {
            self.deadline_reported = true;
            return Some(PreAuthorizationAction::DeadlineExpired);
        }
        if self.renewal_pending {
            return None;
        }
        let renewal_at = self
            .lease_expires_at
            .get()
            .saturating_sub(self.renewal_lead_ms);
        let renewal_precedes_hedge = renewal_at <= self.hedge_at.get();
        if renewal_precedes_hedge && now.get() >= renewal_at {
            self.renewal_pending = true;
            return Some(PreAuthorizationAction::RenewLease {
                attempt_id: self.base_attempt,
            });
        }
        if !self.hedge_launched && now.get() >= self.hedge_at.get() {
            self.hedge_launched = true;
            return Some(PreAuthorizationAction::LaunchHedge);
        }
        if now.get() >= renewal_at {
            self.renewal_pending = true;
            return Some(PreAuthorizationAction::RenewLease {
                attempt_id: self.base_attempt,
            });
        }
        None
    }

    /// Records successful lease renewal and schedules the next notification.
    pub fn lease_renewed(&mut self, now: EpochMillis, lease_ttl_ms: u64) -> Result<(), HedgeError> {
        self.lease_expires_at = add_millis(now, lease_ttl_ms)?;
        self.renewal_pending = false;
        Ok(())
    }

    /// Consumes the sole sequential alternate slot.
    pub fn consume_alternate(&mut self) -> Result<(), HedgeError> {
        self.require_pre_authorization()?;
        if self.alternate_consumed {
            return Err(HedgeError::AlternateAlreadyConsumed);
        }
        self.alternate_consumed = true;
        Ok(())
    }

    /// Consumes the sole speculative hedge slot when a timer is managed
    /// externally rather than through [`Self::action_at`].
    pub fn consume_hedge(&mut self) -> Result<(), HedgeError> {
        self.require_pre_authorization()?;
        if self.hedge_launched {
            return Err(HedgeError::HedgeAlreadyLaunched);
        }
        self.hedge_launched = true;
        Ok(())
    }

    /// Permanently fences all alternate and hedge work at start authorization.
    pub fn mark_start_authorized(&mut self) {
        self.start_authorized = true;
    }

    /// Permanently fences all alternate and hedge work at content commitment.
    pub fn mark_content_committed(&mut self) {
        self.content_committed = true;
    }

    fn require_pre_authorization(&self) -> Result<(), HedgeError> {
        if self.content_committed {
            Err(HedgeError::AfterContent)
        } else if self.start_authorized {
            Err(HedgeError::AfterAuthorization)
        } else {
            Ok(())
        }
    }
}

fn add_millis(now: EpochMillis, duration_ms: u64) -> Result<EpochMillis, HedgeError> {
    now.get()
        .checked_add(duration_ms)
        .map(EpochMillis::new)
        .ok_or(HedgeError::TimestampOverflow)
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    fn attempt() -> AttemptId {
        AttemptId::new(Uuid::from_bytes([1; 16])).expect("attempt")
    }

    #[test]
    fn delay_beyond_ttl_notifies_renewal_before_hedge() {
        let deadline = AbsoluteDeadline::new(10_000).expect("deadline");
        let mut planner = PreAuthorizationPlanner::new(
            EpochMillis::new(1_000),
            deadline,
            attempt(),
            2_000,
            500,
            100,
        )
        .expect("planner");
        assert_eq!(
            planner.next_notification_at(),
            Some(EpochMillis::new(1_400))
        );
        assert_eq!(
            planner.action_at(EpochMillis::new(1_400)),
            Some(PreAuthorizationAction::RenewLease {
                attempt_id: attempt()
            })
        );
        assert_eq!(planner.action_at(EpochMillis::new(3_000)), None);
        planner
            .lease_renewed(EpochMillis::new(1_400), 5_000)
            .expect("renew");
        assert_eq!(
            planner.action_at(EpochMillis::new(3_000)),
            Some(PreAuthorizationAction::LaunchHedge)
        );
    }

    #[test]
    fn alternate_and_hedge_are_single_use_and_pre_authorization_only() {
        let mut planner = PreAuthorizationPlanner::new(
            EpochMillis::new(1),
            AbsoluteDeadline::new(100).expect("deadline"),
            attempt(),
            10,
            50,
            5,
        )
        .expect("planner");
        planner.consume_alternate().expect("one alternate");
        assert_eq!(
            planner.consume_alternate(),
            Err(HedgeError::AlternateAlreadyConsumed)
        );
        planner.consume_hedge().expect("one hedge");
        assert_eq!(
            planner.consume_hedge(),
            Err(HedgeError::HedgeAlreadyLaunched)
        );
        planner.mark_start_authorized();
        assert_eq!(
            planner.consume_alternate(),
            Err(HedgeError::AfterAuthorization)
        );
    }

    #[test]
    fn deadline_is_absolute_and_reported_once() {
        let mut planner = PreAuthorizationPlanner::new(
            EpochMillis::new(90),
            AbsoluteDeadline::new(100).expect("deadline"),
            attempt(),
            50,
            50,
            1,
        )
        .expect("planner");
        assert_eq!(
            planner.action_at(EpochMillis::new(100)),
            Some(PreAuthorizationAction::DeadlineExpired)
        );
        assert_eq!(planner.action_at(EpochMillis::new(101)), None);
    }
}
