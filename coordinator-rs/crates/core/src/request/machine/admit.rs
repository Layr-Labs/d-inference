//! Reserve and admission handlers (plan 7.8 steps 1-3, 12.5).

use super::{MoneyState, RequestMachine, MAX_ATTEMPTS};
use crate::ids::{AttemptId, ProviderId};
use crate::request::effects::Effect;
use crate::request::errors::TransitionError;
use crate::request::types::{AttemptKind, AttemptRecord, Phase, RequestOutcome};
use crate::time::DurationMs;

impl RequestMachine {
    pub(super) fn on_reserve_committed(
        &mut self,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        if !matches!(self.phase, Phase::Reserving) {
            return Err(self.phase_mismatch("reserve_committed"));
        }
        self.money = MoneyState::Held;
        if self.cancel_requested {
            // The consumer cancelled while the reservation was in flight
            // (13.1): release immediately, dispatch nothing.
            self.dispose_release(effects);
            return Ok(());
        }
        self.phase = Phase::Admitting;
        effects.push(Effect::RequestAdmission {
            exclude: self.attempted_providers.clone(),
        });
        Ok(())
    }

    pub(super) fn on_reserve_failed(
        &mut self,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        if !matches!(self.phase, Phase::Reserving) {
            return Err(self.phase_mismatch("reserve_failed"));
        }
        self.complete_once(RequestOutcome::ReserveFailed, effects);
        self.phase = Phase::Finished;
        Ok(())
    }

    pub(super) fn on_admit_granted(
        &mut self,
        attempt: AttemptId,
        provider: ProviderId,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        if self.attempts.iter().any(|a| a.id == attempt) {
            return Err(TransitionError::DuplicateAttempt { attempt });
        }
        if !matches!(self.phase, Phase::Admitting) {
            // A grant that raced a cancel or failure: the caller holds a
            // permit that must not leak (9.2.10).
            if matches!(self.phase, Phase::Finalizing | Phase::Finished) {
                effects.push(Effect::ReleasePermit { attempt });
                return Ok(());
            }
            return Err(self.phase_mismatch("admit_granted"));
        }
        if self.attempts.len() >= MAX_ATTEMPTS {
            return Err(TransitionError::TooManyAttempts);
        }
        let kind = if self.attempts.is_empty() {
            AttemptKind::Primary
        } else {
            AttemptKind::SequentialAlternate
        };
        self.attempts
            .push(AttemptRecord::new(attempt, provider, kind));
        self.attempted_providers.insert(provider);
        self.phase = Phase::Preparing;
        effects.push(Effect::SendPrepare { attempt, provider });
        Ok(())
    }

    pub(super) fn on_admit_failed(
        &mut self,
        retry_after: Option<DurationMs>,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        if !matches!(self.phase, Phase::Admitting) {
            if matches!(self.phase, Phase::Finalizing | Phase::Finished) {
                return Ok(());
            }
            return Err(self.phase_mismatch("admit_failed"));
        }
        self.fail_request(RequestOutcome::NoCapacity { retry_after }, effects);
        Ok(())
    }
}
