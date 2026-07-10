use std::{
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    time::Duration,
};

use sqlx::{Connection, PgConnection, Postgres, Transaction};
use thiserror::Error;
use tokio::{
    sync::{Notify, oneshot},
    task::JoinHandle,
    time::{MissedTickBehavior, interval, timeout},
};
use uuid::Uuid;

use crate::{
    database::Database,
    mutation_fence::{
        COORDINATOR_MUTATION_LOCK_NAME, COORDINATOR_OWNERSHIP_LOCK_NAME, verify_authority,
    },
};

const OWNERSHIP_MONITOR_INTERVAL: Duration = Duration::from_millis(500);
const STATE_ACTIVE: u8 = 0;
const STATE_LOST: u8 = 1;
const STATE_RELEASED: u8 = 2;

#[derive(Debug, Error)]
pub enum OwnershipError {
    #[error("coordinator ownership was activated and cannot be disabled")]
    CannotDisableAfterActivation,
    #[error("connect dedicated coordinator ownership connection: {0}")]
    Connect(#[source] sqlx::Error),
    #[error("coordinator ownership is already held by another process")]
    AlreadyHeld,
    #[error("coordinator ownership is not configured for the database pool")]
    NotConfigured,
    #[error("{operation}: {source}")]
    Database {
        operation: &'static str,
        source: sqlx::Error,
    },
    #[error("{operation} exceeded {duration:?}")]
    OperationTimeout {
        operation: &'static str,
        duration: Duration,
    },
    #[error("coordinator ownership lost")]
    Lost,
    #[error("coordinator ownership monitor task failed: {0}")]
    MonitorTask(#[source] tokio::task::JoinError),
}

#[derive(Clone, Debug)]
pub struct OwnershipStatus {
    inner: Arc<OwnershipStatusInner>,
}

#[derive(Debug)]
struct OwnershipStatusInner {
    state: AtomicU8,
    changed: Notify,
}

impl OwnershipStatus {
    fn active() -> Self {
        Self {
            inner: Arc::new(OwnershipStatusInner {
                state: AtomicU8::new(STATE_ACTIVE),
                changed: Notify::new(),
            }),
        }
    }

    pub fn is_healthy(&self) -> bool {
        self.inner.state.load(Ordering::Acquire) == STATE_ACTIVE
    }

    pub async fn wait_until_unhealthy(&self) {
        loop {
            let changed = self.inner.changed.notified();
            if !self.is_healthy() {
                return;
            }
            changed.await;
        }
    }

    pub(crate) fn mark_lost(&self) {
        if self
            .inner
            .state
            .compare_exchange(
                STATE_ACTIVE,
                STATE_LOST,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_ok()
        {
            self.inner.changed.notify_waiters();
        }
    }

    fn mark_released(&self) {
        self.inner.state.store(STATE_RELEASED, Ordering::Release);
        self.inner.changed.notify_waiters();
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FencingContext {
    owner_id: Arc<str>,
    epoch: i64,
    epoch_active: bool,
}

impl FencingContext {
    pub fn owner_id(&self) -> &str {
        &self.owner_id
    }

    pub fn epoch(&self) -> i64 {
        self.epoch
    }

    pub fn epoch_active(&self) -> bool {
        self.epoch_active
    }

    fn legacy() -> Self {
        Self {
            owner_id: "".into(),
            epoch: 0,
            epoch_active: false,
        }
    }

    fn enabled_epoch(owner_id: Arc<str>, epoch: i64) -> Self {
        Self {
            owner_id,
            epoch,
            epoch_active: true,
        }
    }
}

#[derive(Clone, Debug)]
pub struct OwnershipFence {
    context: FencingContext,
    status: OwnershipStatus,
    operation_timeout: Duration,
}

impl OwnershipFence {
    pub(crate) fn new(
        context: FencingContext,
        status: OwnershipStatus,
        operation_timeout: Duration,
    ) -> Self {
        Self {
            context,
            status,
            operation_timeout,
        }
    }

    pub fn context(&self) -> &FencingContext {
        &self.context
    }

    pub fn status(&self) -> OwnershipStatus {
        self.status.clone()
    }

    pub(crate) async fn verify_transaction(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
    ) -> Result<(), OwnershipError> {
        let valid = timeout(
            self.operation_timeout,
            verify_authority(transaction, &self.context, &self.status),
        )
        .await
        .map_err(|_| OwnershipError::OperationTimeout {
            operation: "verify coordinator ownership transaction",
            duration: self.operation_timeout,
        })?
        .map_err(|source| OwnershipError::Database {
            operation: "verify coordinator ownership transaction",
            source,
        })?;
        if !valid {
            self.status.mark_lost();
            return Err(OwnershipError::Lost);
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct CoordinatorOwnership {
    fence: OwnershipFence,
    backend_pid: i32,
    stop: Option<oneshot::Sender<()>>,
    monitor: Option<JoinHandle<Result<(), OwnershipError>>>,
}

impl CoordinatorOwnership {
    pub async fn configure(
        database: &Database,
        database_url: &str,
        enabled: bool,
    ) -> Result<Self, OwnershipError> {
        Self::acquire(
            database,
            database_url,
            enabled,
            database.operation_timeout(),
        )
        .await
    }

    async fn acquire(
        database: &Database,
        database_url: &str,
        enabled: bool,
        operation_timeout: Duration,
    ) -> Result<Self, OwnershipError> {
        let mut connection = timeout(operation_timeout, PgConnection::connect(database_url))
            .await
            .map_err(|_| OwnershipError::OperationTimeout {
                operation: "connect dedicated coordinator ownership connection",
                duration: operation_timeout,
            })?
            .map_err(OwnershipError::Connect)?;
        let owns_coordinator = bounded_query(
            operation_timeout,
            "acquire coordinator ownership advisory lock",
            sqlx::query_scalar::<_, bool>("SELECT pg_try_advisory_lock(hashtextextended($1, 0))")
                .bind(COORDINATOR_OWNERSHIP_LOCK_NAME)
                .fetch_one(&mut connection),
        )
        .await?;
        if !owns_coordinator {
            let _ = timeout(operation_timeout, connection.close()).await;
            return Err(OwnershipError::AlreadyHeld);
        }

        if let Err(error) = bounded_query(
            operation_timeout,
            "acquire coordinator mutation handoff lock",
            sqlx::query("SELECT pg_advisory_lock(hashtextextended($1, 0))")
                .bind(COORDINATOR_MUTATION_LOCK_NAME)
                .execute(&mut connection),
        )
        .await
        {
            abandon_connection(connection, operation_timeout, false).await;
            return Err(error);
        }

        let activated = match bounded_query(
            operation_timeout,
            "inspect coordinator ownership activation",
            sqlx::query_scalar::<_, bool>(
                r#"
                SELECT EXISTS (
                    SELECT 1
                    FROM public.schema_migrations
                    WHERE id = 'coordinator_ownership_activated'
                )
                "#,
            )
            .fetch_one(&mut connection),
        )
        .await
        {
            Ok(activated) => activated,
            Err(error) => {
                abandon_connection(connection, operation_timeout, true).await;
                return Err(error);
            }
        };
        if activated && !enabled {
            abandon_connection(connection, operation_timeout, true).await;
            return Err(OwnershipError::CannotDisableAfterActivation);
        }

        let context = if enabled {
            let owner_id: Arc<str> = Uuid::new_v4().to_string().into();
            let epoch = match bounded_query(
                operation_timeout,
                "advance coordinator ownership epoch",
                sqlx::query_scalar::<_, i64>(
                    r#"
                    INSERT INTO public.coordinator_ownership (
                        singleton,
                        epoch,
                        owner_id,
                        acquired_at
                    )
                    VALUES (TRUE, 1, $1, NOW())
                    ON CONFLICT (singleton) DO UPDATE SET
                        epoch = public.coordinator_ownership.epoch + 1,
                        owner_id = EXCLUDED.owner_id,
                        acquired_at = NOW()
                    RETURNING epoch
                    "#,
                )
                .bind(owner_id.as_ref())
                .fetch_one(&mut connection),
            )
            .await
            {
                Ok(epoch) => epoch,
                Err(error) => {
                    abandon_connection(connection, operation_timeout, true).await;
                    return Err(error);
                }
            };
            if let Err(error) = bounded_query(
                operation_timeout,
                "persist coordinator ownership activation",
                sqlx::query(
                    r#"
                    INSERT INTO public.schema_migrations (id)
                    VALUES ('coordinator_ownership_activated')
                    ON CONFLICT (id) DO NOTHING
                    "#,
                )
                .execute(&mut connection),
            )
            .await
            {
                abandon_connection(connection, operation_timeout, true).await;
                return Err(error);
            }
            FencingContext::enabled_epoch(owner_id, epoch)
        } else {
            FencingContext::legacy()
        };

        let backend_pid = match bounded_query(
            operation_timeout,
            "read coordinator ownership backend PID",
            sqlx::query_scalar!(r#"SELECT pg_backend_pid() AS "backend_pid!""#)
                .fetch_one(&mut connection),
        )
        .await
        {
            Ok(backend_pid) => backend_pid,
            Err(error) => {
                abandon_connection(connection, operation_timeout, true).await;
                return Err(error);
            }
        };

        let status = OwnershipStatus::active();
        let fence = OwnershipFence::new(context, status.clone(), operation_timeout);
        database.activate_ownership_fence(fence.context.clone(), status.clone());
        let mutation_unlocked = match bounded_query(
            operation_timeout,
            "release coordinator mutation handoff lock",
            sqlx::query_scalar::<_, bool>(
                r#"
                SELECT pg_advisory_unlock(hashtextextended($1, 0))
                "#,
            )
            .bind(COORDINATOR_MUTATION_LOCK_NAME)
            .fetch_one(&mut connection),
        )
        .await
        {
            Ok(unlocked) => unlocked,
            Err(error) => {
                status.mark_lost();
                abandon_connection(connection, operation_timeout, true).await;
                return Err(error);
            }
        };
        if !mutation_unlocked {
            status.mark_lost();
            abandon_connection(connection, operation_timeout, false).await;
            return Err(OwnershipError::Lost);
        }

        let (stop_tx, stop_rx) = oneshot::channel();
        let monitor_context = fence.context.clone();
        let monitor = tokio::spawn(monitor_connection(
            connection,
            monitor_context,
            status,
            operation_timeout,
            stop_rx,
        ));
        Ok(Self {
            fence,
            backend_pid,
            stop: Some(stop_tx),
            monitor: Some(monitor),
        })
    }

    pub fn epoch(&self) -> i64 {
        self.fence.context.epoch
    }

    pub fn backend_pid(&self) -> i32 {
        self.backend_pid
    }

    pub fn fence(&self) -> OwnershipFence {
        self.fence.clone()
    }

    pub fn status(&self) -> OwnershipStatus {
        self.fence.status()
    }

    pub async fn release(mut self) -> Result<(), OwnershipError> {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        match self.monitor.take() {
            Some(monitor) => monitor.await.map_err(OwnershipError::MonitorTask)?,
            None => Ok(()),
        }
    }
}

impl Drop for CoordinatorOwnership {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

async fn monitor_connection(
    mut connection: PgConnection,
    context: FencingContext,
    status: OwnershipStatus,
    operation_timeout: Duration,
    mut stop: oneshot::Receiver<()>,
) -> Result<(), OwnershipError> {
    let mut ticker = interval(OWNERSHIP_MONITOR_INTERVAL);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = &mut stop => {
                return clean_release(connection, &context, &status, operation_timeout).await;
            }
            _ = ticker.tick() => {
                let ping = bounded_query(
                    operation_timeout,
                    "monitor coordinator ownership connection",
                    sqlx::query_scalar!(r#"SELECT 1 AS "value!""#)
                        .fetch_one(&mut connection),
                ).await;
                match ping {
                    Ok(1) => {}
                    Ok(_) => {
                        status.mark_lost();
                        return Err(OwnershipError::Lost);
                    }
                    Err(error) => {
                        status.mark_lost();
                        return Err(error);
                    }
                }
            }
        }
    }
}

async fn clean_release(
    mut connection: PgConnection,
    context: &FencingContext,
    status: &OwnershipStatus,
    operation_timeout: Duration,
) -> Result<(), OwnershipError> {
    let clear_result = if context.epoch_active() {
        bounded_query(
            operation_timeout,
            "clear coordinator ownership holder",
            sqlx::query(
                r#"
                UPDATE public.coordinator_ownership
                SET owner_id = ''
                WHERE singleton = TRUE AND epoch = $1 AND owner_id = $2
                "#,
            )
            .bind(context.epoch())
            .bind(context.owner_id())
            .execute(&mut connection),
        )
        .await
        .map(|result| result.rows_affected() == 1)
    } else {
        Ok(true)
    };
    let unlock_result = bounded_query(
        operation_timeout,
        "release coordinator ownership advisory lock",
        sqlx::query_scalar::<_, bool>("SELECT pg_advisory_unlock(hashtextextended($1, 0))")
            .bind(COORDINATOR_OWNERSHIP_LOCK_NAME)
            .fetch_one(&mut connection),
    )
    .await;
    let close_result = timeout(operation_timeout, connection.close()).await;

    let result = match clear_result {
        Ok(true) => match unlock_result {
            Ok(true) => match close_result {
                Ok(Ok(())) => Ok(()),
                Ok(Err(source)) => Err(OwnershipError::Database {
                    operation: "close coordinator ownership connection",
                    source,
                }),
                Err(_) => Err(OwnershipError::OperationTimeout {
                    operation: "close coordinator ownership connection",
                    duration: operation_timeout,
                }),
            },
            Ok(false) => Err(OwnershipError::Lost),
            Err(error) => Err(error),
        },
        Ok(false) => Err(OwnershipError::Lost),
        Err(error) => Err(error),
    };
    if result.is_ok() {
        status.mark_released();
    } else {
        status.mark_lost();
    }
    result
}

async fn abandon_connection(
    mut connection: PgConnection,
    operation_timeout: Duration,
    mutation_locked: bool,
) {
    if mutation_locked {
        let _ = timeout(
            operation_timeout,
            sqlx::query_scalar::<_, bool>("SELECT pg_advisory_unlock(hashtextextended($1, 0))")
                .bind(COORDINATOR_MUTATION_LOCK_NAME)
                .fetch_one(&mut connection),
        )
        .await;
    }
    let _ = timeout(
        operation_timeout,
        sqlx::query_scalar::<_, bool>("SELECT pg_advisory_unlock(hashtextextended($1, 0))")
            .bind(COORDINATOR_OWNERSHIP_LOCK_NAME)
            .fetch_one(&mut connection),
    )
    .await;
    let _ = timeout(operation_timeout, connection.close()).await;
}

async fn bounded_query<T>(
    operation_timeout: Duration,
    operation: &'static str,
    query: impl Future<Output = Result<T, sqlx::Error>>,
) -> Result<T, OwnershipError> {
    timeout(operation_timeout, query)
        .await
        .map_err(|_| OwnershipError::OperationTimeout {
            operation,
            duration: operation_timeout,
        })?
        .map_err(|source| OwnershipError::Database { operation, source })
}
