use std::sync::{
    RwLock,
    atomic::{AtomicBool, Ordering},
};

use sqlx::PgConnection;

use crate::ownership::{FencingContext, OwnershipStatus};

pub(crate) const COORDINATOR_MUTATION_LOCK_NAME: &str = "darkbloom-coordinator-mutation";
pub(crate) const COORDINATOR_OWNERSHIP_LOCK_NAME: &str = "darkbloom-coordinator-owner";

#[derive(Clone, Debug)]
struct Authority {
    context: FencingContext,
    status: OwnershipStatus,
}

/// Fences every serving-pool checkout against coordinator ownership handoff.
///
/// An active checkout holds the shared mutation advisory lock for its complete
/// lifetime. Ownership activation holds the exclusive form while changing the
/// authority marker or epoch, so a successor cannot overlap an old operation.
#[derive(Debug, Default)]
pub(crate) struct PoolMutationFence {
    active: AtomicBool,
    authority: RwLock<Option<Authority>>,
}

impl PoolMutationFence {
    pub(crate) fn activate(&self, context: FencingContext, status: OwnershipStatus) {
        *self
            .authority
            .write()
            .expect("pool mutation fence authority lock poisoned") =
            Some(Authority { context, status });
        self.active.store(true, Ordering::Release);
    }

    pub(crate) fn status(&self) -> Option<OwnershipStatus> {
        self.authority().map(|(_, status)| status)
    }

    pub(crate) fn authority(&self) -> Option<(FencingContext, OwnershipStatus)> {
        self.authority_snapshot()
            .map(|authority| (authority.context, authority.status))
    }

    pub(crate) async fn before_checkout(
        &self,
        connection: &mut PgConnection,
    ) -> Result<bool, sqlx::Error> {
        let Some(authority) = self.authority_snapshot() else {
            return Ok(true);
        };
        sqlx::query("SELECT pg_advisory_lock_shared(hashtextextended($1, 0))")
            .bind(COORDINATOR_MUTATION_LOCK_NAME)
            .execute(&mut *connection)
            .await?;

        match verify_authority(connection, &authority.context, &authority.status).await {
            Ok(true) => Ok(true),
            Ok(false) => {
                unlock_shared(connection).await?;
                Ok(false)
            }
            Err(error) => {
                let _ = unlock_shared(connection).await;
                Err(error)
            }
        }
    }

    pub(crate) async fn after_checkout(
        &self,
        connection: &mut PgConnection,
    ) -> Result<bool, sqlx::Error> {
        if !self.active.load(Ordering::Acquire) {
            return Ok(true);
        }
        // A connection may have been checked out immediately before activation.
        // PostgreSQL returns false (and a warning) when that session held no
        // shared lock; it is still safe to keep the connection when the query
        // itself succeeded.
        unlock_shared(connection).await?;
        Ok(true)
    }

    fn authority_snapshot(&self) -> Option<Authority> {
        if !self.active.load(Ordering::Acquire) {
            return None;
        }
        self.authority
            .read()
            .expect("pool mutation fence authority lock poisoned")
            .clone()
    }
}

pub(crate) async fn verify_authority(
    connection: &mut PgConnection,
    context: &FencingContext,
    status: &OwnershipStatus,
) -> Result<bool, sqlx::Error> {
    if !status.is_healthy() {
        return Ok(false);
    }

    // A false result may be our dedicated owner or a successor that has not
    // reached the handoff point. This checkout already holds the shared
    // mutation lock, so such a successor cannot advance the epoch until the
    // checkout returns; the old operation remains linearized before handoff.
    let acquired_primary: bool =
        sqlx::query_scalar("SELECT pg_try_advisory_lock(hashtextextended($1, 0))")
            .bind(COORDINATOR_OWNERSHIP_LOCK_NAME)
            .fetch_one(&mut *connection)
            .await?;
    if acquired_primary {
        status.mark_lost();
        let _: bool = sqlx::query_scalar("SELECT pg_advisory_unlock(hashtextextended($1, 0))")
            .bind(COORDINATOR_OWNERSHIP_LOCK_NAME)
            .fetch_one(&mut *connection)
            .await?;
        return Ok(false);
    }

    let valid = if context.epoch_active() {
        sqlx::query_scalar::<_, bool>(
            r#"
            SELECT EXISTS (
                SELECT 1
                FROM public.coordinator_ownership
                WHERE singleton = TRUE AND epoch = $1 AND owner_id = $2
            )
            "#,
        )
        .bind(context.epoch())
        .bind(context.owner_id())
        .fetch_one(&mut *connection)
        .await?
    } else {
        sqlx::query_scalar::<_, bool>(
            r#"
            SELECT NOT EXISTS (
                SELECT 1
                FROM public.schema_migrations
                WHERE id = 'coordinator_ownership_activated'
            )
            "#,
        )
        .fetch_one(&mut *connection)
        .await?
    };
    let valid = valid && status.is_healthy();
    if !valid {
        status.mark_lost();
    }
    Ok(valid)
}

async fn unlock_shared(connection: &mut PgConnection) -> Result<(), sqlx::Error> {
    let _: bool = sqlx::query_scalar("SELECT pg_advisory_unlock_shared(hashtextextended($1, 0))")
        .bind(COORDINATOR_MUTATION_LOCK_NAME)
        .fetch_one(connection)
        .await?;
    Ok(())
}
