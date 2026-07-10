//! Recovery workers — bounded claims over durable jobs (plan §18.1).
//!
//! Memory-backed for tests; Postgres SKIP LOCKED lands with SQLx.

use crate::ledger::{LedgerError, MemoryLedger, OperationKey};
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
    recover_undispatched_fenced(ledger, 0, job_id, account)
}

/// Like `recover_undispatched` but refuses when fencing epoch mismatches (DECISIONS #59).
pub fn recover_undispatched_fenced(
    ledger: &Arc<Mutex<MemoryLedger>>,
    fencing_epoch: u64,
    job_id: &str,
    account: &str,
) -> Result<RecoveryAction, String> {
    let mut g = ledger.lock().map_err(|e| e.to_string())?;
    recover_undispatched_on(&mut g, fencing_epoch, job_id, account).map_err(|e| e.to_string())
}

/// Core recover path for callers that already hold the ledger lock (DECISIONS #59/#62).
pub fn recover_undispatched_on(
    g: &mut MemoryLedger,
    fencing_epoch: u64,
    job_id: &str,
    account: &str,
) -> Result<RecoveryAction, LedgerError> {
    if g.job_disposition(job_id).is_some() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    if g.job_funded_start(job_id) {
        return Ok(RecoveryAction::Skipped);
    }
    if g.active_job_count() == 0 && g.job_reserved_total(job_id).is_none() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    match g.release_fenced(
        fencing_epoch,
        OperationKey(format!("recovery_release:{job_id}")),
        job_id,
        account,
    )? {
        true => Ok(RecoveryAction::Released),
        false => Ok(RecoveryAction::AlreadyTerminal),
    }
}

/// Explicit ops review settle for a start_authorized held job (DECISIONS #16).
pub fn force_settle_held(
    ledger: &Arc<Mutex<MemoryLedger>>,
    job_id: &str,
    account: &str,
    actual: i64,
    terminal_digest: &str,
) -> Result<RecoveryAction, String> {
    force_settle_held_fenced(ledger, 0, job_id, account, actual, terminal_digest)
}

/// Like `force_settle_held` but refuses when fencing epoch mismatches (DECISIONS #59).
pub fn force_settle_held_fenced(
    ledger: &Arc<Mutex<MemoryLedger>>,
    fencing_epoch: u64,
    job_id: &str,
    account: &str,
    actual: i64,
    terminal_digest: &str,
) -> Result<RecoveryAction, String> {
    let mut g = ledger.lock().map_err(|e| e.to_string())?;
    force_settle_held_on(&mut g, fencing_epoch, job_id, account, actual, terminal_digest)
        .map_err(|e| e.to_string())
}

/// Core force-settle path for callers that already hold the ledger lock (DECISIONS #59/#62).
pub fn force_settle_held_on(
    g: &mut MemoryLedger,
    fencing_epoch: u64,
    job_id: &str,
    account: &str,
    actual: i64,
    terminal_digest: &str,
) -> Result<RecoveryAction, LedgerError> {
    if g.job_disposition(job_id).is_some() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    if !g.job_funded_start(job_id) {
        return Ok(RecoveryAction::Skipped);
    }
    if g.active_job_count() == 0 || g.job_reserved_total(job_id).is_none() {
        return Ok(RecoveryAction::AlreadyTerminal);
    }
    let reserved = g.job_reserved_total(job_id).map(|m| m.0).unwrap_or(0);
    match g.settle_capped_as_fenced(
        fencing_epoch,
        OperationKey(format!("force_settle:{job_id}")),
        job_id,
        account,
        actual,
        reserved,
        terminal_digest,
        "force_settled",
    )? {
        true => Ok(RecoveryAction::Released),
        false => Ok(RecoveryAction::AlreadyTerminal),
    }
}

/// Classify a start_authorized job that never reached a provider terminal.
/// Does not move money — ops must settle or force-release via explicit review.
pub fn recover_start_authorized_held(
    ledger: &Arc<Mutex<MemoryLedger>>,
    job_id: &str,
) -> Result<RecoveryAction, String> {
    let g = ledger.lock().map_err(|e| e.to_string())?;
    Ok(classify_held_job(&g, job_id))
}

/// Pure held-job classifier shared by recovery helpers and admin HTTP (DECISIONS #42).
pub fn classify_held_job(ledger: &MemoryLedger, job_id: &str) -> RecoveryAction {
    if ledger.job_disposition(job_id).is_some() || ledger.job_reserved_total(job_id).is_none() {
        return RecoveryAction::AlreadyTerminal;
    }
    if !ledger.job_funded_start(job_id) {
        return RecoveryAction::Skipped;
    }
    if ledger.active_job_count() == 0 {
        return RecoveryAction::AlreadyTerminal;
    }
    RecoveryAction::HeldForReview
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
            g.mark_start_authorized("j1", "a").unwrap();
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
            g.mark_start_authorized("j1", "a").unwrap();
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
            g.mark_start_authorized("j1", "a").unwrap();
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
        assert_eq!(g.job_disposition("j1"), Some("force_settled"));
    }

    #[test]
    fn force_settle_held_second_call_is_already_terminal() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1", "a").unwrap();
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
    fn held_review_after_force_settle_is_already_terminal() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1", "a").unwrap();
        }
        assert_eq!(
            force_settle_held(&led, "j1", "a", 40_000, "force-d1").unwrap(),
            RecoveryAction::Released
        );
        assert_eq!(
            recover_start_authorized_held(&led, "j1").unwrap(),
            RecoveryAction::AlreadyTerminal
        );
        assert_eq!(led.lock().unwrap().balance("a").0, 960_000);
    }

    #[test]
    fn classify_held_job_covers_terminal_skipped_and_held() {
        let mut led = MemoryLedger::default();
        assert_eq!(
            classify_held_job(&led, "missing"),
            RecoveryAction::AlreadyTerminal
        );
        led.credit("a", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        assert_eq!(classify_held_job(&led, "j"), RecoveryAction::Skipped);
        led.mark_start_authorized("j", "a").unwrap();
        assert_eq!(classify_held_job(&led, "j"), RecoveryAction::HeldForReview);
        led.settle_capped_as(
            OperationKey("s".into()),
            "j",
            "a",
            10_000,
            100_000,
            "d",
            "force_settled",
        )
        .unwrap();
        assert_eq!(
            classify_held_job(&led, "j"),
            RecoveryAction::AlreadyTerminal
        );
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
    fn force_settle_held_clamps_actual_above_reservation() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve(OperationKey("r".into()), "j1", "a", 100_000)
                .unwrap();
            g.mark_start_authorized("j1", "a").unwrap();
        }
        assert_eq!(
            force_settle_held(&led, "j1", "a", 9_999_999, "force-over").unwrap(),
            RecoveryAction::Released
        );
        let g = led.lock().unwrap();
        // Charged full reservation; no refund.
        assert_eq!(g.balance("a").0, 900_000);
        assert_eq!(g.active_job_count(), 0);
    }

    #[test]
    fn force_settle_op_key_binds_clamped_charge() {
        // DECISIONS #148: OperationRecord.amount is the clamped charge (SQL c.amount),
        // so two oversize actuals that clamp identically only conflict on job_id/digest.
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r1".into()), "j1", "a", 100_000)
            .unwrap();
        led.mark_start_authorized("j1", "a").unwrap();
        assert!(led
            .settle_capped_as(
                OperationKey("fs-shared".into()),
                "j1",
                "a",
                150_000,
                100_000,
                "d1",
                "force_settled",
            )
            .unwrap());
        led.reserve(OperationKey("r2".into()), "j2", "a", 100_000)
            .unwrap();
        led.mark_start_authorized("j2", "a").unwrap();
        // Same op key, different job — Conflict (not silent charge).
        assert!(matches!(
            led.settle_capped_as(
                OperationKey("fs-shared".into()),
                "j2",
                "a",
                200_000,
                100_000,
                "d2",
                "force_settled",
            ),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.active_job_count(), 1);
        // 5M - j1 reserve 100k - j1 charge 100k (no refund) - j2 reserve 100k = 4.8M
        assert_eq!(led.balance("a").0, 4_800_000);
    }

    #[test]
    fn held_start_authorized_count_tracks_holds() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j1", "a", 100_000)
            .unwrap();
        assert_eq!(led.held_start_authorized_count(), 0);
        led.mark_start_authorized("j1", "a").unwrap();
        assert_eq!(led.held_start_authorized_count(), 1);
        assert_eq!(led.held_start_authorized_job_ids(), vec!["j1".to_string()]);
    }

    #[test]
    fn force_settle_held_fenced_refuses_wrong_epoch() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve_with_epoch(OperationKey("r".into()), "j1", "a", 100_000, 7)
                .unwrap();
            g.mark_start_authorized_fenced(7, "j1", "a").unwrap();
        }
        let err = force_settle_held_fenced(&led, 9, "j1", "a", 40_000, "force-ep")
            .unwrap_err();
        assert!(err.contains("ownership"), "err={err}");
        assert_eq!(led.lock().unwrap().held_start_authorized_count(), 1);
        assert_eq!(
            force_settle_held_fenced(&led, 7, "j1", "a", 40_000, "force-ep").unwrap(),
            RecoveryAction::Released
        );
        assert_eq!(led.lock().unwrap().balance("a").0, 960_000);
    }

    #[test]
    fn recover_undispatched_fenced_refuses_wrong_epoch() {
        let led = Arc::new(Mutex::new(MemoryLedger::default()));
        {
            let mut g = led.lock().unwrap();
            g.credit("a", 1_000_000, 0).unwrap();
            g.reserve_with_epoch(OperationKey("r".into()), "j1", "a", 100_000, 3)
                .unwrap();
        }
        let err = recover_undispatched_fenced(&led, 8, "j1", "a").unwrap_err();
        assert!(err.contains("ownership"), "err={err}");
        assert_eq!(led.lock().unwrap().active_job_count(), 1);
        assert_eq!(
            recover_undispatched_fenced(&led, 3, "j1", "a").unwrap(),
            RecoveryAction::Released
        );
        assert_eq!(led.lock().unwrap().balance("a").0, 1_000_000);
    }
}
