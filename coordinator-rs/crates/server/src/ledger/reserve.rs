use darkbloom_coordinator_core::ids::Digest;
use serde_json::Value;
use sqlx::FromRow;

use super::{
    LedgerService,
    types::{
        JobId, JobState, LedgerAmount, LedgerError, MutationDisposition, ReservationResult,
        ReserveRequest, Version,
    },
};
use crate::db::ownership::{Authority, OperationRecord};

impl LedgerService {
    /// Resolves an ambiguous reserve outcome by immutable operation identity.
    /// Absence is reported as commit-unknown rather than being retried.
    pub async fn reconcile_reserve(
        &self,
        request: &ReserveRequest,
    ) -> Result<ReservationResult, LedgerError> {
        let authority = self.db.authority()?;
        self.resolve_reserve(&authority, request, true).await
    }

    /// Creates the provisional durable job and debits its exact base
    /// reservation in one data-modifying CTE statement.
    pub async fn reserve(
        &self,
        request: &ReserveRequest,
    ) -> Result<ReservationResult, LedgerError> {
        if request.request_id.is_nil() {
            return Err(crate::ledger::types::InputError::NilId("request id").into());
        }
        if request.amount.as_i64() == 0 {
            return Err(crate::ledger::types::InputError::Empty("base reservation").into());
        }
        let authority = self.db.authority()?;
        let mut attempt = 0;
        loop {
            authority.ensure_healthy()?;
            let result = self.reserve_once(&authority, request).await;
            match result {
                Ok(Some(row)) => return reservation_from_row(row, MutationDisposition::Applied),
                Ok(None) => return self.resolve_reserve(&authority, request, false).await,
                Err(LedgerError::Database(ref source))
                    if crate::db::ownership::DurableDatabase::may_retry(attempt, source) =>
                {
                    self.db.retry_delay(attempt).await;
                    attempt += 1;
                }
                Err(LedgerError::Database(ref source))
                    if crate::db::ownership::DurableDatabase::is_operation_conflict(source) =>
                {
                    return self.resolve_reserve_conflict(&authority, request).await;
                }
                Err(error) if crate::db::ownership::DurableDatabase::is_ambiguous(&error) => {
                    return self.resolve_reserve(&authority, request, true).await;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn reserve_once(
        &self,
        authority: &Authority,
        request: &ReserveRequest,
    ) -> Result<Option<ReservationRow>, LedgerError> {
        self.db
            .bounded(
                sqlx::query_as_unchecked!(
                    ReservationRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    account AS MATERIALIZED (
                        SELECT
                            account_id,
                            balance_micro_usd,
                            withdrawable_micro_usd,
                            GREATEST(
                                0::BIGINT,
                                $10::BIGINT - (
                                    balance_micro_usd - withdrawable_micro_usd
                                )
                            ) AS reserved_withdrawable
                        FROM public.balances
                        WHERE account_id = $8
                          AND balance_micro_usd >= $10
                          AND withdrawable_micro_usd >= 0
                          AND withdrawable_micro_usd <= balance_micro_usd
                        FOR UPDATE
                    ),
                    job_insert AS (
                        INSERT INTO rust_coord.inference_jobs (
                            job_id,
                            request_id,
                            reservation_id,
                            reserve_operation_key,
                            account_id,
                            api_key_id,
                            owner_epoch,
                            version,
                            state,
                            reserved_total_micro_usd,
                            reserved_withdrawable_micro_usd,
                            reservation_pre_debited
                        )
                        SELECT
                            $3,
                            $4,
                            $5,
                            $6,
                            account.account_id,
                            $9,
                            $2,
                            1,
                            'reserved',
                            $10,
                            account.reserved_withdrawable,
                            TRUE
                        FROM authority
                        CROSS JOIN account
                        ON CONFLICT DO NOTHING
                        RETURNING
                            job_id,
                            version,
                            state,
                            reserved_total_micro_usd,
                            reserved_withdrawable_micro_usd
                    ),
                    operation_insert AS (
                        INSERT INTO rust_coord.financial_operations (
                            operation_id,
                            operation_key,
                            operation_digest,
                            kind,
                            status,
                            job_id,
                            account_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd,
                            result,
                            owner_epoch,
                            version,
                            completed_at
                        )
                        SELECT
                            $7,
                            $6,
                            $11,
                            'reserve',
                            'applied',
                            job_insert.job_id,
                            $8,
                            job_insert.reserved_total_micro_usd,
                            job_insert.reserved_withdrawable_micro_usd,
                            jsonb_build_object(
                                'job_id', job_insert.job_id,
                                'version', job_insert.version,
                                'state', job_insert.state,
                                'total', job_insert.reserved_total_micro_usd,
                                'withdrawable',
                                    job_insert.reserved_withdrawable_micro_usd
                            ),
                            $2,
                            2,
                            NOW()
                        FROM job_insert
                        RETURNING
                            operation_id,
                            job_id,
                            amount_total_micro_usd,
                            amount_withdrawable_micro_usd
                    ),
                    balance_update AS (
                        UPDATE public.balances AS balances
                        SET
                            balance_micro_usd =
                                balances.balance_micro_usd
                                - operation_insert.amount_total_micro_usd,
                            withdrawable_micro_usd =
                                balances.withdrawable_micro_usd
                                - operation_insert.amount_withdrawable_micro_usd,
                            updated_at = NOW()
                        FROM operation_insert
                        WHERE balances.account_id = $8
                        RETURNING balances.balance_micro_usd
                    ),
                    ledger_insert AS (
                        INSERT INTO public.ledger_entries (
                            account_id,
                            entry_type,
                            amount_micro_usd,
                            balance_after,
                            reference
                        )
                        SELECT
                            $8,
                            'charge',
                            -operation_insert.amount_total_micro_usd,
                            balance_update.balance_micro_usd,
                            'rust-reserve:' || $6
                        FROM operation_insert
                        CROSS JOIN balance_update
                        RETURNING id
                    )
                    SELECT
                        job_insert.job_id,
                        job_insert.version,
                        job_insert.state,
                        job_insert.reserved_total_micro_usd,
                        job_insert.reserved_withdrawable_micro_usd
                    FROM job_insert
                    CROSS JOIN operation_insert
                    CROSS JOIN ledger_insert
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.job_id.as_uuid(),
                    request.request_id,
                    request.reservation_id.as_uuid(),
                    request.operation.key.as_str(),
                    request.operation.id.as_uuid(),
                    request.account_id.as_str(),
                    request.api_key_id.as_ref(),
                    request.amount.as_i64(),
                    request.operation.digest.as_bytes().as_slice(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await
    }

    async fn resolve_reserve(
        &self,
        authority: &Authority,
        request: &ReserveRequest,
        ambiguous: bool,
    ) -> Result<ReservationResult, LedgerError> {
        if let Some(operation) = self.db.operation(authority, &request.operation.key).await? {
            return reservation_from_operation(operation, request);
        }
        if ambiguous {
            return Err(LedgerError::CommitOutcomeUnknown(
                request.operation.key.clone(),
            ));
        }
        let diagnostic = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    ReserveDiagnostic,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        EXISTS (
                            SELECT 1
                            FROM public.balances
                            WHERE account_id = $3
                              AND balance_micro_usd >= $4
                              AND withdrawable_micro_usd >= 0
                              AND withdrawable_micro_usd <= balance_micro_usd
                        ) AS funded,
                        EXISTS (
                            SELECT 1
                            FROM rust_coord.inference_jobs
                            WHERE job_id = $5
                               OR request_id = $6
                               OR reservation_id = $7
                               OR reserve_operation_key = $8
                        ) AS job_conflict
                    WHERE EXISTS (SELECT 1 FROM authority)
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    request.account_id.as_str(),
                    request.amount.as_i64(),
                    request.job_id.as_uuid(),
                    request.request_id,
                    request.reservation_id.as_uuid(),
                    request.operation.key.as_str(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match diagnostic {
            Some(row) if !row.funded => Err(LedgerError::InsufficientBalance),
            Some(row) if row.job_conflict => Err(LedgerError::OperationConflict),
            Some(_) => Err(LedgerError::OperationConflict),
            None => Err(LedgerError::OwnershipLost),
        }
    }

    async fn resolve_reserve_conflict(
        &self,
        authority: &Authority,
        request: &ReserveRequest,
    ) -> Result<ReservationResult, LedgerError> {
        let Some(operation) = self.db.operation(authority, &request.operation.key).await? else {
            return Err(LedgerError::OperationConflict);
        };
        reservation_from_operation(operation, request)
    }
}

#[derive(Debug, FromRow)]
struct ReservationRow {
    job_id: uuid::Uuid,
    version: i64,
    state: String,
    reserved_total_micro_usd: i64,
    reserved_withdrawable_micro_usd: i64,
}

#[derive(Debug, FromRow)]
struct ReserveDiagnostic {
    funded: bool,
    job_conflict: bool,
}

fn reservation_from_row(
    row: ReservationRow,
    disposition: MutationDisposition,
) -> Result<ReservationResult, LedgerError> {
    Ok(ReservationResult {
        disposition,
        job_id: JobId::new(row.job_id)
            .map_err(|_| LedgerError::CorruptData("stored job id is nil"))?,
        version: Version::from_database(row.version)?,
        total: LedgerAmount::from_i64(row.reserved_total_micro_usd)
            .map_err(LedgerError::Invalid)?,
        withdrawable: LedgerAmount::from_i64(row.reserved_withdrawable_micro_usd)
            .map_err(LedgerError::Invalid)?,
        state: JobState::from_database(&row.state)?,
    })
}

fn reservation_from_operation(
    operation: OperationRecord,
    request: &ReserveRequest,
) -> Result<ReservationResult, LedgerError> {
    if operation.operation_key != request.operation.key.as_str()
        || operation.digest()? != request.operation.digest
        || operation.kind != "reserve"
        || operation.status != "applied"
        || operation.job_id != Some(request.job_id.as_uuid())
        || operation.account_id != request.account_id.as_str()
        || operation.amount_total_micro_usd != request.amount.as_i64()
    {
        return Err(LedgerError::OperationConflict);
    }
    let result = &operation.result;
    let row = ReservationRow {
        job_id: json_uuid(result, "job_id")?,
        version: json_i64(result, "version")?,
        state: json_string(result, "state")?.to_owned(),
        reserved_total_micro_usd: json_i64(result, "total")?,
        reserved_withdrawable_micro_usd: json_i64(result, "withdrawable")?,
    };
    let reservation = reservation_from_row(row, MutationDisposition::Replayed)?;
    if reservation.total != request.amount
        || operation.amount_withdrawable_micro_usd != reservation.withdrawable.as_i64()
        || operation.version <= 0
    {
        return Err(LedgerError::OperationConflict);
    }
    Ok(reservation)
}

pub(crate) fn json_i64(value: &Value, field: &'static str) -> Result<i64, LedgerError> {
    value
        .get(field)
        .and_then(Value::as_i64)
        .ok_or(LedgerError::CorruptData(field))
}

pub(crate) fn json_string<'a>(
    value: &'a Value,
    field: &'static str,
) -> Result<&'a str, LedgerError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .ok_or(LedgerError::CorruptData(field))
}

pub(crate) fn json_uuid(value: &Value, field: &'static str) -> Result<uuid::Uuid, LedgerError> {
    json_string(value, field)?
        .parse()
        .map_err(|_| LedgerError::CorruptData(field))
}

#[allow(dead_code)]
fn _digest_type_pin(_: Digest) {}
