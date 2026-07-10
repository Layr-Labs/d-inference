//! Prepare-permit accounting (plan sections 9.2.10, 11.1, 11.3).
//!
//! A permit is a short-lived coordinator-local reservation limiting how many
//! prepares are outstanding per provider. Invariants enforced here:
//!
//! - Every permit has a hard expiry and an idempotent release path (9.2.10).
//! - Outstanding permits per provider never exceed the advisory-capacity
//!   bound supplied at reservation time.
//! - Counts are derived from record removal, so they can never go negative.

use std::collections::BTreeMap;

use thiserror::Error;

use crate::ids::{PermitId, ProviderId};
use crate::time::{DurationMs, TimestampMs};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PermitRecord {
    provider: ProviderId,
    expires_at: TimestampMs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum PermitError {
    /// A permit id was reused while still outstanding. Ids are single-use.
    #[error("permit id already outstanding")]
    DuplicatePermitId,
    /// The provider is at its advisory outstanding-prepare bound.
    #[error("provider at outstanding-permit bound")]
    ProviderSaturated,
}

/// Outcome of an idempotent release (9.2.10): releasing twice is legal and
/// visible, never an error and never a double decrement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReleaseOutcome {
    Released,
    AlreadyReleased,
}

/// All outstanding prepare permits. Bounded by (providers x per-provider cap).
#[derive(Debug, Clone, Default)]
pub struct PermitBook {
    outstanding: BTreeMap<PermitId, PermitRecord>,
}

impl PermitBook {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Reserve one permit for `provider`, expiring `ttl` after `now`.
    ///
    /// `max_outstanding` is the advisory-capacity bound for this provider at
    /// this moment (plan section 11.3: heartbeat capacity limits how many
    /// prepares are outstanding; it never authorizes execution).
    pub fn reserve(
        &mut self,
        permit: PermitId,
        provider: ProviderId,
        now: TimestampMs,
        ttl: DurationMs,
        max_outstanding: u32,
    ) -> Result<(), PermitError> {
        if self.outstanding.contains_key(&permit) {
            return Err(PermitError::DuplicatePermitId);
        }
        if self.outstanding_for(provider) >= max_outstanding {
            return Err(PermitError::ProviderSaturated);
        }
        self.outstanding.insert(
            permit,
            PermitRecord {
                provider,
                expires_at: now.saturating_add(ttl),
            },
        );
        Ok(())
    }

    /// Idempotent release. The count decrements only when the record is
    /// actually removed, so no release sequence can drive it negative.
    pub fn release(&mut self, permit: PermitId) -> ReleaseOutcome {
        if self.outstanding.remove(&permit).is_some() {
            ReleaseOutcome::Released
        } else {
            ReleaseOutcome::AlreadyReleased
        }
    }

    /// Sweep every permit whose hard expiry has passed and return them.
    /// Expiry is itself an idempotent release path (9.2.10).
    pub fn expire(&mut self, now: TimestampMs) -> Vec<PermitId> {
        let expired: Vec<PermitId> = self
            .outstanding
            .iter()
            .filter(|(_, record)| now >= record.expires_at)
            .map(|(id, _)| *id)
            .collect();
        for id in &expired {
            self.outstanding.remove(id);
        }
        expired
    }

    /// Outstanding permit count for one provider (the scoring load-spread
    /// input and the reservation bound check).
    #[must_use]
    pub fn outstanding_for(&self, provider: ProviderId) -> u32 {
        let count = self
            .outstanding
            .values()
            .filter(|record| record.provider == provider)
            .count();
        u32::try_from(count).unwrap_or(u32::MAX)
    }

    #[must_use]
    pub fn total_outstanding(&self) -> usize {
        self.outstanding.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    const NOW: TimestampMs = TimestampMs::new(0);
    const TTL: DurationMs = DurationMs::new(1_000);

    fn permit(n: u128) -> PermitId {
        PermitId::new(Uuid::from_u128(n))
    }

    fn provider(n: u128) -> ProviderId {
        ProviderId::new(Uuid::from_u128(n))
    }

    #[test]
    fn reserve_release_is_idempotent() {
        let mut book = PermitBook::new();
        book.reserve(permit(1), provider(1), NOW, TTL, 2)
            .expect("reserve");
        assert_eq!(book.outstanding_for(provider(1)), 1);
        assert_eq!(book.release(permit(1)), ReleaseOutcome::Released);
        assert_eq!(book.release(permit(1)), ReleaseOutcome::AlreadyReleased);
        assert_eq!(book.outstanding_for(provider(1)), 0);
    }

    #[test]
    fn provider_bound_enforced() {
        let mut book = PermitBook::new();
        book.reserve(permit(1), provider(1), NOW, TTL, 1)
            .expect("first fits");
        assert_eq!(
            book.reserve(permit(2), provider(1), NOW, TTL, 1),
            Err(PermitError::ProviderSaturated)
        );
        // Another provider is unaffected.
        book.reserve(permit(3), provider(2), NOW, TTL, 1)
            .expect("other provider fits");
    }

    #[test]
    fn duplicate_permit_id_rejected() {
        let mut book = PermitBook::new();
        book.reserve(permit(1), provider(1), NOW, TTL, 2)
            .expect("reserve");
        assert_eq!(
            book.reserve(permit(1), provider(1), NOW, TTL, 2),
            Err(PermitError::DuplicatePermitId)
        );
    }

    #[test]
    fn hard_expiry_sweeps_and_release_after_expiry_is_noop() {
        let mut book = PermitBook::new();
        book.reserve(permit(1), provider(1), NOW, TTL, 2)
            .expect("reserve");
        assert!(book.expire(TimestampMs::new(999)).is_empty());
        let expired = book.expire(TimestampMs::new(1_000));
        assert_eq!(expired, vec![permit(1)]);
        assert_eq!(book.release(permit(1)), ReleaseOutcome::AlreadyReleased);
        assert_eq!(book.outstanding_for(provider(1)), 0);
    }
}
