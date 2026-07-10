//! Ledger service stubs — SQLx wiring in later M4 commits.
//!
//! Operation keys make reserve/resize/settle/release idempotent.

use darkbloom_core::MicroUsd;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct OperationKey(pub String);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReservationProvenance {
    pub total: MicroUsd,
    pub withdrawable: MicroUsd,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReserveResult {
    pub job_id: String,
    pub provenance: ReservationProvenance,
    pub applied: bool,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum LedgerError {
    #[error("insufficient balance")]
    InsufficientBalance,
    #[error("ownership lost")]
    OwnershipLost,
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("invalid amount")]
    InvalidAmount,
}

/// In-memory ledger for unit tests and warm-plane development without Postgres.
#[derive(Default)]
pub struct MemoryLedger {
    balances: std::collections::HashMap<String, (i64, i64)>, // total, withdrawable
    ops: std::collections::HashSet<String>,
    jobs: std::collections::HashMap<String, JobRecord>,
    attempts: std::collections::HashMap<String, AttemptRecord>,
    terminals: std::collections::HashMap<String, String>, // digest -> disposition
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRecord {
    pub account_id: String,
    pub state: String,
    pub provenance: ReservationProvenance,
    pub funded_start: bool,
    pub disposition: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttemptRecord {
    pub job_id: String,
    pub provider_id: String,
    pub state: String,
}

impl MemoryLedger {
    pub fn credit(&mut self, account: &str, total: i64, withdrawable: i64) -> Result<(), LedgerError> {
        if total < 0 || withdrawable < 0 {
            return Err(LedgerError::InvalidAmount);
        }
        if withdrawable > total {
            return Err(LedgerError::Conflict(
                "withdrawable exceeds total credit".into(),
            ));
        }
        let e = self.balances.entry(account.to_string()).or_insert((0, 0));
        e.0 += total;
        e.1 += withdrawable;
        Ok(())
    }

    pub fn reserve(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        amount: i64,
    ) -> Result<ReserveResult, LedgerError> {
        if amount <= 0 {
            return Err(LedgerError::InvalidAmount);
        }
        if !self.ops.insert(op.0.clone()) {
            let provenance = self
                .jobs
                .get(job_id)
                .map(|j| j.provenance.clone())
                .unwrap_or(ReservationProvenance {
                    total: MicroUsd(amount),
                    withdrawable: MicroUsd(0),
                });
            return Ok(ReserveResult {
                job_id: job_id.to_string(),
                provenance,
                applied: false,
            });
        }
        let (bal, wdr) = self.balances.entry(account.to_string()).or_insert((0, 0));
        if *bal < amount {
            self.ops.remove(&op.0);
            return Err(LedgerError::InsufficientBalance);
        }
        let non_wdr = (*bal - *wdr).max(0);
        let reserved_wdr = (amount - non_wdr).max(0).min(*wdr);
        *bal -= amount;
        *wdr -= reserved_wdr;
        let provenance = ReservationProvenance {
            total: MicroUsd(amount),
            withdrawable: MicroUsd(reserved_wdr),
        };
        self.jobs.insert(
            job_id.to_string(),
            JobRecord {
                account_id: account.to_string(),
                state: "reserved".into(),
                provenance: provenance.clone(),
                funded_start: false,
                disposition: None,
            },
        );
        Ok(ReserveResult {
            job_id: job_id.to_string(),
            provenance,
            applied: true,
        })
    }

    pub fn mark_start_authorized(&mut self, job_id: &str) -> Result<(), LedgerError> {
        let job = self
            .jobs
            .get_mut(job_id)
            .ok_or_else(|| LedgerError::Conflict("unknown job".into()))?;
        if job.funded_start {
            return Err(LedgerError::Conflict("already start_authorized".into()));
        }
        job.funded_start = true;
        job.state = "start_authorized".into();
        Ok(())
    }

    pub fn record_attempt(
        &mut self,
        attempt_id: &str,
        job_id: &str,
        provider_id: &str,
        state: &str,
    ) {
        self.attempts.insert(
            attempt_id.to_string(),
            AttemptRecord {
                job_id: job_id.to_string(),
                provider_id: provider_id.to_string(),
                state: state.to_string(),
            },
        );
    }

    /// Settle: charge `actual`, refund unused provenance, mark terminal.
    /// Enforces at most one funded start / one settle per job via op key.
    /// Settle charging min(actual, billable_cap) when a chunk checkpoint caps tokens.
    pub fn settle_capped(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        billable_cap: i64,
        terminal_digest: &str,
    ) -> Result<bool, LedgerError> {
        let charge = actual.min(billable_cap).max(0);
        self.settle(op, job_id, account, charge, terminal_digest)
    }

    pub fn settle(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        terminal_digest: &str,
    ) -> Result<bool, LedgerError> {
        if actual < 0 {
            return Err(LedgerError::InvalidAmount);
        }
        if let Some(prev) = self.terminals.get(terminal_digest) {
            // Idempotent only when replaying the same settled job digest.
            if prev == job_id {
                return Ok(false);
            }
            return Err(LedgerError::Conflict(format!(
                "terminal digest conflict: already bound to {prev}"
            )));
        }
        if !self.ops.insert(op.0.clone()) {
            return Ok(false);
        }
        let job = self
            .jobs
            .get_mut(job_id)
            .ok_or_else(|| LedgerError::Conflict("unknown job".into()))?;
        if job.disposition.is_some() {
            return Ok(false);
        }
        let reserved = job.provenance.total.0;
        if actual > reserved {
            return Err(LedgerError::Conflict("actual exceeds reservation".into()));
        }
        let refund = reserved - actual;
        let non_wdr_reserved = reserved - job.provenance.withdrawable.0;
        let consumed_wdr = (actual - non_wdr_reserved).max(0).min(job.provenance.withdrawable.0);
        let refund_wdr = job.provenance.withdrawable.0 - consumed_wdr;

        let e = self.balances.entry(account.to_string()).or_insert((0, 0));
        e.0 += refund;
        e.1 += refund_wdr;

        job.state = "settled".into();
        job.disposition = Some("settled".into());
        self.terminals
            .insert(terminal_digest.to_string(), job_id.to_string());
        Ok(true)
    }

    pub fn release(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
    ) -> Result<bool, LedgerError> {
        if !self.ops.insert(op.0.clone()) {
            return Ok(false);
        }
        let Some(job) = self.jobs.get_mut(job_id) else {
            return Ok(false);
        };
        if job.disposition.is_some() {
            return Ok(false);
        }
        let prov = job.provenance.clone();
        let e = self.balances.entry(account.to_string()).or_insert((0, 0));
        e.0 += prov.total.0;
        e.1 += prov.withdrawable.0;
        job.state = "released".into();
        job.disposition = Some("released".into());
        Ok(true)
    }

    pub fn balance(&self, account: &str) -> (i64, i64) {
        self.balances.get(account).copied().unwrap_or((0, 0))
    }

    pub fn job_funded_start(&self, job_id: &str) -> bool {
        self.jobs.get(job_id).map(|j| j.funded_start).unwrap_or(false)
    }

    pub fn job_reserved_total(&self, job_id: &str) -> Option<MicroUsd> {
        self.jobs.get(job_id).map(|j| j.provenance.total)
    }

    pub fn attempt(&self, attempt_id: &str) -> Option<&AttemptRecord> {
        self.attempts.get(attempt_id)
    }

    pub fn active_job_count(&self) -> usize {
        self.jobs
            .values()
            .filter(|j| j.disposition.is_none())
            .count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reserve_consumes_nonwithdrawable_first() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 0).unwrap();
        led.credit("a", 5_000_000, 5_000_000).unwrap();
        let res = led
            .reserve(OperationKey("op1".into()), "j1", "a", 12_000_000)
            .unwrap();
        assert!(res.applied);
        assert_eq!(res.provenance.withdrawable.0, 2_000_000);
        assert_eq!(led.balance("a"), (3_000_000, 3_000_000));
        assert!(led
            .release(OperationKey("rel1".into()), "j1", "a")
            .unwrap());
        assert_eq!(led.balance("a"), (15_000_000, 5_000_000));
    }

    #[test]
    fn reserve_idempotent_on_operation_key() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        let r1 = led
            .reserve(OperationKey("op".into()), "j", "a", 1_000_000)
            .unwrap();
        let r2 = led
            .reserve(OperationKey("op".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(r1.applied && !r2.applied);
        assert_eq!(led.balance("a").0, 4_000_000);
    }

    #[test]
    fn settle_refunds_unused_and_is_idempotent() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 4_000_000).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        assert!(led
            .mark_start_authorized("j")
            .unwrap_err()
            .to_string()
            .contains("already"));
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 1_000_000, "td1")
            .unwrap());
        assert!(!led
            .settle(OperationKey("s".into()), "j", "a", 1_000_000, "td1")
            .unwrap());
        // reserved 5M, charged 1M → refund 4M; start bal 10M → 5M after reserve → 9M after settle
        assert_eq!(led.balance("a").0, 9_000_000);
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn at_most_one_funded_start_per_job() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        assert!(led.job_funded_start("j"));
        assert!(matches!(
            led.mark_start_authorized("j"),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn settle_capped_respects_billable_cap() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        // Provider claims 4M but checkpoint only accepted 1M worth.
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                4_000_000,
                1_000_000,
                "td"
            )
            .unwrap());
        // reserved 5M, charged 1M → refund 4M → bal 10M-5M+4M = 9M
        assert_eq!(led.balance("a").0, 9_000_000);
    }

    #[test]
    fn release_is_idempotent_on_operation_key() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 2_000_000)
            .unwrap();
        assert!(led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
        // Second release with same op key is a no-op.
        assert!(!led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
    }

    #[test]
    fn settle_rejects_conflicting_terminal_digest() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r1".into()), "j1", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j1").unwrap();
        assert!(led
            .settle(OperationKey("s1".into()), "j1", "a", 500_000, "digest-a")
            .unwrap());
        // Reuse same digest on a different job → conflict.
        led.reserve(OperationKey("r2".into()), "j2", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j2").unwrap();
        assert!(matches!(
            led.settle(OperationKey("s2".into()), "j2", "a", 500_000, "digest-a"),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn settle_same_job_digest_replay_is_idempotent() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 400_000, "d1")
            .unwrap());
        // Same op key + same digest → idempotent false.
        assert!(!led
            .settle(OperationKey("s".into()), "j", "a", 400_000, "d1")
            .unwrap());
        // Different op key but same digest+job → still idempotent (digest bound to job).
        assert!(!led
            .settle(OperationKey("s2".into()), "j", "a", 400_000, "d1")
            .unwrap());
        // reserved 1M, charged 400k → refund 600k → bal = 5M-1M+600k = 4.6M
        assert_eq!(led.balance("a").0, 4_600_000);
    }

    #[test]
    fn settle_rejects_actual_exceeding_reservation() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        assert!(matches!(
            led.settle(OperationKey("s".into()), "j", "a", 1_000_001, "d-over"),
            Err(LedgerError::Conflict(_))
        ));
        // Balance still held in reservation (not settled, not released).
        assert_eq!(led.balance("a").0, 4_000_000);
        assert_eq!(led.active_job_count(), 1);
    }

    #[test]
    fn reserve_fails_on_insufficient_balance() {
        let mut led = MemoryLedger::default();
        led.credit("a", 100_000, 0).unwrap();
        assert_eq!(
            led.reserve(OperationKey("r".into()), "j", "a", 100_001)
                .unwrap_err(),
            LedgerError::InsufficientBalance
        );
        assert_eq!(led.balance("a").0, 100_000);
        assert_eq!(led.active_job_count(), 0);
        // Op key must not stick after failed reserve.
        assert!(led
            .reserve(OperationKey("r".into()), "j", "a", 50_000)
            .unwrap()
            .applied);
    }

    #[test]
    fn mark_start_authorized_unknown_job_conflicts() {
        let mut led = MemoryLedger::default();
        assert!(matches!(
            led.mark_start_authorized("missing"),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn release_unknown_job_is_noop() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        assert!(!led
            .release(OperationKey("rel".into()), "no-such-job", "a")
            .unwrap());
        assert_eq!(led.balance("a").0, 1_000_000);
    }

    #[test]
    fn settle_unknown_job_conflicts() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        assert!(matches!(
            led.settle(OperationKey("s".into()), "missing", "a", 1, "d"),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn record_attempt_is_retrievable() {
        let mut led = MemoryLedger::default();
        led.record_attempt("att-1", "job-1", "prov-1", "started");
        let a = led.attempt("att-1").expect("attempt");
        assert_eq!(a.job_id, "job-1");
        assert_eq!(a.provider_id, "prov-1");
        assert_eq!(a.state, "started");
        assert!(led.attempt("missing").is_none());
    }

    #[test]
    fn release_after_settle_is_noop() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 400_000, "d1")
            .unwrap());
        let bal_after_settle = led.balance("a").0;
        // Release after disposition must not double-refund.
        assert!(!led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        assert_eq!(led.balance("a").0, bal_after_settle);
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn settle_after_release_is_noop() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
        // Settle after release: disposition already set → noop false.
        assert!(!led
            .settle(OperationKey("s".into()), "j", "a", 100_000, "d1")
            .unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
    }

    #[test]
    fn job_reserved_total_tracks_provenance_until_disposition() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 2_000_000).unwrap();
        assert!(led.job_reserved_total("j").is_none());
        let res = led
            .reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        assert!(res.applied);
        assert_eq!(led.job_reserved_total("j").unwrap().0, 3_000_000);
        // After settle, job row remains but disposition is set; reserved total still readable.
        led.mark_start_authorized("j").unwrap();
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 1_000_000, "d1")
            .unwrap());
        assert_eq!(led.job_reserved_total("j").unwrap().0, 3_000_000);
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn credit_accumulates_total_and_withdrawable() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        led.credit("a", 500_000, 500_000).unwrap();
        assert_eq!(led.balance("a"), (1_500_000, 500_000));
    }

    #[test]
    fn reserve_rejects_zero_or_negative_amount() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        assert_eq!(
            led.reserve(OperationKey("r0".into()), "j", "a", 0)
                .unwrap_err(),
            LedgerError::InvalidAmount
        );
        assert_eq!(
            led.reserve(OperationKey("r-1".into()), "j", "a", -1)
                .unwrap_err(),
            LedgerError::InvalidAmount
        );
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn settle_rejects_negative_actual() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        assert_eq!(
            led.settle(OperationKey("s".into()), "j", "a", -1, "d")
                .unwrap_err(),
            LedgerError::InvalidAmount
        );
    }

    #[test]
    fn settle_capped_zero_billable_refunds_full_reservation() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        // Provider claimed 800k but pipe accepted 0 tokens → charge 0, refund all.
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                800_000,
                0,
                "d-zero"
            )
            .unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn settle_exact_reservation_charges_full_amount() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 1_000_000).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 2_000_000)
            .unwrap();
        // Non-wdr first: reserved_wdr = max(0, 2M - 4M) = 0
        assert_eq!(led.balance("a"), (3_000_000, 1_000_000));
        led.mark_start_authorized("j").unwrap();
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 2_000_000, "d-full")
            .unwrap());
        // Full charge, zero refund.
        assert_eq!(led.balance("a"), (3_000_000, 1_000_000));
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn settle_capped_never_exceeds_actual() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        // Cap higher than actual → charge actual only.
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                300_000,
                900_000,
                "d-cap"
            )
            .unwrap());
        // reserved 1M, charged 300k → refund 700k → bal = 5M-1M+700k = 4.7M
        assert_eq!(led.balance("a").0, 4_700_000);
    }

    #[test]
    fn reserve_can_consume_all_withdrawable() {
        let mut led = MemoryLedger::default();
        // Pure withdrawable balance (earnings).
        led.credit("a", 2_000_000, 2_000_000).unwrap();
        let res = led
            .reserve(OperationKey("r".into()), "j", "a", 2_000_000)
            .unwrap();
        assert!(res.applied);
        assert_eq!(res.provenance.total.0, 2_000_000);
        assert_eq!(res.provenance.withdrawable.0, 2_000_000);
        assert_eq!(led.balance("a"), (0, 0));
        // Release restores withdrawable exactly.
        assert!(led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        assert_eq!(led.balance("a"), (2_000_000, 2_000_000));
    }

    #[test]
    fn reserve_zero_withdrawable_when_non_wdr_covers_amount() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 1_000_000).unwrap(); // 4M non-wdr, 1M wdr
        let res = led
            .reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        assert_eq!(res.provenance.withdrawable.0, 0);
        assert_eq!(led.balance("a"), (2_000_000, 1_000_000));
    }

    #[test]
    fn settle_restores_unused_withdrawable_provenance_exactly() {
        let mut led = MemoryLedger::default();
        // 3M non-wdr + 2M wdr
        led.credit("a", 3_000_000, 0).unwrap();
        led.credit("a", 2_000_000, 2_000_000).unwrap();
        // Reserve 4M → consumes 3M non-wdr + 1M wdr
        let res = led
            .reserve(OperationKey("r".into()), "j", "a", 4_000_000)
            .unwrap();
        assert_eq!(res.provenance.withdrawable.0, 1_000_000);
        assert_eq!(led.balance("a"), (1_000_000, 1_000_000));
        led.mark_start_authorized("j").unwrap();
        // Charge 500k (all from non-wdr portion of reservation) → refund 3.5M
        // of which refund_wdr = reserved_wdr - consumed_wdr = 1M - 0 = 1M
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 500_000, "d-wdr")
            .unwrap());
        // bal: 1M + 3.5M refund = 4.5M; wdr: 1M + 1M refund_wdr = 2M
        assert_eq!(led.balance("a"), (4_500_000, 2_000_000));
    }

    #[test]
    fn settle_consumes_reserved_withdrawable_when_charge_exceeds_non_wdr() {
        let mut led = MemoryLedger::default();
        // 1M non-wdr + 3M wdr
        led.credit("a", 1_000_000, 0).unwrap();
        led.credit("a", 3_000_000, 3_000_000).unwrap();
        // Reserve 3M → 1M non-wdr + 2M wdr reserved
        let res = led
            .reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        assert_eq!(res.provenance.withdrawable.0, 2_000_000);
        assert_eq!(led.balance("a"), (1_000_000, 1_000_000));
        led.mark_start_authorized("j").unwrap();
        // Charge 2.5M → consumes all 1M non-wdr + 1.5M of reserved wdr
        // refund = 0.5M, refund_wdr = 2M - 1.5M = 0.5M
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 2_500_000, "d-cw")
            .unwrap());
        // bal: 1M + 0.5M = 1.5M; wdr: 1M + 0.5M = 1.5M
        assert_eq!(led.balance("a"), (1_500_000, 1_500_000));
    }

    #[test]
    fn active_job_count_tracks_multiple_concurrent_jobs() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 0).unwrap();
        assert_eq!(led.active_job_count(), 0);
        led.reserve(OperationKey("r1".into()), "j1", "a", 1_000_000)
            .unwrap();
        led.reserve(OperationKey("r2".into()), "j2", "a", 1_000_000)
            .unwrap();
        led.reserve(OperationKey("r3".into()), "j3", "a", 1_000_000)
            .unwrap();
        assert_eq!(led.active_job_count(), 3);
        led.mark_start_authorized("j1").unwrap();
        assert!(led
            .settle(OperationKey("s1".into()), "j1", "a", 500_000, "d1")
            .unwrap());
        assert_eq!(led.active_job_count(), 2);
        assert!(led
            .release(OperationKey("rel2".into()), "j2", "a")
            .unwrap());
        assert_eq!(led.active_job_count(), 1);
        assert!(led
            .release(OperationKey("rel3".into()), "j3", "a")
            .unwrap());
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn settle_capped_negative_billable_cap_clamps_to_zero() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j").unwrap();
        // Negative cap must clamp to zero charge (full refund), not panic or over-charge.
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                800_000,
                -50,
                "d-neg-cap"
            )
            .unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn record_attempt_overwrites_same_attempt_id() {
        let mut led = MemoryLedger::default();
        led.record_attempt("att-1", "job-1", "prov-1", "started");
        led.record_attempt("att-1", "job-1", "prov-1", "completed");
        let a = led.attempt("att-1").expect("attempt");
        assert_eq!(a.state, "completed");
        assert_eq!(a.job_id, "job-1");
    }

    #[test]
    fn job_funded_start_remains_true_after_settle() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(!led.job_funded_start("j"));
        led.mark_start_authorized("j").unwrap();
        assert!(led.job_funded_start("j"));
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 400_000, "d1")
            .unwrap());
        // Funded-start flag is sticky for audit even after disposition.
        assert!(led.job_funded_start("j"));
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn job_funded_start_false_for_unknown_and_released() {
        let mut led = MemoryLedger::default();
        assert!(!led.job_funded_start("missing"));
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(!led.job_funded_start("j"));
        assert!(led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        // Never start-authorized → still false after release.
        assert!(!led.job_funded_start("j"));
    }

    #[test]
    fn settle_empty_terminal_digest_still_binds_and_blocks_reuse() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r1".into()), "j1", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j1").unwrap();
        // Empty digest is allowed but still unique across jobs.
        assert!(led
            .settle(OperationKey("s1".into()), "j1", "a", 400_000, "")
            .unwrap());
        led.reserve(OperationKey("r2".into()), "j2", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j2").unwrap();
        assert!(matches!(
            led.settle(OperationKey("s2".into()), "j2", "a", 400_000, ""),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn reserve_idempotent_returns_existing_provenance() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 2_000_000).unwrap();
        let r1 = led
            .reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        assert!(r1.applied);
        let r2 = led
            .reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        assert!(!r2.applied);
        assert_eq!(r2.provenance.total.0, r1.provenance.total.0);
        assert_eq!(r2.provenance.withdrawable.0, r1.provenance.withdrawable.0);
        // Balance unchanged by idempotent replay.
        assert_eq!(led.balance("a").0, 2_000_000);
    }
    #[test]
    fn credit_rejects_negative_amounts() {
        let mut led = MemoryLedger::default();
        assert_eq!(
            led.credit("a", -1, 0).unwrap_err(),
            LedgerError::InvalidAmount
        );
        assert_eq!(
            led.credit("a", 1_000_000, -1).unwrap_err(),
            LedgerError::InvalidAmount
        );
        assert_eq!(led.balance("a"), (0, 0));
    }

    #[test]
    fn credit_rejects_withdrawable_exceeding_total() {
        let mut led = MemoryLedger::default();
        assert!(matches!(
            led.credit("a", 100, 101),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.balance("a"), (0, 0));
    }
}
