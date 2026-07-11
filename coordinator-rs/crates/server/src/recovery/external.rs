use std::{sync::Arc, time::Duration};

use darkbloom_coordinator_core::ids::Digest;
use serde_json::Value;
use sqlx::FromRow;
use uuid::Uuid;

use super::RecoveryService;
use crate::ledger::types::{ExternalEventId, LedgerError, OperationKey, OutboxId, Version};

const MAX_CLAIM_BATCH: u32 = 100;
const MAX_LEASE_MILLIS: u64 = 300_000;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExternalEventLease {
    pub external_event_id: ExternalEventId,
    pub source: Arc<str>,
    pub event_id: Arc<str>,
    pub event_kind: Arc<str>,
    pub payload_digest: Digest,
    pub payload: Value,
    pub version: Version,
    pub lease_until_epoch_millis: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutboxLease {
    pub outbox_id: OutboxId,
    pub operation_key: OperationKey,
    pub kind: Arc<str>,
    pub payload_digest: Digest,
    pub payload: Value,
    pub attempts: u32,
    pub max_attempts: u32,
    pub version: Version,
    pub lease_until_epoch_millis: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExternalDisposition {
    Applied,
    Rejected,
    Ignored,
    Failed,
}

impl ExternalDisposition {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Applied => "applied",
            Self::Rejected => "rejected",
            Self::Ignored => "ignored",
            Self::Failed => "failed",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutboxDisposition {
    Delivered,
    Retry,
    Failed,
    Cancelled,
}

impl RecoveryService {
    /// Claims unknown or abandoned inbound events without blocking peers.
    pub async fn claim_external_events(
        &self,
        worker_id: Uuid,
        limit: u32,
        lease_for: Duration,
    ) -> Result<Vec<ExternalEventLease>, LedgerError> {
        let lease_millis = validate_claim(worker_id, limit, lease_for)?;
        let authority = self.db.authority()?;
        let rows = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    ExternalLeaseRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    candidates AS MATERIALIZED (
                        SELECT events.external_event_id
                        FROM rust_coord.external_events AS events
                        WHERE events.status IN ('pending', 'processing')
                          AND (
                              events.worker_owner IS NULL
                              OR events.lease_until <= NOW()
                          )
                        ORDER BY events.received_at, events.external_event_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $4
                    ),
                    claimed AS (
                        UPDATE rust_coord.external_events AS events
                        SET
                            status = 'processing',
                            owner_epoch = $2,
                            worker_owner = $3,
                            lease_until =
                                NOW() + ($5::BIGINT * INTERVAL '1 millisecond'),
                            version = events.version + 1,
                            updated_at = NOW()
                        FROM candidates, authority
                        WHERE events.external_event_id =
                              candidates.external_event_id
                        RETURNING
                            events.external_event_id,
                            events.source,
                            events.event_id,
                            events.event_kind,
                            events.payload_digest,
                            events.payload,
                            events.version,
                            (
                                EXTRACT(EPOCH FROM events.lease_until) * 1000
                            )::BIGINT AS lease_until_epoch_millis
                    )
                    SELECT *
                    FROM claimed
                    ORDER BY external_event_id
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    worker_id,
                    i64::from(limit),
                    lease_millis,
                )
                .fetch_all(self.db.pool()),
            )
            .await?;
        if rows.is_empty() {
            self.db.verify_authority(&authority).await?;
        }
        rows.into_iter().map(ExternalLeaseRow::into_lease).collect()
    }

    /// Claims due outbox calls with bounded attempts and SKIP LOCKED.
    pub async fn claim_outbox(
        &self,
        worker_id: Uuid,
        limit: u32,
        lease_for: Duration,
    ) -> Result<Vec<OutboxLease>, LedgerError> {
        let lease_millis = validate_claim(worker_id, limit, lease_for)?;
        let authority = self.db.authority()?;
        let rows = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    OutboxLeaseRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    candidates AS MATERIALIZED (
                        SELECT outbox.outbox_id
                        FROM rust_coord.outbox
                        WHERE outbox.status IN ('pending', 'processing')
                          AND outbox.attempts < outbox.max_attempts
                          AND outbox.next_attempt_at <= NOW()
                          AND (
                              outbox.worker_owner IS NULL
                              OR outbox.lease_until <= NOW()
                          )
                        ORDER BY outbox.next_attempt_at, outbox.outbox_id
                        FOR UPDATE SKIP LOCKED
                        LIMIT $4
                    ),
                    claimed AS (
                        UPDATE rust_coord.outbox
                        SET
                            status = 'processing',
                            owner_epoch = $2,
                            worker_owner = $3,
                            lease_until =
                                NOW() + ($5::BIGINT * INTERVAL '1 millisecond'),
                            attempts = outbox.attempts + 1,
                            version = outbox.version + 1,
                            updated_at = NOW()
                        FROM candidates, authority
                        WHERE outbox.outbox_id = candidates.outbox_id
                        RETURNING
                            outbox.outbox_id,
                            outbox.operation_key,
                            outbox.kind,
                            outbox.payload_digest,
                            outbox.payload,
                            outbox.attempts,
                            outbox.max_attempts,
                            outbox.version,
                            (
                                EXTRACT(EPOCH FROM outbox.lease_until) * 1000
                            )::BIGINT AS lease_until_epoch_millis
                    )
                    SELECT *
                    FROM claimed
                    ORDER BY outbox_id
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    worker_id,
                    i64::from(limit),
                    lease_millis,
                )
                .fetch_all(self.db.pool()),
            )
            .await?;
        if rows.is_empty() {
            self.db.verify_authority(&authority).await?;
        }
        rows.into_iter().map(OutboxLeaseRow::into_lease).collect()
    }

    pub async fn complete_external_event(
        &self,
        worker_id: Uuid,
        event_id: ExternalEventId,
        version: Version,
        disposition: ExternalDisposition,
    ) -> Result<Version, LedgerError> {
        if worker_id.is_nil() {
            return Err(crate::ledger::types::InputError::NilId("worker id").into());
        }
        let authority = self.db.authority()?;
        let next = self
            .db
            .bounded(
                sqlx::query_scalar_unchecked!(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    UPDATE rust_coord.external_events AS events
                    SET
                        status = $6,
                        worker_owner = NULL,
                        lease_until = NULL,
                        version = events.version + 1,
                        updated_at = NOW(),
                        processed_at = NOW()
                    FROM authority
                    WHERE events.external_event_id = $3
                      AND events.owner_epoch = $2
                      AND events.worker_owner = $4
                      AND events.version = $5
                      AND events.status = 'processing'
                      AND events.lease_until > NOW()
                    RETURNING events.version
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    event_id.as_uuid(),
                    worker_id,
                    version.as_i64(),
                    disposition.as_str(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(next) = next else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::StaleVersion);
        };
        Version::from_database(next)
    }

    pub async fn complete_outbox(
        &self,
        worker_id: Uuid,
        outbox_id: OutboxId,
        version: Version,
        disposition: OutboxDisposition,
        retry_after: Duration,
    ) -> Result<Version, LedgerError> {
        if worker_id.is_nil() {
            return Err(crate::ledger::types::InputError::NilId("worker id").into());
        }
        let retry_millis = i64::try_from(retry_after.as_millis())
            .map_err(|_| crate::ledger::types::InputError::ArithmeticOverflow)?;
        let (status, delivered) = match disposition {
            OutboxDisposition::Delivered => ("delivered", true),
            OutboxDisposition::Retry => ("pending", false),
            OutboxDisposition::Failed => ("failed", false),
            OutboxDisposition::Cancelled => ("cancelled", false),
        };
        let authority = self.db.authority()?;
        let next = self
            .db
            .bounded(
                sqlx::query_scalar_unchecked!(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    UPDATE rust_coord.outbox
                    SET
                        status = CASE
                            WHEN $6 = 'pending'
                                 AND outbox.attempts >= outbox.max_attempts
                            THEN 'failed'
                            ELSE $6
                        END,
                        worker_owner = NULL,
                        lease_until = NULL,
                        next_attempt_at = CASE
                            WHEN $6 = 'pending'
                                 AND outbox.attempts < outbox.max_attempts
                            THEN NOW() + ($7::BIGINT * INTERVAL '1 millisecond')
                            ELSE outbox.next_attempt_at
                        END,
                        version = outbox.version + 1,
                        updated_at = NOW(),
                        delivered_at = CASE WHEN $8 THEN NOW() ELSE NULL END
                    FROM authority
                    WHERE outbox.outbox_id = $3
                      AND outbox.owner_epoch = $2
                      AND outbox.worker_owner = $4
                      AND outbox.version = $5
                      AND outbox.status = 'processing'
                      AND outbox.lease_until > NOW()
                    RETURNING outbox.version
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    outbox_id.as_uuid(),
                    worker_id,
                    version.as_i64(),
                    status,
                    retry_millis,
                    delivered,
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(next) = next else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::StaleVersion);
        };
        Version::from_database(next)
    }
}

#[derive(Debug, FromRow)]
struct ExternalLeaseRow {
    external_event_id: Uuid,
    source: String,
    event_id: String,
    event_kind: String,
    payload_digest: Vec<u8>,
    payload: Value,
    version: i64,
    lease_until_epoch_millis: i64,
}

impl ExternalLeaseRow {
    fn into_lease(self) -> Result<ExternalEventLease, LedgerError> {
        Ok(ExternalEventLease {
            external_event_id: ExternalEventId::new(self.external_event_id)
                .map_err(|_| LedgerError::CorruptData("stored external event id is nil"))?,
            source: self.source.into(),
            event_id: self.event_id.into(),
            event_kind: self.event_kind.into(),
            payload_digest: Digest::try_from(self.payload_digest.as_slice())
                .map_err(|_| LedgerError::CorruptData("stored payload digest width"))?,
            payload: self.payload,
            version: Version::from_database(self.version)?,
            lease_until_epoch_millis: self.lease_until_epoch_millis,
        })
    }
}

#[derive(Debug, FromRow)]
struct OutboxLeaseRow {
    outbox_id: Uuid,
    operation_key: String,
    kind: String,
    payload_digest: Vec<u8>,
    payload: Value,
    attempts: i32,
    max_attempts: i32,
    version: i64,
    lease_until_epoch_millis: i64,
}

impl OutboxLeaseRow {
    fn into_lease(self) -> Result<OutboxLease, LedgerError> {
        Ok(OutboxLease {
            outbox_id: OutboxId::new(self.outbox_id)
                .map_err(|_| LedgerError::CorruptData("stored outbox id is nil"))?,
            operation_key: OperationKey::new(self.operation_key).map_err(LedgerError::Invalid)?,
            kind: self.kind.into(),
            payload_digest: Digest::try_from(self.payload_digest.as_slice())
                .map_err(|_| LedgerError::CorruptData("stored payload digest width"))?,
            payload: self.payload,
            attempts: u32::try_from(self.attempts)
                .map_err(|_| LedgerError::CorruptData("negative outbox attempts"))?,
            max_attempts: u32::try_from(self.max_attempts)
                .map_err(|_| LedgerError::CorruptData("negative outbox max attempts"))?,
            version: Version::from_database(self.version)?,
            lease_until_epoch_millis: self.lease_until_epoch_millis,
        })
    }
}

fn validate_claim(worker_id: Uuid, limit: u32, lease_for: Duration) -> Result<i64, LedgerError> {
    if worker_id.is_nil() {
        return Err(crate::ledger::types::InputError::NilId("worker id").into());
    }
    if limit == 0 || limit > MAX_CLAIM_BATCH {
        return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
    }
    let millis = u64::try_from(lease_for.as_millis())
        .map_err(|_| crate::ledger::types::InputError::ArithmeticOverflow)?;
    if millis == 0 || millis > MAX_LEASE_MILLIS {
        return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
    }
    i64::try_from(millis).map_err(|_| crate::ledger::types::InputError::ArithmeticOverflow.into())
}
