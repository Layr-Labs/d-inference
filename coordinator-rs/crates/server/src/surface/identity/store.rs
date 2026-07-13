use std::{future::Future, sync::Arc, time::Duration};

use sqlx::PgPool;
use tokio::time::timeout;

use super::{error::IdentityError, types::MutationAuthority};

#[derive(Clone, Debug)]
pub struct IdentityStore {
    pool: PgPool,
    authority: Arc<MutationAuthority>,
    operation_timeout: Duration,
}

impl IdentityStore {
    pub fn new(
        pool: PgPool,
        authority: MutationAuthority,
        operation_timeout: Duration,
    ) -> Result<Self, IdentityError> {
        if operation_timeout.is_zero() {
            return Err(IdentityError::Unavailable);
        }
        Ok(Self {
            pool,
            authority: Arc::new(authority),
            operation_timeout,
        })
    }

    pub(crate) fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub(crate) fn owner_id(&self) -> &str {
        &self.authority.owner_id
    }

    pub(crate) fn epoch(&self) -> i64 {
        self.authority.epoch
    }

    pub(crate) async fn bounded<T>(
        &self,
        future: impl Future<Output = Result<T, sqlx::Error>>,
    ) -> Result<T, IdentityError> {
        timeout(self.operation_timeout, future)
            .await
            .map_err(|_| IdentityError::Timeout)?
            .map_err(IdentityError::Database)
    }
}
