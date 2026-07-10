//! SQLSTATE mapping and bounded retries (plan §12.5: retry ONLY recognized
//! deadlock or serialization failures).

use std::future::Future;
use std::time::Duration;

use crate::contracts::LedgerError;

/// PostgreSQL `serialization_failure` and `deadlock_detected`.
const RETRYABLE_SQLSTATES: [&str; 2] = ["40001", "40P01"];

/// Attempts per financial transaction: the first try plus two retries.
const MAX_ATTEMPTS: u32 = 3;

/// Backoff before retry `n` (1-based).
fn backoff(attempt: u32) -> Duration {
    Duration::from_millis(10 * u64::from(attempt) * u64::from(attempt))
}

#[must_use]
pub fn is_serialization_failure(err: &sqlx::Error) -> bool {
    err.as_database_error()
        .and_then(|db| db.code())
        .is_some_and(|code| RETRYABLE_SQLSTATES.contains(&code.as_ref()))
}

/// Maps a driver error to the typed ledger error. Serialization failures are
/// handled by [`with_retries`] before reaching this.
#[must_use]
pub fn map_sqlx(err: sqlx::Error) -> LedgerError {
    LedgerError::Unavailable(err.to_string())
}

/// Runs `op` up to [`MAX_ATTEMPTS`] times, retrying ONLY on
/// serialization/deadlock SQLSTATEs surfaced as
/// [`LedgerError::Unavailable`]-wrapped driver errors. `op` must be
/// idempotent at the transaction level (all ledger transactions are, via
/// operation keys).
pub async fn with_retries<T, F, Fut>(mut op: F) -> Result<T, LedgerError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, TxError>>,
{
    let mut attempt = 1u32;
    loop {
        match op().await {
            Ok(value) => return Ok(value),
            Err(TxError::Sqlx(err)) if is_serialization_failure(&err) && attempt < MAX_ATTEMPTS => {
                tracing::debug!(attempt, error = %err, "retrying on serialization/deadlock");
                tokio::time::sleep(backoff(attempt)).await;
                attempt += 1;
            }
            Err(TxError::Sqlx(err)) => return Err(map_sqlx(err)),
            Err(TxError::Ledger(err)) => return Err(err),
        }
    }
}

/// Internal transaction error: either a driver error (candidate for retry)
/// or an already-typed ledger outcome (never retried).
#[derive(Debug)]
pub enum TxError {
    Sqlx(sqlx::Error),
    Ledger(LedgerError),
}

impl From<sqlx::Error> for TxError {
    fn from(err: sqlx::Error) -> Self {
        Self::Sqlx(err)
    }
}

impl From<LedgerError> for TxError {
    fn from(err: LedgerError) -> Self {
        Self::Ledger(err)
    }
}
