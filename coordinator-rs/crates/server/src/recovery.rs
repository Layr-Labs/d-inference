//! Recovery workers — bounded claims over durable jobs (plan §18.1).
//!
//! Memory-backed for tests; Postgres SKIP LOCKED lands with SQLx.

use crate::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryAction {
    Released,
    AlreadyTerminal,
    Skipped,
    /// start_authorized job left held for human/ops review (DECISIONS #16).
    HeldForReview,
}

/// Release reserved jobs that never reached start_authorized.
pub fn recover_undispatched(
    ledger: &Arc<Mutex<MemoryLedger>>,
    job_id: &str,
    account: &str,
) -> Result<RecoveryAction, String> {
    let mut g = ledger.lock().map_err(|e| e.to_string())?;
    if g.job_funded_start(job_id) {
        // start_authorized — must not auto-redispatch or auto-release in pilot.
        return Ok(RecoveryAction::Skipped);
    }
    if g.active_job_count() == 0 && g.job_reserved_total(job_id).is_none() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    match g.release(
        OperationKey(format!("recovery_release:{job_id}")),
        job_id,
        account,
    ) {
        Ok(true) => Ok(RecoveryAction::Released),
        Ok(false) => Ok(RecoveryAction::AlreadyTerminal),
        Err(e) => Err(e.to_string()),
    }
}

/// Explicit ops review settle for a start_authorized held job (DECISIONS #16).
/// Charges `actual` (capped by reservation) and clears the hold.
pub fn force_settle_held(
    ledger: &Arc<Mutex<MemoryLedger>>,
    job_id: &str,
    account: &str,
    actual: i64,
    terminal_digest: &str,
) -> Result<RecoveryAction, String> {
    let mut g = ledger.lock().map_err(|e| e.to_string())?;
    if !g.job_funded_start(job_id) {
        return Ok(RecoveryAction::Skipped);
    }
    if g.active_job_count() == 0 || g.job_reserved_total(job_id).is_none() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    match g.settle(
        OperationKey(format!("force_settle:{job_id}")),
        job_id,
        account,
        actual,
        terminal_digest,
    ) {
        Ok(true) => Ok(RecoveryAction::Released), // settled — reuse Released as "cleared"
        Ok(false) => Ok(RecoveryAction::AlreadyTerminal),
        Err(e) => Err(e.to_string()),
    }
}

/// Classify a start_authorized job that never reached a provider terminal.
/// Does not move money — ops must settle or force-release via explicit review.
pub fn recover_start_authorized_held(
    ledger: &Arc<Mutex<MemoryLedger>>,
    job_id: &str,
) -> Result<RecoveryAction, String> {
    let g = ledger.lock().map_err(|e| e.to_string())?;
    if g.job_reserved_total(job_id).is_none() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    if !g.job_funded_start(job_id) {
        return Ok(RecoveryAction::Skipped);
    }
    if g.active_job_count() == 0 {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    Ok(RecoveryAction::HeldForReview)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn releases_reserved_not_started() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
        }
        assert_eq!(
            recover_undispatched(&led, "j1", "a").unwrap(),
            RecoveryAction::Released
        );
        assert_eq!(led.lock().unwrap().balance("a").0, 1_000_000);
    }

    #[test]
    fn skips_start_authorized() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1").unwrap();
        }
        assert_eq!(
            recover_undispatched(&led, "j1", "a").unwrap(),
            RecoveryAction::Skipped
        );
    }

    #[test]
    fn held_for_review_when_start_authorized_and_active() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1").unwrap();
        }
        assert_eq!(
            recover_start_authorized_held(&led, "j1").unwrap(),
            RecoveryAction::HeldForReview
        );
        // Money still held.
        assert_eq!(led.lock().unwrap().balance("a").0, 900_000);
        assert_eq!(led.lock().unwrap().active_job_count(), 1);
    }

    #[test]
    fn held_helper_skips_when_not_start_authorized() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
        }
        assert_eq!(
            recover_start_authorized_held(&led, "j1").unwrap(),
            RecoveryAction::Skipped
        );
    }

    #[test]
    fn force_settle_held_clears_hold() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1").unwrap();
        }
        assert_eq!(
            force_settle_held(&led, "j1", "a", 40_000, "force-d1").unwrap(),
            RecoveryAction::Released
        );
        let g = led.lock().unwrap();
        assert_eq!(g.active_job_count(), 0);
        // reserved 100k, charged 40k → refund 60k → bal = 1M-100k+60k = 960k
        assert_eq!(g.balance("a").0, 960_000);
        assert_eq!(g.held_start_authorized_count(), 0);
    }

    #[test]
    fn force_settle_held_second_call_is_already_terminal() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1").unwrap();
        }
        assert_eq!(
            force_settle_held(&led, "j1", "a", 40_000, "force-d1").unwrap(),
            RecoveryAction::Released
        );
        // Same digest / disposed job → AlreadyTerminal (idempotent).
        assert_eq!(
            force_settle_held(&led, "j1", "a", 40_000, "force-d1").unwrap(),
            RecoveryAction::AlreadyTerminal
        );
        assert_eq!(led.lock().unwrap().balance("a").0, 960_000);
    }

    #[test]
    fn force_settle_held_skips_when_not_authorized() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
        }
        assert_eq!(
            force_settle_held(&led, "j1", "a", 40_000, "force-d1").unwrap(),
            RecoveryAction::Skipped
        );
        assert_eq!(led.lock().unwrap().active_job_count(), 1);
    }

    #[test]
    fn held_start_authorized_count_tracks_holds() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j1", "a", 100_000)
            .unwrap();
        assert_eq!(led.held_start_authorized_count(), 0);
        led.mark_start_authorized("j1").unwrap();
        assert_eq!(led.held_start_authorized_count(), 1);
        assert_eq!(led.held_start_authorized_job_ids(), vec!["j1".to_string()]);
    }
}
