//! Single-active coordinator ownership (plan §20).
//!
//! Ownership is BOTH:
//!
//! 1. A live PostgreSQL session advisory lock ([`OWNERSHIP_LOCK_KEY`]) held on
//!    a DEDICATED connection. Readiness requires that connection to stay
//!    healthy; if it drops, the lock is gone and another coordinator may
//!    acquire ownership.
//! 2. A persistent fencing epoch in `rust_coord.coordinator_ownership`,
//!    incremented on acquisition. Every authoritative SQL mutation compares
//!    the expected active epoch inside the same transaction (zero affected
//!    rows means immediate ownership loss) — recording an epoch without a
//!    transactional compare is not a fence.
//!
//! The rollback-safe Go build must acquire the SAME advisory lock key and
//! bump the same epoch before enabling workers (plan §4.6, §26.1 step 10).

use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::time::Duration;

use sqlx::postgres::PgConnectOptions;
use sqlx::{ConnectOptions, Connection, PgConnection, Row};
use tokio::sync::{oneshot, watch};

use darkbloom_core::ids::CoordinatorEpoch;

/// Global advisory lock key shared by every coordinator implementation
/// (Rust and the rollback-safe Go build). ASCII `"darkcoor"` as big-endian
/// i64; the value itself is arbitrary but must never change.
pub const OWNERSHIP_LOCK_KEY: i64 = 0x6461_726b_636f_6f72;

/// How often the keeper pings the lock-holding connection and refreshes
/// `renewed_at`.
const HEALTH_INTERVAL: Duration = Duration::from_secs(5);

/// Hard bound on one keeper ping. A half-open (black-holed) TCP connection
/// produces neither data nor an error — without this bound the ping would
/// hang forever and the health watch would never flip, leaving a coordinator
/// that no longer holds the advisory lock reporting ready (plan §20).
const PING_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, thiserror::Error)]
pub enum OwnershipError {
    #[error("invalid database URL: {0}")]
    InvalidUrl(String),
    #[error("ownership database error: {0}")]
    Sqlx(#[from] sqlx::Error),
    #[error("ownership keeper task is gone")]
    KeeperGone,
}

/// Live handle to acquired ownership.
///
/// Dropping the guard does NOT release the lock gracefully (the dedicated
/// connection dies with the process); call [`OwnershipGuard::release`] as the
/// final mutating action of a graceful shutdown (plan §26.1 step 7).
pub struct OwnershipGuard {
    epoch: CoordinatorEpoch,
    /// Same epoch as an atomic for cheap sharing with the ledger's
    /// fence-comparing transactions.
    epoch_shared: Arc<AtomicU64>,
    healthy_rx: watch::Receiver<bool>,
    release_tx: Option<oneshot::Sender<oneshot::Sender<()>>>,
    keeper: Option<tokio::task::JoinHandle<()>>,
}

impl OwnershipGuard {
    /// Takes the global advisory lock on a dedicated connection (blocking
    /// until it is free), then increments and returns the fencing epoch.
    ///
    /// `database_url` is used to open the dedicated connection — ownership
    /// must NOT share the request pool: pool churn would silently drop the
    /// session lock.
    pub async fn acquire(database_url: &str, holder: &str) -> Result<Self, OwnershipError> {
        let options: PgConnectOptions = database_url
            .parse()
            .map_err(|e: sqlx::Error| OwnershipError::InvalidUrl(e.to_string()))?;
        let mut conn = options.disable_statement_logging().connect().await?;

        // Session-scoped: held until this connection closes.
        sqlx::query("SELECT pg_advisory_lock($1)")
            .bind(OWNERSHIP_LOCK_KEY)
            .execute(&mut conn)
            .await?;

        let row = sqlx::query(
            "UPDATE rust_coord.coordinator_ownership \
             SET fencing_epoch = fencing_epoch + 1, holder = $1, \
                 acquired_at = NOW(), renewed_at = NOW() \
             WHERE id = 1 \
             RETURNING fencing_epoch",
        )
        .bind(holder)
        .fetch_one(&mut conn)
        .await?;
        let epoch_i64: i64 = row.get("fencing_epoch");
        let epoch = CoordinatorEpoch::new(u64::try_from(epoch_i64).unwrap_or(0));

        tracing::info!(
            epoch = epoch.get(),
            holder,
            "coordinator ownership acquired"
        );

        let (healthy_tx, healthy_rx) = watch::channel(true);
        let (release_tx, release_rx) = oneshot::channel();
        let keeper = tokio::spawn(keeper_loop(conn, healthy_tx, release_rx));

        Ok(Self {
            epoch,
            epoch_shared: Arc::new(AtomicU64::new(epoch.get())),
            healthy_rx,
            release_tx: Some(release_tx),
            keeper: Some(keeper),
        })
    }

    /// The fencing epoch this process owns. Every financial command records
    /// and compares it (plan §20).
    pub fn epoch(&self) -> CoordinatorEpoch {
        self.epoch
    }

    /// Shared epoch cell for components (ledger) that fence mutations without
    /// threading the guard through.
    pub fn epoch_cell(&self) -> Arc<AtomicU64> {
        Arc::clone(&self.epoch_shared)
    }

    /// True while the lock-holding connection is alive. Readiness gate input.
    pub fn is_healthy(&self) -> bool {
        *self.healthy_rx.borrow()
    }

    /// Watch channel that flips to `false` when the lock-holding connection
    /// drops. Ownership loss must immediately stop admission (plan §20).
    pub fn health_watch(&self) -> watch::Receiver<bool> {
        self.healthy_rx.clone()
    }

    /// Graceful release: the FINAL mutating action of shutdown (plan §26.1
    /// step 7). Unlocks the advisory lock and closes the dedicated
    /// connection.
    pub async fn release(mut self) -> Result<(), OwnershipError> {
        let (done_tx, done_rx) = oneshot::channel();
        let release_tx = self.release_tx.take().ok_or(OwnershipError::KeeperGone)?;
        release_tx
            .send(done_tx)
            .map_err(|_| OwnershipError::KeeperGone)?;
        done_rx.await.map_err(|_| OwnershipError::KeeperGone)?;
        if let Some(keeper) = self.keeper.take() {
            let _ = keeper.await;
        }
        tracing::info!(epoch = self.epoch.get(), "coordinator ownership released");
        Ok(())
    }
}

/// Owns the dedicated lock connection: pings it on an interval (refreshing
/// `renewed_at`), flips the health watch to `false` when the connection
/// fails OR a ping exceeds [`PING_TIMEOUT`] (half-open connection), and
/// performs the graceful unlock when asked.
///
/// Once health flips false it stays false permanently: the keeper returns
/// and the guard NEVER reconnects or re-acquires. A reconnect would be a
/// NEW lock session — another coordinator may have taken ownership in the
/// gap, and re-acquiring would mint a new fencing epoch this process's
/// in-flight state was not built under. The plan's answer to ownership loss
/// is a supervised process restart (plan §20), and `bootstrap::App::serve`
/// begins the ordered shutdown the moment this watch flips.
async fn keeper_loop(
    mut conn: PgConnection,
    healthy_tx: watch::Sender<bool>,
    mut release_rx: oneshot::Receiver<oneshot::Sender<()>>,
) {
    let mut ticker = tokio::time::interval(HEALTH_INTERVAL);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            done = &mut release_rx => {
                let unlock = tokio::time::timeout(
                    PING_TIMEOUT,
                    sqlx::query("SELECT pg_advisory_unlock($1)")
                        .bind(OWNERSHIP_LOCK_KEY)
                        .execute(&mut conn),
                )
                .await;
                match unlock {
                    Ok(Ok(_)) => {}
                    Ok(Err(err)) => tracing::warn!(
                        error = %err,
                        "advisory unlock failed; closing connection anyway"
                    ),
                    Err(_) => tracing::warn!(
                        "advisory unlock timed out; closing connection anyway"
                    ),
                }
                let _ = conn.close().await;
                let _ = healthy_tx.send(false);
                if let Ok(done_tx) = done {
                    let _ = done_tx.send(());
                }
                return;
            }
            _ = ticker.tick() => {
                let ping = tokio::time::timeout(
                    PING_TIMEOUT,
                    sqlx::query(
                        "UPDATE rust_coord.coordinator_ownership SET renewed_at = NOW() WHERE id = 1",
                    )
                    .execute(&mut conn),
                )
                .await;
                match ping {
                    Ok(Ok(_)) => {}
                    Ok(Err(err)) => {
                        tracing::error!(
                            error = %err,
                            "ownership lock connection unhealthy — readiness gate closing (plan §20)"
                        );
                        let _ = healthy_tx.send(false);
                        return;
                    }
                    Err(_) => {
                        tracing::error!(
                            timeout_ms = PING_TIMEOUT.as_millis() as u64,
                            "ownership ping timed out (half-open lock connection) — \
                             readiness gate closing (plan §20)"
                        );
                        let _ = healthy_tx.send(false);
                        return;
                    }
                }
            }
        }
    }
}
