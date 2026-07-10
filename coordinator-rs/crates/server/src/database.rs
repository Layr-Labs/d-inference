use std::time::Duration;

use sqlx::{PgPool, postgres::PgPoolOptions};
use thiserror::Error;
use tokio::time::timeout;

/// Bounded PostgreSQL access owned by server adapters.
#[derive(Clone, Debug)]
pub struct Database {
    pool: PgPool,
    operation_timeout: Duration,
}

#[derive(Debug, Error)]
pub enum DatabaseError {
    #[error("connect to PostgreSQL: {0}")]
    Connect(#[source] sqlx::Error),
    #[error("PostgreSQL readiness query: {0}")]
    Readiness(#[source] sqlx::Error),
    #[error("PostgreSQL readiness query exceeded {0:?}")]
    ReadinessTimeout(Duration),
    #[error("PostgreSQL pool close exceeded {0:?}")]
    CloseTimeout(Duration),
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
        let database = Self {
            pool,
            operation_timeout: acquire_timeout,
        };
        database.ping().await?;
        Ok(database)
    }

    pub async fn ping(&self) -> Result<(), DatabaseError> {
        let value = timeout(
            self.operation_timeout,
            sqlx::query_scalar!("SELECT 1 AS \"value!\"").fetch_one(&self.pool),
        )
        .await
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
}

#[cfg(test)]
mod tests {
    use std::{
        future::pending,
        time::{Duration, Instant},
    };

    use sqlx::postgres::PgPoolOptions;
    use tokio::{net::TcpListener, task};

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
            operation_timeout: Duration::from_millis(25),
        };

        let started = Instant::now();
        let error = database.ping().await.expect_err("blackhole must time out");
        assert!(matches!(error, DatabaseError::ReadinessTimeout(_)));
        assert!(started.elapsed() < Duration::from_secs(1));

        blackhole.abort();
        let _ = blackhole.await;
    }
}
