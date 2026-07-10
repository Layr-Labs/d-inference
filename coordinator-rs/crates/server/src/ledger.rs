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
}

/// In-memory ledger for unit tests and warm-plane development without Postgres.
#[derive(Default)]
pub struct MemoryLedger {
    balances: std::collections::HashMap<String, (i64, i64)>, // total, withdrawable
    ops: std::collections::HashSet<String>,
    jobs: std::collections::HashMap<String, ReservationProvenance>,
}

impl MemoryLedger {
    pub fn credit(&mut self, account: &str, total: i64, withdrawable: i64) {
        let e = self.balances.entry(account.to_string()).or_insert((0, 0));
        e.0 += total;
        e.1 += withdrawable;
    }

    pub fn reserve(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        amount: i64,
    ) -> Result<ReserveResult, LedgerError> {
        if !self.ops.insert(op.0.clone()) {
            let provenance = self
                .jobs
                .get(job_id)
                .cloned()
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
        self.jobs.insert(job_id.to_string(), provenance.clone());
        Ok(ReserveResult {
            job_id: job_id.to_string(),
            provenance,
            applied: true,
        })
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
        let Some(prov) = self.jobs.remove(job_id) else {
            return Ok(false);
        };
        let e = self.balances.entry(account.to_string()).or_insert((0, 0));
        e.0 += prov.total.0;
        e.1 += prov.withdrawable.0;
        Ok(true)
    }

    pub fn balance(&self, account: &str) -> (i64, i64) {
        self.balances.get(account).copied().unwrap_or((0, 0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reserve_consumes_nonwithdrawable_first() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 0);
        led.credit("a", 5_000_000, 5_000_000);
        let res = led
            .reserve(
                OperationKey("op1".into()),
                "j1",
                "a",
                12_000_000,
            )
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
        led.credit("a", 5_000_000, 0);
        let r1 = led
            .reserve(OperationKey("op".into()), "j", "a", 1_000_000)
            .unwrap();
        let r2 = led
            .reserve(OperationKey("op".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(r1.applied && !r2.applied);
        assert_eq!(led.balance("a").0, 4_000_000);
    }
}
