use std::{future::Future, sync::Arc, time::Duration};

use sqlx::{PgConnection, PgPool, Postgres, Transaction, postgres::PgPoolOptions};
use thiserror::Error;
use tokio::time::timeout;

use crate::{
    mutation_fence::PoolMutationFence,
    ownership::{FencingContext, OwnershipError, OwnershipFence},
    schema::{self, SchemaCompatibility, SchemaError},
};

/// Bounded PostgreSQL access owned by server adapters.
#[derive(Clone, Debug)]
pub struct Database {
    pool: PgPool,
    mutation_fence: Arc<PoolMutationFence>,
    operation_timeout: Duration,
    compatibility: SchemaCompatibility,
}

#[derive(Debug, Error)]
pub enum DatabaseError {
    #[error("connect to PostgreSQL: {0}")]
    Connect(#[source] sqlx::Error),
    #[error(transparent)]
    Schema(#[from] SchemaError),
    #[error("PostgreSQL readiness query: {0}")]
    Readiness(#[source] sqlx::Error),
    #[error("PostgreSQL readiness query exceeded {0:?}")]
    ReadinessTimeout(Duration),
    #[error("begin PostgreSQL transaction: {0}")]
    BeginTransaction(#[source] sqlx::Error),
    #[error("begin PostgreSQL transaction exceeded {0:?}")]
    BeginTransactionTimeout(Duration),
    #[error(transparent)]
    Ownership(#[from] OwnershipError),
    #[error("{operation} PostgreSQL transaction: {source}")]
    Transaction {
        operation: &'static str,
        source: sqlx::Error,
    },
    #[error("{operation} PostgreSQL transaction exceeded {duration:?}")]
    TransactionTimeout {
        operation: &'static str,
        duration: Duration,
    },
    #[error("PostgreSQL pool close exceeded {0:?}")]
    CloseTimeout(Duration),
}

impl Database {
    pub async fn connect(
        url: &str,
        max_connections: u32,
        acquire_timeout: Duration,
    ) -> Result<Self, DatabaseError> {
        let mutation_fence = Arc::new(PoolMutationFence::default());
        let after_connect_fence = Arc::clone(&mutation_fence);
        let before_acquire_fence = Arc::clone(&mutation_fence);
        let after_release_fence = Arc::clone(&mutation_fence);
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .acquire_timeout(acquire_timeout)
            .after_connect(move |connection, _metadata| {
                let fence = Arc::clone(&after_connect_fence);
                Box::pin(async move {
                    if fence.before_checkout(connection).await? {
                        Ok(())
                    } else {
                        Err(sqlx::Error::Protocol(
                            "coordinator ownership lost during PostgreSQL connection setup"
                                .to_owned(),
                        ))
                    }
                })
            })
            .before_acquire(move |connection, _metadata| {
                let fence = Arc::clone(&before_acquire_fence);
                Box::pin(async move { fence.before_checkout(connection).await })
            })
            .after_release(move |connection, _metadata| {
                let fence = Arc::clone(&after_release_fence);
                Box::pin(async move { fence.after_checkout(connection).await })
            })
            .connect(url)
            .await
            .map_err(DatabaseError::Connect)?;
        let compatibility = match schema::check(&pool, acquire_timeout).await {
            Ok(compatibility) => compatibility,
            Err(error) => {
                pool.close().await;
                return Err(error.into());
            }
        };
        let database = Self {
            pool,
            mutation_fence,
            operation_timeout: acquire_timeout,
            compatibility,
        };
        database.ping().await?;
        Ok(database)
    }

    pub async fn ping(&self) -> Result<(), DatabaseError> {
        if self
            .mutation_fence
            .status()
            .is_some_and(|status| !status.is_healthy())
        {
            return Err(OwnershipError::Lost.into());
        }
        let query = timeout(
            self.operation_timeout,
            sqlx::query_scalar!("SELECT 1 AS \"value!\"").fetch_one(&self.pool),
        );
        tokio::pin!(query);
        let value = match self.mutation_fence.status() {
            Some(status) => {
                tokio::select! {
                    biased;
                    () = status.wait_until_unhealthy() => {
                        return Err(OwnershipError::Lost.into());
                    }
                    result = &mut query => result,
                }
            }
            None => query.await,
        }
        .map_err(|_| DatabaseError::ReadinessTimeout(self.operation_timeout))?
        .map_err(DatabaseError::Readiness)?;
        if value == 1 {
            Ok(())
        } else {
            unreachable!("PostgreSQL SELECT 1 returned {value}")
        }
    }

    pub async fn close(self, close_timeout: Duration) -> Result<(), DatabaseError> {
        timeout(close_timeout, self.pool.close())
            .await
            .map_err(|_| DatabaseError::CloseTimeout(close_timeout))
    }

    pub fn compatibility(&self) -> SchemaCompatibility {
        self.compatibility
    }

    pub async fn begin_owned(&self) -> Result<OwnedTransaction<'_>, DatabaseError> {
        let Some((context, status)) = self.mutation_fence.authority() else {
            return Err(OwnershipError::NotConfigured.into());
        };
        let fence = OwnershipFence::new(context, status, self.operation_timeout);
        if !fence.status().is_healthy() {
            return Err(OwnershipError::Lost.into());
        }
        let begin = timeout(self.operation_timeout, self.pool.begin());
        tokio::pin!(begin);
        let status = fence.status();
        let mut transaction = tokio::select! {
            biased;
            () = status.wait_until_unhealthy() => {
                return Err(OwnershipError::Lost.into());
            }
            result = &mut begin => result,
        }
        .map_err(|_| DatabaseError::BeginTransactionTimeout(self.operation_timeout))?
        .map_err(DatabaseError::BeginTransaction)?;
        fence.verify_transaction(&mut transaction).await?;
        Ok(OwnedTransaction {
            transaction,
            context: fence.context().clone(),
            operation_timeout: self.operation_timeout,
        })
    }

    pub(crate) fn activate_ownership_fence(
        &self,
        context: FencingContext,
        status: crate::ownership::OwnershipStatus,
    ) {
        self.mutation_fence.activate(context, status);
    }

    pub(crate) fn operation_timeout(&self) -> Duration {
        self.operation_timeout
    }

    pub(crate) fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub(crate) fn authority(&self) -> Option<(FencingContext, crate::ownership::OwnershipStatus)> {
        self.mutation_fence.authority()
    }
}

#[derive(Debug)]
pub struct OwnedTransaction<'a> {
    transaction: Transaction<'a, Postgres>,
    context: FencingContext,
    operation_timeout: Duration,
}

impl OwnedTransaction<'_> {
    pub fn context(&self) -> &FencingContext {
        &self.context
    }

    pub fn connection(&mut self) -> &mut PgConnection {
        &mut self.transaction
    }

    pub async fn commit(self) -> Result<(), DatabaseError> {
        finish_transaction("commit", self.operation_timeout, self.transaction.commit()).await
    }

    pub async fn rollback(self) -> Result<(), DatabaseError> {
        finish_transaction(
            "roll back",
            self.operation_timeout,
            self.transaction.rollback(),
        )
        .await
    }
}

async fn finish_transaction(
    operation: &'static str,
    operation_timeout: Duration,
    future: impl Future<Output = Result<(), sqlx::Error>>,
) -> Result<(), DatabaseError> {
    timeout(operation_timeout, future)
        .await
        .map_err(|_| DatabaseError::TransactionTimeout {
            operation,
            duration: operation_timeout,
        })?
        .map_err(|source| DatabaseError::Transaction { operation, source })
}

#[cfg(test)]
mod tests {
    use std::{
        future::pending,
        sync::Arc,
        time::{Duration, Instant},
    };

    use sqlx::postgres::PgPoolOptions;
    use tokio::{net::TcpListener, task};

    use crate::{mutation_fence::PoolMutationFence, schema::SchemaCompatibility};

    use super::{Database, DatabaseError};

    #[tokio::test]
    async fn readiness_is_bounded_against_a_blackholed_database() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let address = listener.local_addr().expect("address");
        let blackhole = task::spawn(async move {
            let (_connection, _) = listener.accept().await.expect("accept");
            pending::<()>().await;
        });
        let pool = PgPoolOptions::new()
            .connect_lazy(&format!(
                "postgres://test:test@{address}/test?sslmode=disable"
            ))
            .expect("lazy pool");
        let database = Database {
            pool,
            mutation_fence: Arc::new(PoolMutationFence::default()),
            operation_timeout: Duration::from_millis(25),
            compatibility: SchemaCompatibility {
                public_version: 4,
                rust_version: 2,
                migration_checksum_valid: true,
            },
        };

        let started = Instant::now();
        let error = database.ping().await.expect_err("blackhole must time out");
        assert!(matches!(error, DatabaseError::ReadinessTimeout(_)));
        assert!(started.elapsed() < Duration::from_secs(1));

        blackhole.abort();
        let _ = blackhole.await;
    }
}
