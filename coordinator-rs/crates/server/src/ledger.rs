//! Ledger service stubs — SQLx wiring in later M4 commits.
//!
//! Operation keys make reserve/resize/settle/release idempotent.
//! Replay is idempotent only when the recorded parameters match
//! (DECISIONS #34); mismatched reuse is Conflict.

use darkbloom_core::MicroUsd;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct OperationKey(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReservationProvenance {
    pub total: MicroUsd,
    pub withdrawable: MicroUsd,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

/// Admin cutover chaining snapshot (DECISIONS #123–#130).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CutoverStatus {
    pub accounts_needing_cutover: Vec<String>,
    pub needs_adopt_count: usize,
    pub active_jobs: usize,
    pub held_start_authorized: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OperationRecord {
    op_type: &'static str,
    job_id: String,
    account: String,
    amount: i64,
    digest: Option<String>,
    billable_cap: Option<i64>,
}

enum OpClaim {
    Fresh,
    Replay,
}

/// In-memory ledger for unit tests and warm-plane development without Postgres.
#[derive(Default)]
pub struct MemoryLedger {
    balances: std::collections::HashMap<String, (i64, i64)>, // total, withdrawable
    ops: std::collections::HashMap<String, OperationRecord>,
    jobs: std::collections::HashMap<String, JobRecord>,
    attempts: std::collections::HashMap<String, AttemptRecord>,
    terminals: std::collections::HashMap<String, String>, // digest -> job_id
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobRecord {
    pub account_id: String,
    pub state: String,
    pub provenance: ReservationProvenance,
    pub funded_start: bool,
    pub disposition: Option<String>,
    /// Ownership fencing epoch at reserve time (0 = unbound). DECISIONS #52.
    #[serde(default)]
    pub fencing_epoch: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttemptRecord {
    pub job_id: String,
    pub provider_id: String,
    pub state: String,
}

impl MemoryLedger {
    fn claim_op(&mut self, key: &str, record: OperationRecord) -> Result<OpClaim, LedgerError> {
        match self.ops.get(key) {
            Some(prev) if prev == &record => Ok(OpClaim::Replay),
            Some(_) => Err(LedgerError::Conflict(format!(
                "operation key {key} reused with different parameters"
            ))),
            None => {
                self.ops.insert(key.to_string(), record);
                Ok(OpClaim::Fresh)
            }
        }
    }

    fn unclaim_op(&mut self, key: &str) {
        self.ops.remove(key);
    }

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
        let record = OperationRecord {
            op_type: "reserve",
            job_id: job_id.to_string(),
            account: account.to_string(),
            amount,
            digest: None,
            billable_cap: None,
        };
        match self.claim_op(&op.0, record)? {
            OpClaim::Replay => {
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
            OpClaim::Fresh => {}
        }
        // Job IDs are single-use. A disposed or still-active job must not be
        // overwritten by a later reserve under a different operation key.
        if let Some(existing) = self.jobs.get(job_id) {
            let state = existing.state.clone();
            let disposition = existing.disposition.clone();
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict(format!(
                "job {job_id} already exists (state={state}, disposition={disposition:?})"
            )));
        }
        let (bal, wdr) = self.balances.entry(account.to_string()).or_insert((0, 0));
        if *bal < amount {
            self.unclaim_op(&op.0);
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
                fencing_epoch: 0,
            },
        );
        Ok(ReserveResult {
            job_id: job_id.to_string(),
            provenance,
            applied: true,
        })
    }

    /// Reserve and bind fencing epoch atomically (DECISIONS #55).
    /// Avoids a window where a reserved job is unbound (`fencing_epoch=0`).
    pub fn reserve_with_epoch(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        amount: i64,
        fencing_epoch: u64,
    ) -> Result<ReserveResult, LedgerError> {
        let result = self.reserve(op, job_id, account, amount)?;
        if result.applied {
            // Fresh reserve — bind epoch in the same critical section.
            if let Some(job) = self.jobs.get_mut(job_id) {
                job.fencing_epoch = fencing_epoch;
            }
        } else if fencing_epoch != 0 {
            // Idempotent replay: refuse if a prior bind used a different epoch.
            self.require_fencing_epoch(job_id, fencing_epoch)?;
        }
        Ok(result)
    }

    /// Bind the job to the coordinator fencing epoch at reserve time (DECISIONS #52).
    pub fn bind_fencing_epoch(&mut self, job_id: &str, epoch: u64) -> Result<(), LedgerError> {
        let job = self
            .jobs
            .get_mut(job_id)
            .ok_or_else(|| LedgerError::Conflict("unknown job".into()))?;
        if job.disposition.is_some() {
            return Err(LedgerError::Conflict(format!(
                "job {job_id} already disposed"
            )));
        }
        job.fencing_epoch = epoch;
        Ok(())
    }

    /// Refuse money moves when the job was reserved under a different fencing epoch.
    pub fn require_fencing_epoch(&self, job_id: &str, epoch: u64) -> Result<(), LedgerError> {
        let job = self
            .jobs
            .get(job_id)
            .ok_or_else(|| LedgerError::Conflict("unknown job".into()))?;
        if job.fencing_epoch != 0 && job.fencing_epoch != epoch {
            return Err(LedgerError::OwnershipLost);
        }
        Ok(())
    }

    /// Rebind an active job to the current coordinator fencing epoch (DECISIONS #66).
    /// Used after ownership re-acquire so orphaned jobs can be recovered/force-settled.
    pub fn adopt_fencing_epoch(&mut self, job_id: &str, epoch: u64) -> Result<u64, LedgerError> {
        let job = self
            .jobs
            .get_mut(job_id)
            .ok_or_else(|| LedgerError::Conflict("unknown job".into()))?;
        if job.disposition.is_some() {
            return Err(LedgerError::Conflict(format!(
                "job {job_id} already disposed"
            )));
        }
        let prev = job.fencing_epoch;
        job.fencing_epoch = epoch;
        Ok(prev)
    }

    pub fn job_fencing_epoch(&self, job_id: &str) -> Option<u64> {
        self.jobs.get(job_id).map(|j| j.fencing_epoch)
    }

    /// Mark `start_authorized` only when `account` owns the job (DECISIONS #24/#31).
    pub fn mark_start_authorized(
        &mut self,
        job_id: &str,
        account: &str,
    ) -> Result<(), LedgerError> {
        let job = self
            .jobs
            .get_mut(job_id)
            .ok_or_else(|| LedgerError::Conflict("unknown job".into()))?;
        if job.account_id != account {
            return Err(LedgerError::Conflict(format!(
                "account mismatch for job {job_id}"
            )));
        }
        if job.disposition.is_some() {
            return Err(LedgerError::Conflict(format!(
                "job {job_id} already disposed"
            )));
        }
        if job.funded_start {
            return Err(LedgerError::Conflict("already start_authorized".into()));
        }
        job.funded_start = true;
        job.state = "start_authorized".into();
        Ok(())
    }

    /// Mark start_authorized only when fencing epoch matches (DECISIONS #56).
    pub fn mark_start_authorized_fenced(
        &mut self,
        epoch: u64,
        job_id: &str,
        account: &str,
    ) -> Result<(), LedgerError> {
        self.require_fencing_epoch(job_id, epoch)?;
        self.mark_start_authorized(job_id, account)
    }

    /// Atomically resize the reservation to `new_amount` and mark start_authorized.
    /// Mirrors the one-round-trip Postgres CTE (plan §12 / M4 ledger service).
    /// Idempotent on `op`; conflicts if already authorized or disposed.
    pub fn resize_and_authorize(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        new_amount: i64,
    ) -> Result<ReserveResult, LedgerError> {
        if new_amount <= 0 {
            return Err(LedgerError::InvalidAmount);
        }
        let record = OperationRecord {
            op_type: "resize_authorize",
            job_id: job_id.to_string(),
            account: account.to_string(),
            amount: new_amount,
            digest: None,
            billable_cap: None,
        };
        match self.claim_op(&op.0, record)? {
            OpClaim::Replay => {
                let provenance = self
                    .jobs
                    .get(job_id)
                    .map(|j| j.provenance.clone())
                    .unwrap_or(ReservationProvenance {
                        total: MicroUsd(new_amount),
                        withdrawable: MicroUsd(0),
                    });
                return Ok(ReserveResult {
                    job_id: job_id.to_string(),
                    provenance,
                    applied: false,
                });
            }
            OpClaim::Fresh => {}
        }
        let job = match self.jobs.get(job_id) {
            Some(j) => j,
            None => {
                self.unclaim_op(&op.0);
                return Err(LedgerError::Conflict("unknown job".into()));
            }
        };
        if job.disposition.is_some() {
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict(format!(
                "job {job_id} already disposed"
            )));
        }
        if job.funded_start {
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict("already start_authorized".into()));
        }
        if job.account_id != account {
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict("account mismatch".into()));
        }
        let old_total = job.provenance.total.0;
        let old_wdr = job.provenance.withdrawable.0;
        let delta = new_amount - old_total;

        let (bal, wdr) = self.balances.entry(account.to_string()).or_insert((0, 0));
        let (new_total, new_wdr) = if delta > 0 {
            if *bal < delta {
                self.unclaim_op(&op.0);
                return Err(LedgerError::InsufficientBalance);
            }
            let non_wdr = (*bal - *wdr).max(0);
            let add_wdr = (delta - non_wdr).max(0).min(*wdr);
            *bal -= delta;
            *wdr -= add_wdr;
            (new_amount, old_wdr + add_wdr)
        } else if delta < 0 {
            let refund = -delta;
            // Prefer refunding non-withdrawable first (mirror settle provenance).
            let non_wdr_reserved = old_total - old_wdr;
            let refund_non_wdr = refund.min(non_wdr_reserved);
            let refund_wdr = refund - refund_non_wdr;
            *bal += refund;
            *wdr += refund_wdr;
            (new_amount, old_wdr - refund_wdr)
        } else {
            (old_total, old_wdr)
        };

        let provenance = ReservationProvenance {
            total: MicroUsd(new_total),
            withdrawable: MicroUsd(new_wdr),
        };
        let job = self.jobs.get_mut(job_id).expect("job checked above");
        job.provenance = provenance.clone();
        job.funded_start = true;
        job.state = "start_authorized".into();
        Ok(ReserveResult {
            job_id: job_id.to_string(),
            provenance,
            applied: true,
        })
    }

    /// Resize+authorize only when fencing epoch matches (DECISIONS #56).
    pub fn resize_and_authorize_fenced(
        &mut self,
        epoch: u64,
        op: OperationKey,
        job_id: &str,
        account: &str,
        new_amount: i64,
    ) -> Result<ReserveResult, LedgerError> {
        self.require_fencing_epoch(job_id, epoch)?;
        self.resize_and_authorize(op, job_id, account, new_amount)
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

    /// Settle charging min(actual, billable_cap, reserved) when a chunk checkpoint caps tokens.
    /// Clamping to reservation prevents fail-closed holds when the pipe reports more tokens
    /// than the provisional reservation covered (stream billing kill-boundary).
    pub fn settle_capped(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        billable_cap: i64,
        terminal_digest: &str,
    ) -> Result<bool, LedgerError> {
        self.settle_capped_as(
            op,
            job_id,
            account,
            actual,
            billable_cap,
            terminal_digest,
            "settled",
        )
    }

    /// Like `settle_capped` but records a custom terminal disposition (e.g. force_settled).
    pub fn settle_capped_as(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        billable_cap: i64,
        terminal_digest: &str,
        disposition: &str,
    ) -> Result<bool, LedgerError> {
        let reserved = self
            .jobs
            .get(job_id)
            .map(|j| j.provenance.total.0)
            .unwrap_or(0);
        let charge = actual.min(billable_cap).min(reserved).max(0);
        self.settle_as_inner(
            op,
            job_id,
            account,
            charge,
            terminal_digest,
            disposition,
            Some((actual, billable_cap)),
        )
    }

    /// Settle capped only when the caller's fencing epoch matches (DECISIONS #56).
    pub fn settle_capped_fenced(
        &mut self,
        epoch: u64,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        billable_cap: i64,
        terminal_digest: &str,
    ) -> Result<bool, LedgerError> {
        self.require_fencing_epoch(job_id, epoch)?;
        self.settle_capped(op, job_id, account, actual, billable_cap, terminal_digest)
    }

    /// Force/custom settle capped with fencing epoch check (DECISIONS #56).
    pub fn settle_capped_as_fenced(
        &mut self,
        epoch: u64,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        billable_cap: i64,
        terminal_digest: &str,
        disposition: &str,
    ) -> Result<bool, LedgerError> {
        self.require_fencing_epoch(job_id, epoch)?;
        self.settle_capped_as(
            op,
            job_id,
            account,
            actual,
            billable_cap,
            terminal_digest,
            disposition,
        )
    }

    pub fn settle(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        terminal_digest: &str,
    ) -> Result<bool, LedgerError> {
        self.settle_as(op, job_id, account, actual, terminal_digest, "settled")
    }

    pub fn settle_as(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        actual: i64,
        terminal_digest: &str,
        disposition: &str,
    ) -> Result<bool, LedgerError> {
        self.settle_as_inner(
            op,
            job_id,
            account,
            actual,
            terminal_digest,
            disposition,
            None,
        )
    }

    fn settle_as_inner(
        &mut self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        charge: i64,
        terminal_digest: &str,
        disposition: &str,
        capped_inputs: Option<(i64, i64)>,
    ) -> Result<bool, LedgerError> {
        if charge < 0 {
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
        let (amount, billable_cap, op_type) = match capped_inputs {
            Some((actual, cap)) => (
                actual,
                Some(cap),
                if disposition == "force_settled" {
                    "force_settle"
                } else {
                    "settle_capped"
                },
            ),
            None => (
                charge,
                None,
                if disposition == "force_settled" {
                    "force_settle"
                } else {
                    "settle"
                },
            ),
        };
        let record = OperationRecord {
            op_type,
            job_id: job_id.to_string(),
            account: account.to_string(),
            amount,
            digest: Some(terminal_digest.to_string()),
            billable_cap,
        };
        match self.claim_op(&op.0, record)? {
            OpClaim::Replay => return Ok(false),
            OpClaim::Fresh => {}
        }
        let job = match self.jobs.get_mut(job_id) {
            Some(j) => j,
            None => {
                self.unclaim_op(&op.0);
                return Err(LedgerError::Conflict("unknown job".into()));
            }
        };
        if job.account_id != account {
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict(format!(
                "account mismatch for job {job_id}"
            )));
        }
        if job.disposition.is_some() {
            return Ok(false);
        }
        let reserved = job.provenance.total.0;
        if charge > reserved {
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict("actual exceeds reservation".into()));
        }
        let refund = reserved - charge;
        let non_wdr_reserved = reserved - job.provenance.withdrawable.0;
        let consumed_wdr = (charge - non_wdr_reserved).max(0).min(job.provenance.withdrawable.0);
        let refund_wdr = job.provenance.withdrawable.0 - consumed_wdr;

        let e = self.balances.entry(account.to_string()).or_insert((0, 0));
        e.0 += refund;
        e.1 += refund_wdr;

        job.state = "settled".into();
        job.disposition = Some(disposition.to_string());
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
        // Bind amount to reserved total (SQL release_sql stores j.reserved — DECISIONS #144).
        let reserved = self
            .jobs
            .get(job_id)
            .map(|j| j.provenance.total.0)
            .unwrap_or(0);
        let record = OperationRecord {
            op_type: "release",
            job_id: job_id.to_string(),
            account: account.to_string(),
            amount: reserved,
            digest: None,
            billable_cap: None,
        };
        match self.claim_op(&op.0, record)? {
            OpClaim::Replay => return Ok(false),
            OpClaim::Fresh => {}
        }
        let Some(job) = self.jobs.get_mut(job_id) else {
            self.unclaim_op(&op.0);
            return Ok(false);
        };
        if job.account_id != account {
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict(format!(
                "account mismatch for job {job_id}"
            )));
        }
        if job.disposition.is_some() {
            return Ok(false);
        }
        // Once start is authorized, release is forbidden — must settle or
        // recovery-review. Prevents concurrent mark_start/release from
        // refunding a funded attempt.
        if job.funded_start {
            self.unclaim_op(&op.0);
            return Err(LedgerError::Conflict(format!(
                "job {job_id} is start_authorized; cannot release"
            )));
        }
        let prov = job.provenance.clone();
        let e = self.balances.entry(account.to_string()).or_insert((0, 0));
        e.0 += prov.total.0;
        e.1 += prov.withdrawable.0;
        job.state = "released".into();
        job.disposition = Some("released".into());
        Ok(true)
    }

    /// Release only when fencing epoch matches (DECISIONS #56).
    pub fn release_fenced(
        &mut self,
        epoch: u64,
        op: OperationKey,
        job_id: &str,
        account: &str,
    ) -> Result<bool, LedgerError> {
        self.require_fencing_epoch(job_id, epoch)?;
        self.release(op, job_id, account)
    }

    pub fn balance(&self, account: &str) -> (i64, i64) {
        self.balances.get(account).copied().unwrap_or((0, 0))
    }

    pub fn job_funded_start(&self, job_id: &str) -> bool {
        self.jobs.get(job_id).map(|j| j.funded_start).unwrap_or(false)
    }

    pub fn job_disposition(&self, job_id: &str) -> Option<&str> {
        self.jobs
            .get(job_id)
            .and_then(|j| j.disposition.as_deref())
    }

    pub fn job_reserved_total(&self, job_id: &str) -> Option<MicroUsd> {
        self.jobs.get(job_id).map(|j| j.provenance.total)
    }

    /// Account that owns an active (or disposed) job — used by batch clear paths.
    pub fn job_account_id(&self, job_id: &str) -> Option<String> {
        self.jobs.get(job_id).map(|j| j.account_id.clone())
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

    /// Active (non-disposed) job ids — used by ops/e2e orphan discovery.
    pub fn active_job_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .jobs
            .iter()
            .filter(|(_, j)| j.disposition.is_none())
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
    }

    /// Active job ids owned by `account` (DECISIONS #105 account-scoped abort).
    pub fn active_job_ids_for_account(&self, account: &str) -> Vec<String> {
        let mut ids: Vec<String> = self
            .jobs
            .iter()
            .filter(|(_, j)| j.disposition.is_none() && j.account_id == account)
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
    }

    /// Per-job orphan inventory for quiescence (DECISIONS #76/#77).
    /// `current_epoch` is the live ownership epoch (0 when not holding).
    pub fn active_jobs_detail(&self, current_epoch: u64) -> Vec<serde_json::Value> {
        let mut rows: Vec<(String, serde_json::Value)> = self
            .jobs
            .iter()
            .filter(|(_, j)| j.disposition.is_none())
            .map(|(id, j)| {
                let needs_adopt = j.fencing_epoch != 0
                    && current_epoch != 0
                    && j.fencing_epoch != current_epoch;
                (
                    id.clone(),
                    serde_json::json!({
                        "job_id": id,
                        "account_id": j.account_id,
                        "state": j.state,
                        "funded_start": j.funded_start,
                        "fencing_epoch": j.fencing_epoch,
                        "needs_adopt": needs_adopt,
                        "reserved_micro_usd": j.provenance.total.0,
                        "reserved_withdrawable_micro_usd": j.provenance.withdrawable.0,
                    }),
                )
            })
            .collect();
        rows.sort_by(|a, b| a.0.cmp(&b.0));
        rows.into_iter().map(|(_, v)| v).collect()
    }

    /// Reserved-not-started active job ids (recover-batch candidates).
    pub fn reserved_not_started_job_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .jobs
            .iter()
            .filter(|(_, j)| j.disposition.is_none() && !j.funded_start)
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
    }

    /// Counts for quiescence orphan_summary (DECISIONS #81).
    pub fn orphan_summary_counts(&self, current_epoch: u64) -> (usize, usize, usize) {
        let mut needs_adopt = 0usize;
        let mut reserved = 0usize;
        let mut held = 0usize;
        for j in self.jobs.values() {
            if j.disposition.is_some() {
                continue;
            }
            if j.funded_start {
                held += 1;
            } else {
                reserved += 1;
            }
            if j.fencing_epoch != 0
                && current_epoch != 0
                && j.fencing_epoch != current_epoch
            {
                needs_adopt += 1;
            }
        }
        (needs_adopt, reserved, held)
    }

    /// Accounts with active reserved/held orphans (sorted), for cutover chaining.
    pub fn accounts_needing_cutover(&self, current_epoch: u64) -> Vec<String> {
        self.orphan_summary_by_account(current_epoch)
            .into_iter()
            .filter(|(_, _a, reserved, held)| *reserved + *held > 0)
            .map(|(acct, _, _, _)| acct)
            .collect()
    }

    /// Snapshot used by admin success/abort responses (DECISIONS #130).
    pub fn cutover_status(&self, current_epoch: u64) -> CutoverStatus {
        let (needs_adopt, _, _) = self.orphan_summary_counts(current_epoch);
        CutoverStatus {
            accounts_needing_cutover: self.accounts_needing_cutover(current_epoch),
            needs_adopt_count: needs_adopt,
            active_jobs: self.active_job_count(),
            held_start_authorized: self.held_start_authorized_count(),
        }
    }

    /// Per-account orphan counts for multi-tenant cutover (DECISIONS #110).
    /// Returns sorted `(account_id, needs_adopt, reserved_not_started, held)`.
    pub fn orphan_summary_by_account(
        &self,
        current_epoch: u64,
    ) -> Vec<(String, usize, usize, usize)> {
        use std::collections::BTreeMap;
        let mut map: BTreeMap<String, (usize, usize, usize)> = BTreeMap::new();
        for j in self.jobs.values() {
            if j.disposition.is_some() {
                continue;
            }
            let entry = map.entry(j.account_id.clone()).or_insert((0, 0, 0));
            if j.funded_start {
                entry.2 += 1;
            } else {
                entry.1 += 1;
            }
            if j.fencing_epoch != 0
                && current_epoch != 0
                && j.fencing_epoch != current_epoch
            {
                entry.0 += 1;
            }
        }
        map.into_iter()
            .map(|(acct, (a, r, h))| (acct, a, r, h))
            .collect()
    }

    /// Jobs that are start_authorized but not yet disposed (held for review).
    pub fn held_start_authorized_count(&self) -> usize {
        self.jobs
            .values()
            .filter(|j| j.disposition.is_none() && j.funded_start)
            .count()
    }

    pub fn held_start_authorized_job_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self
            .jobs
            .iter()
            .filter(|(_, j)| j.disposition.is_none() && j.funded_start)
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
    }

    /// Held start_authorized job ids owned by `account` (DECISIONS #105).
    pub fn held_start_authorized_job_ids_for_account(&self, account: &str) -> Vec<String> {
        let mut ids: Vec<String> = self
            .jobs
            .iter()
            .filter(|(_, j)| {
                j.disposition.is_none() && j.funded_start && j.account_id == account
            })
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
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
        led.mark_start_authorized("j", "a").unwrap();
        assert!(led
            .mark_start_authorized("j", "a")
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
        led.mark_start_authorized("j", "a").unwrap();
        assert!(led.job_funded_start("j"));
        assert!(matches!(
            led.mark_start_authorized("j", "a"),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn settle_capped_respects_billable_cap() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
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
    fn release_op_key_binds_reserved_amount() {
        // DECISIONS #144: MemoryLedger stores reserved amount like release_sql.
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 0).unwrap();
        led.reserve(OperationKey("r1".into()), "j1", "a", 1_000_000)
            .unwrap();
        assert!(led
            .release(OperationKey("rel-shared".into()), "j1", "a")
            .unwrap());
        led.reserve(OperationKey("r2".into()), "j2", "a", 2_000_000)
            .unwrap();
        // Same op key, different reserved amount → Conflict (not silent replay).
        assert!(matches!(
            led.release(OperationKey("rel-shared".into()), "j2", "a"),
            Err(LedgerError::Conflict(_))
        ));
        // j1 refunded then j2 reserved 2M from 10M → 8M; conflict leaves j2 held.
        assert_eq!(led.balance("a").0, 8_000_000);
        assert_eq!(led.active_job_count(), 1);
    }

    #[test]
    fn settle_rejects_conflicting_terminal_digest() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r1".into()), "j1", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j1", "a").unwrap();
        assert!(led
            .settle(OperationKey("s1".into()), "j1", "a", 500_000, "digest-a")
            .unwrap());
        // Reuse same digest on a different job → conflict.
        led.reserve(OperationKey("r2".into()), "j2", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j2", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
            led.mark_start_authorized("missing", "a"),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn mark_start_authorized_rejects_account_mismatch() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_000_000, 0).unwrap();
        led.credit("b", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        assert!(matches!(
            led.mark_start_authorized("j", "b"),
            Err(LedgerError::Conflict(_))
        ));
        assert!(!led.job_funded_start("j"));
        led.mark_start_authorized("j", "a").unwrap();
        assert!(led.job_funded_start("j"));
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j1", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j", "a").unwrap();
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
        led.mark_start_authorized("j1", "a").unwrap();
        // Empty digest is allowed but still unique across jobs.
        assert!(led
            .settle(OperationKey("s1".into()), "j1", "a", 400_000, "")
            .unwrap());
        led.reserve(OperationKey("r2".into()), "j2", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j2", "a").unwrap();
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

    #[test]
    fn settle_capped_zero_actual_refunds_full_even_with_positive_cap() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        // actual=0, cap=500k → charge min(0,500k)=0 → full refund
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                0,
                500_000,
                "d-za"
            )
            .unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn credit_zero_amounts_is_allowed_noop() {
        let mut led = MemoryLedger::default();
        led.credit("a", 0, 0).unwrap();
        assert_eq!(led.balance("a"), (0, 0));
        led.credit("a", 1_000_000, 0).unwrap();
        led.credit("a", 0, 0).unwrap();
        assert_eq!(led.balance("a"), (1_000_000, 0));
    }

    #[test]
    fn settle_exact_withdrawable_only_charge_leaves_non_wdr_intact() {
        let mut led = MemoryLedger::default();
        // Pure withdrawable earnings.
        led.credit("a", 4_000_000, 4_000_000).unwrap();
        let res = led
            .reserve(OperationKey("r".into()), "j", "a", 3_000_000)
            .unwrap();
        assert_eq!(res.provenance.withdrawable.0, 3_000_000);
        assert_eq!(led.balance("a"), (1_000_000, 1_000_000));
        led.mark_start_authorized("j", "a").unwrap();
        // Charge exactly the reserved withdrawable amount.
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 3_000_000, "d-wonly")
            .unwrap());
        // Full charge of reserved wdr → no refund; leftover account wdr untouched.
        assert_eq!(led.balance("a"), (1_000_000, 1_000_000));
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn settle_capped_equal_actual_and_cap() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 2_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                750_000,
                750_000,
                "d-eq"
            )
            .unwrap());
        // reserved 2M, charged 750k → refund 1.25M → bal = 5M-2M+1.25M = 4.25M
        assert_eq!(led.balance("a").0, 4_250_000);
    }

    #[test]
    fn release_restores_partial_withdrawable_provenance() {
        let mut led = MemoryLedger::default();
        // 2M non-wdr + 3M wdr
        led.credit("a", 2_000_000, 0).unwrap();
        led.credit("a", 3_000_000, 3_000_000).unwrap();
        // Reserve 4M → 2M non-wdr + 2M wdr
        let res = led
            .reserve(OperationKey("r".into()), "j", "a", 4_000_000)
            .unwrap();
        assert_eq!(res.provenance.withdrawable.0, 2_000_000);
        assert_eq!(led.balance("a"), (1_000_000, 1_000_000));
        assert!(led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        // Full provenance restore.
        assert_eq!(led.balance("a"), (5_000_000, 3_000_000));
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn settle_capped_billable_cap_above_reservation_still_caps_at_actual() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        // Cap way above reservation; actual within reservation → charge actual.
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                200_000,
                9_000_000,
                "d-bigcap"
            )
            .unwrap());
        // reserved 1M, charged 200k → refund 800k → bal = 5M-1M+800k = 4.8M
        assert_eq!(led.balance("a").0, 4_800_000);
    }

    #[test]
    fn release_then_re_reserve_same_job_id_conflicts() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r1".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(led
            .release(OperationKey("rel1".into()), "j", "a")
            .unwrap());
        // Job IDs are single-use; disposed jobs must not be overwritten.
        assert!(matches!(
            led.reserve(OperationKey("r2".into()), "j", "a", 500_000),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.active_job_count(), 0);
        assert_eq!(led.balance("a").0, 5_000_000);
        // Op key from the failed reserve must not poison later use.
        let res = led
            .reserve(OperationKey("r2".into()), "j-new", "a", 500_000)
            .unwrap();
        assert!(res.applied);
        assert_eq!(led.active_job_count(), 1);
    }

    #[test]
    fn reserve_active_job_id_under_new_op_conflicts() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r1".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(matches!(
            led.reserve(OperationKey("r2".into()), "j", "a", 500_000),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.active_job_count(), 1);
        assert_eq!(led.balance("a").0, 4_000_000);
    }

    #[test]
    fn mark_start_authorized_after_release_conflicts() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(led
            .release(OperationKey("rel".into()), "j", "a")
            .unwrap());
        assert!(matches!(
            led.mark_start_authorized("j", "a"),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn settle_capped_clamps_actual_before_reservation_check() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        // charge = min(actual, cap, reserved) = min(2M, 500k, 1M) = 500k
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                2_000_000,
                500_000,
                "d-clamp"
            )
            .unwrap());
        // reserved 1M, charged 500k → refund 500k → bal = 5M-1M+500k = 4.5M
        assert_eq!(led.balance("a").0, 4_500_000);
    }

    #[test]
    fn settle_capped_clamps_to_reservation_when_cap_exceeds() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        // Stream checkpoint / provider both claim above reservation — charge reserved.
        assert!(led
            .settle_capped(
                OperationKey("s".into()),
                "j",
                "a",
                9_000_000,
                8_000_000,
                "d-res-clamp"
            )
            .unwrap());
        // reserved 1M, charged 1M → refund 0 → bal = 5M-1M = 4M
        assert_eq!(led.balance("a").0, 4_000_000);
        assert_eq!(led.active_job_count(), 0);
    }

    #[test]
    fn resize_and_authorize_up_debits_and_funds_start() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        let res = led
            .resize_and_authorize(OperationKey("ra".into()), "j", "a", 2_500_000)
            .unwrap();
        assert!(res.applied);
        assert_eq!(res.provenance.total.0, 2_500_000);
        assert!(led.job_funded_start("j"));
        assert_eq!(led.held_start_authorized_count(), 1);
        // 10M - 1M - 1.5M = 7.5M
        assert_eq!(led.balance("a").0, 7_500_000);
        // Second call with same op is idempotent.
        let again = led
            .resize_and_authorize(OperationKey("ra".into()), "j", "a", 2_500_000)
            .unwrap();
        assert!(!again.applied);
        assert_eq!(led.balance("a").0, 7_500_000);
    }

    #[test]
    fn resize_and_authorize_down_refunds_unused() {
        let mut led = MemoryLedger::default();
        led.credit("a", 10_000_000, 4_000_000).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 5_000_000)
            .unwrap();
        // After reserve: bal=5M, wdr consumed from non-wdr first.
        let res = led
            .resize_and_authorize(OperationKey("ra".into()), "j", "a", 2_000_000)
            .unwrap();
        assert!(res.applied);
        assert_eq!(res.provenance.total.0, 2_000_000);
        assert!(led.job_funded_start("j"));
        // 10M - 5M + 3M refund = 8M
        assert_eq!(led.balance("a").0, 8_000_000);
    }

    #[test]
    fn resize_and_authorize_rejects_already_authorized() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        assert!(matches!(
            led.resize_and_authorize(OperationKey("ra".into()), "j", "a", 2_000_000),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn resize_and_authorize_insufficient_balance_on_upsize() {
        let mut led = MemoryLedger::default();
        led.credit("a", 1_500_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        // Remaining bal = 500k; need +1M more → insufficient.
        assert_eq!(
            led.resize_and_authorize(OperationKey("ra".into()), "j", "a", 2_000_000),
            Err(LedgerError::InsufficientBalance)
        );
        assert!(!led.job_funded_start("j"));
        assert_eq!(led.balance("a").0, 500_000);
        // Failed op key must not poison a later successful resize.
        let res = led
            .resize_and_authorize(OperationKey("ra".into()), "j", "a", 1_200_000)
            .unwrap();
        assert!(res.applied);
        assert_eq!(led.balance("a").0, 300_000);
    }

    #[test]
    fn resize_and_authorize_zero_amount_invalid() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        assert_eq!(
            led.resize_and_authorize(OperationKey("ra".into()), "j", "a", 0),
            Err(LedgerError::InvalidAmount)
        );
    }

    #[test]
    fn settle_rejects_account_mismatch_without_poisoning_op() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.credit("b", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        assert!(matches!(
            led.settle(OperationKey("s".into()), "j", "b", 100_000, "d-mis"),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.balance("a").0, 4_000_000);
        assert_eq!(led.balance("b").0, 5_000_000);
        // Same op key can retry with correct account.
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 100_000, "d-mis")
            .unwrap());
        assert_eq!(led.balance("a").0, 4_900_000);
    }

    #[test]
    fn release_rejects_account_mismatch_without_poisoning_op() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.credit("b", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        assert!(matches!(
            led.release(OperationKey("rel".into()), "j", "b"),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.balance("a").0, 4_000_000);
        assert_eq!(led.balance("b").0, 1_000_000);
        assert!(led.release(OperationKey("rel".into()), "j", "a").unwrap());
        assert_eq!(led.balance("a").0, 5_000_000);
    }

    #[test]
    fn release_after_start_authorized_does_not_poison_op_key() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        assert!(matches!(
            led.release(OperationKey("rel".into()), "j", "a"),
            Err(LedgerError::Conflict(_))
        ));
        // Op key reusable after conflict (still fails for the same reason).
        assert!(matches!(
            led.release(OperationKey("rel".into()), "j", "a"),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.active_job_count(), 1);
    }

    #[test]
    fn reserve_op_key_reuse_different_job_conflicts() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        assert!(led
            .reserve(OperationKey("op".into()), "j1", "a", 100_000)
            .unwrap()
            .applied);
        assert!(matches!(
            led.reserve(OperationKey("op".into()), "j2", "a", 100_000),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.active_job_count(), 1);
        assert_eq!(led.balance("a").0, 4_900_000);
    }

    #[test]
    fn settle_op_key_reuse_different_digest_conflicts() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        assert!(led
            .settle(OperationKey("s".into()), "j", "a", 100_000, "d1")
            .unwrap());
        // Same op, different digest must not silently noop.
        assert!(matches!(
            led.settle(OperationKey("s".into()), "j", "a", 100_000, "d2"),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.balance("a").0, 4_900_000);
    }

    #[test]
    fn settle_capped_op_key_reuse_different_cap_conflicts() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        led.mark_start_authorized("j", "a").unwrap();
        assert!(led
            .settle_capped(OperationKey("sc".into()), "j", "a", 500_000, 100_000, "d1")
            .unwrap());
        assert!(matches!(
            led.settle_capped(OperationKey("sc".into()), "j", "a", 500_000, 200_000, "d2"),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.balance("a").0, 4_900_000);
    }

    #[test]
    fn fencing_epoch_mismatch_is_ownership_lost() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        led.bind_fencing_epoch("j", 9).unwrap();
        assert!(led.require_fencing_epoch("j", 9).is_ok());
        assert!(matches!(
            led.require_fencing_epoch("j", 10),
            Err(LedgerError::OwnershipLost)
        ));
        // Unbound jobs (epoch 0) accept any caller epoch.
        led.reserve(OperationKey("r2".into()), "j2", "a", 50_000)
            .unwrap();
        assert!(led.require_fencing_epoch("j2", 99).is_ok());
    }

    #[test]
    fn reserve_with_epoch_binds_atomically() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 7)
            .unwrap();
        assert!(led.require_fencing_epoch("j", 7).is_ok());
        assert!(matches!(
            led.require_fencing_epoch("j", 8),
            Err(LedgerError::OwnershipLost)
        ));
        // Idempotent replay with matching epoch is fine.
        let again = led
            .reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 7)
            .unwrap();
        assert!(!again.applied);
        // Replay with mismatched epoch is OwnershipLost.
        assert!(matches!(
            led.reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 9),
            Err(LedgerError::OwnershipLost)
        ));
    }

    #[test]
    fn adopt_fencing_epoch_rebinds_active_job() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve_with_epoch(OperationKey("r".into()), "j", "a", 100_000, 3)
            .unwrap();
        assert_eq!(led.job_fencing_epoch("j"), Some(3));
        assert_eq!(led.adopt_fencing_epoch("j", 10).unwrap(), 3);
        assert_eq!(led.job_fencing_epoch("j"), Some(10));
        assert!(led.require_fencing_epoch("j", 10).is_ok());
        assert!(matches!(
            led.require_fencing_epoch("j", 3),
            Err(LedgerError::OwnershipLost)
        ));
        // Disposed jobs cannot be adopted.
        led.release_fenced(10, OperationKey("rel".into()), "j", "a")
            .unwrap();
        assert!(matches!(
            led.adopt_fencing_epoch("j", 11),
            Err(LedgerError::Conflict(_))
        ));
    }

    #[test]
    fn fenced_money_apis_refuse_wrong_epoch() {
        let mut led = MemoryLedger::default();
        led.credit("a", 5_000_000, 0).unwrap();
        led.reserve_with_epoch(OperationKey("r".into()), "j", "a", 200_000, 3)
            .unwrap();
        assert!(matches!(
            led.resize_and_authorize_fenced(9, OperationKey("ra".into()), "j", "a", 200_000),
            Err(LedgerError::OwnershipLost)
        ));
        led.resize_and_authorize_fenced(3, OperationKey("ra".into()), "j", "a", 200_000)
            .unwrap();
        assert!(matches!(
            led.settle_capped_fenced(9, OperationKey("s".into()), "j", "a", 10, 10, "d"),
            Err(LedgerError::OwnershipLost)
        ));
        assert!(led
            .settle_capped_fenced(3, OperationKey("s".into()), "j", "a", 10, 10, "d")
            .unwrap());

        led.reserve_with_epoch(OperationKey("r2".into()), "j2", "a", 50_000, 5)
            .unwrap();
        assert!(matches!(
            led.release_fenced(1, OperationKey("rel".into()), "j2", "a"),
            Err(LedgerError::OwnershipLost)
        ));
        assert!(led
            .release_fenced(5, OperationKey("rel".into()), "j2", "a")
            .unwrap());
    }

    #[test]
    fn cutover_status_snapshot_tracks_accounts_and_adopt() {
        let mut led = MemoryLedger::default();
        led.credit("a", 100_000, 0).unwrap();
        led.credit("b", 100_000, 0).unwrap();
        led.reserve_with_epoch(OperationKey("ra".into()), "ja", "a", 10_000, 1)
            .unwrap();
        led.mark_start_authorized_fenced(1, "ja", "a").unwrap();
        led.reserve_with_epoch(OperationKey("rb".into()), "jb", "b", 20_000, 1)
            .unwrap();

        let s = led.cutover_status(1);
        assert_eq!(s.needs_adopt_count, 0);
        assert_eq!(s.active_jobs, 2);
        assert_eq!(s.held_start_authorized, 1);
        assert_eq!(s.accounts_needing_cutover, vec!["a".to_string(), "b".to_string()]);

        // New epoch without adopt → needs_adopt for both.
        let s2 = led.cutover_status(2);
        assert_eq!(s2.needs_adopt_count, 2);
        assert_eq!(s2.accounts_needing_cutover, vec!["a".to_string(), "b".to_string()]);

        led.adopt_fencing_epoch("ja", 2).unwrap();
        let s3 = led.cutover_status(2);
        assert_eq!(s3.needs_adopt_count, 1);
        assert_eq!(led.accounts_needing_cutover(2), vec!["a".to_string(), "b".to_string()]);
    }
}
