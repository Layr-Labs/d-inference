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

const MAX_EXECUTION_LEASE_MILLIS: u64 = 300_000;

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
        if request.consumer_key_hash.is_empty() {
            return Err(crate::ledger::types::InputError::Empty("consumer key hash").into());
        }
        if request.request_deadline_epoch_millis == 0
            || request.request_deadline_epoch_millis > i64::MAX as u64
        {
            return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
        }
        match (request.execution_worker_id, request.execution_lease_millis) {
            (None, None) => {}
            (Some(worker_id), Some(lease_millis))
                if !worker_id.is_nil()
                    && lease_millis > 0
                    && lease_millis <= MAX_EXECUTION_LEASE_MILLIS => {}
            (Some(worker_id), _) if worker_id.is_nil() => {
                return Err(crate::ledger::types::InputError::NilId("execution worker").into());
            }
            _ => {
                return Err(crate::ledger::types::InputError::ArithmeticOverflow.into());
            }
        }
        match (
            request.provisional_provider_id,
            request.provisional_session_epoch,
        ) {
            (None, None) => {}
            (Some(provider_id), Some(_)) if !provider_id.is_nil() => {}
            (Some(provider_id), _) if provider_id.is_nil() => {
                return Err(crate::ledger::types::InputError::NilId("provider id").into());
            }
            _ => {
                return Err(crate::ledger::types::InputError::Empty("provider trust fence").into());
            }
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
                          AND TIMESTAMPTZ 'epoch'
                              + ($17::BIGINT * INTERVAL '1 millisecond')
                              > NOW()
                          AND (
                              $15::UUID IS NULL
                              OR NOT EXISTS (
                                  SELECT 1
                                  FROM rust_coord.provider_hard_untrust_epochs
                                      AS untrusted
                                  WHERE untrusted.provider_id = $15
                                    AND untrusted.hard_untrust_epoch >= $16
                              )
                          )
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
                            consumer_key_hash,
                            owner_epoch,
                            version,
                            state,
                            reserved_total_micro_usd,
                            reserved_withdrawable_micro_usd,
                            reservation_pre_debited,
                            request_deadline,
                            worker_owner,
                            lease_until
                        )
                        SELECT
                            $3,
                            $4,
                            $5,
                            $6,
                            account.account_id,
                            $9,
                            $12,
                            $2,
                            1,
                            'reserved',
                            $10,
                            account.reserved_withdrawable,
                            TRUE,
                            TIMESTAMPTZ 'epoch'
                                + ($17::BIGINT * INTERVAL '1 millisecond'),
                            $13,
                            CASE
                                WHEN $13::UUID IS NULL THEN NULL
                                ELSE NOW()
                                    + ($14::BIGINT * INTERVAL '1 millisecond')
                            END
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
                    request.consumer_key_hash.as_ref(),
                    request.execution_worker_id,
                    request.execution_lease_millis.map(|millis| {
                        i64::try_from(millis).expect("bounded execution lease fits i64")
                    }),
                    request.provisional_provider_id,
                    request.provisional_session_epoch.map(Version::as_i64),
                    i64::try_from(request.request_deadline_epoch_millis)
                        .expect("validated request deadline fits i64"),
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
            return Err(LedgerError::CommitOutcomeUnknown {
                operation: request.operation.key.clone(),
                diagnostic: "ambiguous reserve commit was not found during reconciliation".into(),
            });
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
                        ) AS job_conflict,
                        (
                            $9::UUID IS NULL
                            OR NOT EXISTS (
                                SELECT 1
                                FROM rust_coord.provider_hard_untrust_epochs
                                    AS untrusted
                                WHERE untrusted.provider_id = $9
                                  AND untrusted.hard_untrust_epoch >= $10
                            )
                        ) AS provider_trusted
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
                    request.provisional_provider_id,
                    request.provisional_session_epoch.map(Version::as_i64),
                )
                .fetch_optional(self.db.pool()),
            )
            .await?;
        match diagnostic {
            Some(row) if !row.provider_trusted => Err(LedgerError::ProviderHardUntrusted),
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
    provider_trusted: bool,
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
