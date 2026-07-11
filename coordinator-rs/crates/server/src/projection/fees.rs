use std::{sync::Arc, time::Duration};

use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    database::Database,
    db::ownership::DurableDatabase,
    ledger::types::{AccountId, JobId, LedgerAmount, LedgerError, OperationKey, Version},
};

const MAX_FEE_BATCH: u32 = 100;
const MAX_LEASE_MILLIS: u64 = 300_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FeeKind {
    Platform,
    Referral,
}

impl FeeKind {
    fn from_database(value: &str) -> Result<Self, LedgerError> {
        match value {
            "platform" => Ok(Self::Platform),
            "referral" => Ok(Self::Referral),
            _ => Err(LedgerError::CorruptData("unknown fee allocation kind")),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FeeAllocation {
    pub allocation_id: Uuid,
    pub sequence: i64,
    pub operation_key: OperationKey,
    pub job_id: JobId,
    pub kind: FeeKind,
    pub source_account_id: AccountId,
    pub beneficiary_account_id: AccountId,
    pub amount: LedgerAmount,
    pub version: Version,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FeeBatch {
    pub projection_name: Arc<str>,
    pub checkpoint_version: Version,
    pub lease_until_epoch_millis: i64,
    pub allocations: Vec<FeeAllocation>,
}

#[derive(Clone, Debug)]
pub struct FeeProjectionService {
    db: DurableDatabase,
}

impl FeeProjectionService {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self {
            db: DurableDatabase::new(database),
        }
    }

    /// Claims one checkpoint and a bounded ordered allocation page.
    pub async fn claim(
        &self,
        projection_name: &str,
        worker_id: Uuid,
        limit: u32,
        lease_for: Duration,
    ) -> Result<FeeBatch, LedgerError> {
        validate_claim(projection_name, worker_id, limit, lease_for)?;
        let lease_millis = i64::try_from(lease_for.as_millis())
            .map_err(|_| crate::ledger::types::InputError::ArithmeticOverflow)?;
        let authority = self.db.authority()?;
        let rows = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    FeeClaimRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    checkpoint_claim AS (
                        INSERT INTO rust_coord.fee_projection_checkpoints (
                            projection_name,
                            status,
                            owner_epoch,
                            version,
                            worker_owner,
                            lease_until
                        )
                        SELECT
                            $3,
                            'running',
                            $2,
                            1,
                            $4,
                            NOW() + ($6::BIGINT * INTERVAL '1 millisecond')
                        FROM authority
                        ON CONFLICT (projection_name) DO UPDATE SET
                            status = 'running',
                            owner_epoch = $2,
                            version =
                                fee_projection_checkpoints.version + 1,
                            worker_owner = $4,
                            lease_until =
                                NOW() + ($6::BIGINT * INTERVAL '1 millisecond'),
                            updated_at = NOW()
                        WHERE fee_projection_checkpoints.status <> 'running'
                           OR fee_projection_checkpoints.lease_until <= NOW()
                        RETURNING
                            projection_name,
                            last_allocation_sequence,
                            version,
                            (
                                EXTRACT(EPOCH FROM lease_until) * 1000
                            )::BIGINT AS lease_until_epoch_millis
                    ),
                    candidates AS MATERIALIZED (
                        SELECT allocations.allocation_id
                        FROM rust_coord.fee_allocations AS allocations
                        CROSS JOIN checkpoint_claim
                        WHERE allocations.allocation_sequence
                              > checkpoint_claim.last_allocation_sequence
                          AND allocations.status IN (
                              'pending',
                              'processing',
                              'failed'
                          )
                          AND (
                              allocations.worker_owner IS NULL
                              OR allocations.lease_until <= NOW()
                          )
                        ORDER BY
                            allocations.allocation_sequence,
                            allocations.allocation_id
                        FOR UPDATE OF allocations SKIP LOCKED
                        LIMIT $5
                    ),
                    allocation_claim AS (
                        UPDATE rust_coord.fee_allocations AS allocations
                        SET
                            status = 'processing',
                            owner_epoch = $2,
                            worker_owner = $4,
                            lease_until =
                                NOW() + ($6::BIGINT * INTERVAL '1 millisecond'),
                            version = allocations.version + 1,
                            updated_at = NOW()
                        FROM candidates, checkpoint_claim
                        WHERE allocations.allocation_id =
                              candidates.allocation_id
                        RETURNING
                            allocations.allocation_id,
                            allocations.allocation_sequence,
                            allocations.operation_key,
                            allocations.job_id,
                            allocations.kind,
                            allocations.source_account_id,
                            allocations.beneficiary_account_id,
                            allocations.amount_micro_usd,
                            allocations.version
                    )
                    SELECT
                        checkpoint_claim.projection_name,
                        checkpoint_claim.version AS checkpoint_version,
                        checkpoint_claim.lease_until_epoch_millis,
                        allocation_claim.allocation_id,
                        allocation_claim.allocation_sequence,
                        allocation_claim.operation_key,
                        allocation_claim.job_id,
                        allocation_claim.kind,
                        allocation_claim.source_account_id,
                        allocation_claim.beneficiary_account_id,
                        allocation_claim.amount_micro_usd,
                        allocation_claim.version AS allocation_version
                    FROM checkpoint_claim
                    LEFT JOIN allocation_claim ON TRUE
                    ORDER BY allocation_claim.allocation_sequence,
                             allocation_claim.allocation_id
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    projection_name,
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
        fee_batch(rows)
    }

    /// Marks exactly the claimed allocation versions projected and advances
    /// the checkpoint to the final ordered allocation.
    pub async fn complete(
        &self,
        batch: &FeeBatch,
        worker_id: Uuid,
    ) -> Result<Version, LedgerError> {
        if worker_id.is_nil() {
            return Err(crate::ledger::types::InputError::NilId("worker id").into());
        }
        let ids: Vec<Uuid> = batch
            .allocations
            .iter()
            .map(|allocation| allocation.allocation_id)
            .collect();
        let versions: Vec<i64> = batch
            .allocations
            .iter()
            .map(|allocation| allocation.version.as_i64())
            .collect();
        let final_sequence = batch
            .allocations
            .last()
            .map_or(0, |allocation| allocation.sequence);
        let final_id = batch
            .allocations
            .last()
            .map(|allocation| allocation.allocation_id);
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
                    ),
                    expected AS MATERIALIZED (
                        SELECT allocation_id, version
                        FROM UNNEST($6::UUID[], $7::BIGINT[])
                             AS rows(allocation_id, version)
                    ),
                    checkpoint AS MATERIALIZED (
                        SELECT checkpoints.projection_name
                        FROM rust_coord.fee_projection_checkpoints
                             AS checkpoints
                        CROSS JOIN authority
                        WHERE checkpoints.projection_name = $3
                          AND checkpoints.owner_epoch = $2
                          AND checkpoints.worker_owner = $4
                          AND checkpoints.version = $5
                          AND checkpoints.status = 'running'
                          AND checkpoints.lease_until > NOW()
                        FOR UPDATE OF checkpoints
                    ),
                    locked_allocations AS MATERIALIZED (
                        SELECT allocations.allocation_id
                        FROM rust_coord.fee_allocations AS allocations
                        JOIN expected
                          ON expected.allocation_id =
                             allocations.allocation_id
                         AND expected.version = allocations.version
                        CROSS JOIN checkpoint
                        WHERE allocations.owner_epoch = $2
                          AND allocations.worker_owner = $4
                          AND allocations.status = 'processing'
                          AND allocations.lease_until > NOW()
                        ORDER BY allocations.allocation_id
                        FOR UPDATE OF allocations
                    ),
                    exact AS MATERIALIZED (
                        SELECT 1
                        FROM checkpoint
                        WHERE
                            (SELECT COUNT(*) FROM locked_allocations)
                            = CARDINALITY($6::UUID[])
                    ),
                    allocations_update AS (
                        UPDATE rust_coord.fee_allocations AS allocations
                        SET
                            status = 'projected',
                            worker_owner = NULL,
                            lease_until = NULL,
                            version = allocations.version + 1,
                            updated_at = NOW(),
                            projected_at = NOW()
                        FROM locked_allocations, exact
                        WHERE allocations.allocation_id =
                              locked_allocations.allocation_id
                        RETURNING allocations.allocation_id
                    )
                    UPDATE rust_coord.fee_projection_checkpoints AS checkpoints
                    SET
                        last_allocation_sequence = CASE
                            WHEN $8::BIGINT > 0
                            THEN $8
                            ELSE checkpoints.last_allocation_sequence
                        END,
                        last_allocation_id = CASE
                            WHEN $8::BIGINT > 0
                            THEN $9
                            ELSE checkpoints.last_allocation_id
                        END,
                        status = 'idle',
                        worker_owner = NULL,
                        lease_until = NULL,
                        version = checkpoints.version + 1,
                        updated_at = NOW()
                    FROM exact
                    WHERE checkpoints.projection_name = $3
                      AND checkpoints.owner_epoch = $2
                      AND checkpoints.worker_owner = $4
                      AND checkpoints.version = $5
                      AND checkpoints.status = 'running'
                      AND checkpoints.lease_until > NOW()
                    RETURNING checkpoints.version
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    batch.projection_name.as_ref(),
                    worker_id,
                    batch.checkpoint_version.as_i64(),
                    ids,
                    versions,
                    final_sequence,
                    final_id,
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
struct FeeClaimRow {
    projection_name: String,
    checkpoint_version: i64,
    lease_until_epoch_millis: i64,
    allocation_id: Option<Uuid>,
    allocation_sequence: Option<i64>,
    operation_key: Option<String>,
    job_id: Option<Uuid>,
    kind: Option<String>,
    source_account_id: Option<String>,
    beneficiary_account_id: Option<String>,
    amount_micro_usd: Option<i64>,
    allocation_version: Option<i64>,
}

fn fee_batch(rows: Vec<FeeClaimRow>) -> Result<FeeBatch, LedgerError> {
    let first = rows.first().ok_or(LedgerError::StaleVersion)?;
    let mut allocations = Vec::with_capacity(rows.len());
    for row in &rows {
        let Some(allocation_id) = row.allocation_id else {
            continue;
        };
        allocations.push(FeeAllocation {
            allocation_id,
            sequence: row
                .allocation_sequence
                .ok_or(LedgerError::CorruptData("missing allocation sequence"))?,
            operation_key: OperationKey::new(
                row.operation_key
                    .clone()
                    .ok_or(LedgerError::CorruptData("missing allocation key"))?,
            )
            .map_err(LedgerError::Invalid)?,
            job_id: JobId::new(
                row.job_id
                    .ok_or(LedgerError::CorruptData("missing allocation job"))?,
            )
            .map_err(|_| LedgerError::CorruptData("stored allocation job id is nil"))?,
            kind: FeeKind::from_database(
                row.kind
                    .as_deref()
                    .ok_or(LedgerError::CorruptData("missing allocation kind"))?,
            )?,
            source_account_id: AccountId::new(
                row.source_account_id
                    .clone()
                    .ok_or(LedgerError::CorruptData("missing allocation source"))?,
            )
            .map_err(LedgerError::Invalid)?,
            beneficiary_account_id: AccountId::new(
                row.beneficiary_account_id
                    .clone()
                    .ok_or(LedgerError::CorruptData("missing allocation beneficiary"))?,
            )
            .map_err(LedgerError::Invalid)?,
            amount: LedgerAmount::from_i64(
                row.amount_micro_usd
                    .ok_or(LedgerError::CorruptData("missing allocation amount"))?,
            )
            .map_err(LedgerError::Invalid)?,
            version: Version::from_database(
                row.allocation_version
                    .ok_or(LedgerError::CorruptData("missing allocation version"))?,
            )?,
        });
    }
    Ok(FeeBatch {
        projection_name: first.projection_name.clone().into(),
        checkpoint_version: Version::from_database(first.checkpoint_version)?,
        lease_until_epoch_millis: first.lease_until_epoch_millis,
        allocations,
    })
}

fn validate_claim(
    projection_name: &str,
    worker_id: Uuid,
    limit: u32,
    lease_for: Duration,
) -> Result<(), LedgerError> {
    if projection_name.is_empty()
        || projection_name.len() > 256
        || projection_name.trim() != projection_name
        || projection_name.chars().any(char::is_control)
    {
        return Err(crate::ledger::types::InputError::Empty("projection name").into());
    }
    if worker_id.is_nil() {
        return Err(crate::ledger::types::InputError::NilId("worker id").into());
    }
    if limit == 0 || limit > MAX_FEE_BATCH {
        return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
    }
    let millis = u64::try_from(lease_for.as_millis())
        .map_err(|_| crate::ledger::types::InputError::ArithmeticOverflow)?;
    if millis == 0 || millis > MAX_LEASE_MILLIS {
        return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
    }
    Ok(())
}
