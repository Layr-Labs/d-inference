use std::time::Duration;

use sqlx::{PgPool, postgres::PgPoolOptions};
use thiserror::Error;

/// Bounded PostgreSQL access owned by server adapters.
#[derive(Clone, Debug)]
pub struct Database {
    pool: PgPool,
}

#[derive(Debug, Error)]
pub enum DatabaseError {
    #[error("connect to PostgreSQL: {0}")]
    Connect(#[source] sqlx::Error),
    #[error("PostgreSQL readiness query: {0}")]
    Readiness(#[source] sqlx::Error),
}

impl Database {
    pub async fn connect(
        url: &str,
        max_connections: u32,
        acquire_timeout: Duration,
    ) -> Result<Self, DatabaseError> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .acquire_timeout(acquire_timeout)
            .connect(url)
            .await
            .map_err(DatabaseError::Connect)?;
        let database = Self { pool };
        database.ping().await?;
        Ok(database)
    }

    pub async fn ping(&self) -> Result<(), DatabaseError> {
        let value = sqlx::query_scalar!("SELECT 1 AS \"value!\"")
            .fetch_one(&self.pool)
            .await
            .map_err(DatabaseError::Readiness)?;
        if value == 1 {
            Ok(())
        } else {
            unreachable!("PostgreSQL SELECT 1 returned {value}")
        }
    }

    pub async fn close(self) {
        self.pool.close().await;
    }
}
