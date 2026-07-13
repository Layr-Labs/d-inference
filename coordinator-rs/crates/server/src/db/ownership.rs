use std::{future::Future, time::Duration};

use darkbloom_coordinator_core::ids::Digest;
use serde_json::Value;
use sqlx::{FromRow, PgPool};
use tokio::time::{sleep, timeout};

use crate::{
    database::Database,
    ledger::types::{LedgerError, OperationKey},
    ownership::{FencingContext, OwnershipStatus},
};

const MAX_RETRIES: usize = 3;

/// Current database authority captured before a durable statement is built.
#[derive(Clone, Debug)]
pub(crate) struct Authority {
    owner_id: String,
    epoch: i64,
    status: OwnershipStatus,
}

impl Authority {
    #[must_use]
    pub(crate) fn owner_id(&self) -> &str {
        &self.owner_id
    }

    #[must_use]
    pub(crate) const fn epoch(&self) -> i64 {
        self.epoch
    }

    pub(crate) fn ensure_healthy(&self) -> Result<(), LedgerError> {
        if self.status.is_healthy() {
            Ok(())
        } else {
            Err(LedgerError::OwnershipLost)
        }
    }
}

/// Shared concrete SQLx access used by durable services.
#[derive(Clone, Debug)]
pub struct DurableDatabase {
    database: Database,
}

impl DurableDatabase {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self { database }
    }

    pub(crate) fn authority(&self) -> Result<Authority, LedgerError> {
        let Some((context, status)) = self.database.authority() else {
            return Err(LedgerError::OwnershipUnavailable);
        };
        authority_from_context(context, status)
    }

    #[must_use]
    pub(crate) fn pool(&self) -> &PgPool {
        self.database.pool()
    }

    pub(crate) async fn bounded<T>(
        &self,
        future: impl Future<Output = Result<T, sqlx::Error>>,
    ) -> Result<T, LedgerError> {
        timeout(self.database.operation_timeout(), future)
            .await
            .map_err(|_| LedgerError::Timeout)?
            .map_err(LedgerError::Database)
    }

    pub(crate) async fn retry_delay(&self, attempt: usize) {
        let exponential = 5_u64
            .checked_shl(u32::try_from(attempt).unwrap_or(u32::MAX))
            .unwrap_or(40)
            .min(40);
        let jitter = rand::random::<u64>() % (exponential + 1);
        sleep(Duration::from_millis(exponential + jitter)).await;
    }

    #[must_use]
    pub(crate) fn may_retry(attempt: usize, error: &sqlx::Error) -> bool {
        attempt < MAX_RETRIES && is_retryable(error)
    }

    #[must_use]
    pub(crate) fn is_ambiguous(error: &LedgerError) -> bool {
        match error {
            LedgerError::Timeout => true,
            LedgerError::Database(source) => matches!(
                source,
                sqlx::Error::Io(_)
                    | sqlx::Error::Tls(_)
                    | sqlx::Error::Protocol(_)
                    | sqlx::Error::PoolClosed
            ),
            _ => false,
        }
    }

    #[must_use]
    pub(crate) fn is_operation_conflict(error: &sqlx::Error) -> bool {
        error
            .as_database_error()
            .and_then(|database| database.code())
            .is_some_and(|code| code == "23505")
    }

    pub(crate) async fn operation(
        &self,
        authority: &Authority,
        operation_key: &OperationKey,
    ) -> Result<Option<OperationRecord>, LedgerError> {
        authority.ensure_healthy()?;
        let row = self
            .bounded(
                sqlx::query_as_unchecked!(
                    OperationRecord,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        operation_key,
                        operation_digest,
                        kind,
                        status,
                        result,
                        job_id,
                        terminal_id,
                        account_id,
                        amount_total_micro_usd,
                        amount_withdrawable_micro_usd,
                        version
                    FROM rust_coord.financial_operations
                    WHERE operation_key = $3
                      AND EXISTS (SELECT 1 FROM authority)
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    operation_key.as_str(),
                )
                .fetch_optional(self.pool()),
            )
            .await?;
        if row.is_none() {
            self.verify_authority(authority).await?;
        }
        Ok(row)
    }

    pub(crate) async fn verify_authority(&self, authority: &Authority) -> Result<(), LedgerError> {
        authority.ensure_healthy()?;
        let current = self
            .bounded(
                sqlx::query_scalar_unchecked!(
                    r#"
                    SELECT EXISTS (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ) AS "current!"
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                )
                .fetch_one(self.pool()),
            )
            .await?;
        if current {
            Ok(())
        } else {
            authority.status.mark_lost();
            Err(LedgerError::OwnershipLost)
        }
    }
}

fn authority_from_context(
    context: FencingContext,
    status: OwnershipStatus,
) -> Result<Authority, LedgerError> {
    if !status.is_healthy() {
        return Err(LedgerError::OwnershipLost);
    }
    if !context.epoch_active() || context.epoch() <= 0 || context.owner_id().is_empty() {
        return Err(LedgerError::OwnershipUnavailable);
    }
    Ok(Authority {
        owner_id: context.owner_id().to_owned(),
        epoch: context.epoch(),
        status,
    })
}

#[derive(Debug, FromRow)]
pub(crate) struct OperationRecord {
    pub operation_key: String,
    pub operation_digest: Vec<u8>,
    pub kind: String,
    pub status: String,
    pub result: Value,
    pub job_id: Option<uuid::Uuid>,
    pub terminal_id: Option<uuid::Uuid>,
    pub account_id: String,
    pub amount_total_micro_usd: i64,
    pub amount_withdrawable_micro_usd: i64,
    pub version: i64,
}

impl OperationRecord {
    pub(crate) fn digest(&self) -> Result<Digest, LedgerError> {
        Digest::try_from(self.operation_digest.as_slice())
            .map_err(|_| LedgerError::CorruptData("stored operation digest has invalid width"))
    }
}

fn is_retryable(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|database| database.code())
        .is_some_and(|code| code == "40001" || code == "40P01")
}

#[cfg(test)]
mod tests {
    use sqlx::error::DatabaseError;

    use super::is_retryable;

    #[derive(Debug)]
    struct CodedError(&'static str);

    impl std::fmt::Display for CodedError {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str(self.0)
        }
    }

    impl std::error::Error for CodedError {}

    impl DatabaseError for CodedError {
        fn message(&self) -> &str {
            self.0
        }

        fn code(&self) -> Option<std::borrow::Cow<'_, str>> {
            Some(self.0.into())
        }

        fn kind(&self) -> sqlx::error::ErrorKind {
            sqlx::error::ErrorKind::Other
        }

        fn as_error(&self) -> &(dyn std::error::Error + Send + Sync + 'static) {
            self
        }

        fn as_error_mut(&mut self) -> &mut (dyn std::error::Error + Send + Sync + 'static) {
            self
        }

        fn into_error(self: Box<Self>) -> Box<dyn std::error::Error + Send + Sync + 'static> {
            self
        }
    }

    #[test]
    fn retry_is_limited_to_serialization_and_deadlock() {
        assert!(is_retryable(&sqlx::Error::Database(Box::new(CodedError(
            "40001"
        )))));
        assert!(is_retryable(&sqlx::Error::Database(Box::new(CodedError(
            "40P01"
        )))));
        assert!(!is_retryable(&sqlx::Error::Database(Box::new(CodedError(
            "23505"
        )))));
    }
}
