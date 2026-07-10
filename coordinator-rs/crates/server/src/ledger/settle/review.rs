//! Review parking: moves a non-terminal job to `review_pending` with its
//! reservation retained (plan §12.2 — nonterminal, no money moves).

use sqlx::PgConnection;

use crate::contracts::SettleParams;
use crate::ledger::error::TxError;

use super::transaction::JobRow;

/// Parks a non-terminal job in `review_pending` (nonterminal, reservation
/// retained — plan §12.2) with the reason recorded.
pub(super) async fn park_job_for_review(
    tx: &mut PgConnection,
    p: &SettleParams,
    job: &JobRow,
    reason: &str,
) -> Result<(), TxError> {
    sqlx::query(
        "UPDATE rust_coord.inference_jobs j \
         SET state = 'review_pending', error_class = $2, \
             version = j.version + 1, updated_at = NOW() \
         WHERE j.job_id = $1 AND j.version = $3 \
           AND j.state IN ('reserved','preparing','prepared','start_authorized','running')",
    )
    .bind(p.job.get())
    .bind(reason)
    .bind(job.version)
    .execute(&mut *tx)
    .await?;
    Ok(())
}
