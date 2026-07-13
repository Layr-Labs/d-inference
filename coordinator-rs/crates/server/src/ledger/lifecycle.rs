use std::time::Duration;

use darkbloom_coordinator_core::ids::Digest;
use sqlx::{FromRow, types::Json};
use uuid::Uuid;

use super::{
    LedgerService,
    types::{
        AttemptState, AuthorizedTerminalTimeoutRequest, DurableAttemptIdentity,
        DurableTerminalDisposition, LedgerError, RecoveryTerminalRecordResult, ReviewRequest,
        StartDispatchDisposition, StartDispatchRequest, StartDispatchResult, TerminalFacts,
        TerminalLookup, Version,
    },
};

impl LedgerService {
    /// Renews the process-local execution claim without changing lifecycle
    /// versions. An expired or recovered claim cannot be resurrected.
    pub async fn renew_execution_lease(
        &self,
        job_id: super::types::JobId,
        worker_id: Uuid,
        lease_for: Duration,
    ) -> Result<(), LedgerError> {
        if worker_id.is_nil() {
            return Err(crate::ledger::InputError::NilId("execution worker").into());
        }
        let lease_millis = u64::try_from(lease_for.as_millis())
            .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?;
        if lease_millis == 0 || lease_millis > 300_000 {
            return Err(crate::ledger::InputError::ArithmeticOverflow.into());
        }
        let authority = self.db.authority()?;
        let renewed = self
            .db
            .bounded(
                sqlx::query_scalar::<_, Uuid>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    job_renewal AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            lease_until =
                                NOW() + ($5::BIGINT * INTERVAL '1 millisecond'),
                            updated_at = NOW()
                        FROM authority
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.worker_owner = $4
                          AND jobs.lease_until > NOW()
                          AND jobs.state IN (
                              'reserved',
                              'preparing',
                              'prepared',
                              'start_authorized',
                              'running'
                          )
                        RETURNING jobs.job_id, jobs.lease_until
                    ),
                    attempt_renewal AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            lease_until = job_renewal.lease_until,
                            updated_at = NOW()
                        FROM job_renewal
                        WHERE attempts.job_id = job_renewal.job_id
                          AND attempts.owner_epoch = $2
                          AND attempts.worker_owner = $4
                          AND attempts.state IN (
                              'not_sent',
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                        RETURNING attempts.attempt_id
                    )
                    SELECT job_renewal.job_id
                    FROM job_renewal
                    LEFT JOIN (
                        SELECT COUNT(*) AS renewed_attempts
                        FROM attempt_renewal
                    ) AS attempts ON TRUE
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(job_id.as_uuid())
                .bind(worker_id)
                .bind(i64::try_from(lease_millis).expect("bounded execution lease fits i64"))
                .fetch_optional(self.db.pool()),
            )
            .await?;
        if renewed.is_some() {
            return Ok(());
        }
        self.db.verify_authority(&authority).await?;
        Err(LedgerError::StaleVersion)
    }

    /// Quarantines both the durable job and the exact provider epoch while
    /// retaining the reservation for explicit review disposition.
    pub async fn move_to_review(&self, request: &ReviewRequest) -> Result<Version, LedgerError> {
        if request.reason.is_empty() {
            return Err(crate::ledger::InputError::Empty("review reason").into());
        }
        let accepted_cumulative_tokens = i64::try_from(request.accepted_cumulative_tokens)
            .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?;
        let authority = self.db.authority()?;
        let version = self
            .db
            .bounded(
                sqlx::query_scalar::<_, i64>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    untrust AS (
                        INSERT INTO rust_coord.provider_hard_untrust_epochs (
                            provider_id,
                            hard_untrust_epoch,
                            reason,
                            evidence_digest,
                            owner_epoch
                        )
                        SELECT $6, $7, $8, $9, $2
                        FROM authority
                        ON CONFLICT (provider_id) DO UPDATE SET
                            hard_untrust_epoch = GREATEST(
                                provider_hard_untrust_epochs.hard_untrust_epoch,
                                EXCLUDED.hard_untrust_epoch
                            ),
                            reason = EXCLUDED.reason,
                            evidence_digest = EXCLUDED.evidence_digest,
                            owner_epoch = EXCLUDED.owner_epoch,
                            version = provider_hard_untrust_epochs.version + 1,
                            updated_at = NOW()
                        RETURNING provider_id
                    )
                    UPDATE rust_coord.inference_jobs AS jobs
                    SET
                        state = 'review_pending',
                        error_class = $8,
                        accepted_cumulative_tokens = GREATEST(
                            jobs.accepted_cumulative_tokens,
                            $10
                        ),
                        worker_owner = NULL,
                        lease_until = NULL,
                        version = jobs.version + 1,
                        updated_at = NOW()
                    FROM untrust
                    WHERE jobs.job_id = $3
                      AND jobs.owner_epoch = $2
                      AND jobs.version = $4
                      AND jobs.state = $5
                      AND (
                          $10 = 0
                          OR (
                              jobs.bounded_output_tokens IS NOT NULL
                              AND $10 <= jobs.bounded_output_tokens
                          )
                      )
                    RETURNING jobs.version
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(request.job_id.as_uuid())
                .bind(request.expected_version.as_i64())
                .bind(request.expected_state.as_str())
                .bind(request.provider_id)
                .bind(request.hard_untrust_epoch.as_i64())
                .bind(request.reason.as_ref())
                .bind(request.evidence_digest.as_bytes().as_slice())
                .bind(accepted_cumulative_tokens)
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(version) = version else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::StaleVersion);
        };
        Version::from_database(version)
    }

    /// Quarantines a durably started request only after its persisted absolute
    /// terminal deadline. The reservation, attempt binding, pricing, and usage
    /// facts are left intact for an explicit operator disposition.
    pub async fn expire_authorized_terminal(
        &self,
        request: &AuthorizedTerminalTimeoutRequest,
    ) -> Result<Version, LedgerError> {
        if !matches!(
            request.expected_job_state,
            super::types::JobState::StartAuthorized | super::types::JobState::Running
        ) {
            return Err(LedgerError::StaleVersion);
        }
        let authority = self.db.authority()?;
        let version = self
            .db
            .bounded(
                sqlx::query_scalar::<_, i64>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    locked AS MATERIALIZED (
                        SELECT jobs.job_id, attempts.attempt_id
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN rust_coord.inference_attempts AS attempts
                          ON attempts.job_id = jobs.job_id
                        CROSS JOIN authority
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.version = $4
                          AND jobs.state = $5
                          AND jobs.request_deadline <= NOW()
                          AND attempts.attempt_id = $6
                          AND attempts.owner_epoch = $2
                          AND attempts.version = $7
                          AND attempts.state = 'started'
                        FOR UPDATE OF jobs, attempts
                    ),
                    attempt_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            worker_owner = NULL,
                            lease_until = NULL,
                            owner_epoch = $2,
                            version = attempts.version + 1,
                            updated_at = NOW()
                        FROM locked
                        WHERE attempts.attempt_id = locked.attempt_id
                        RETURNING attempts.attempt_id
                    )
                    UPDATE rust_coord.inference_jobs AS jobs
                    SET
                        state = 'review_pending',
                        error_class = 'authorized_terminal_timeout',
                        worker_owner = NULL,
                        lease_until = NULL,
                        owner_epoch = $2,
                        version = jobs.version + 1,
                        updated_at = NOW()
                    FROM locked, attempt_update
                    WHERE jobs.job_id = locked.job_id
                    RETURNING jobs.version
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(request.job_id.as_uuid())
                .bind(request.expected_job_version.as_i64())
                .bind(request.expected_job_state.as_str())
                .bind(request.attempt_id.as_uuid())
                .bind(request.expected_attempt_version.as_i64())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(version) = version else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::StaleVersion);
        };
        Version::from_database(version)
    }

    /// Rejects a provider process/session covered by a durable hard-untrust
    /// epoch. The check is ownership fenced and is repeated at each financial
    /// boundary by the pilot.
    pub async fn ensure_provider_trusted(
        &self,
        provider_id: Uuid,
        session_epoch: Version,
    ) -> Result<(), LedgerError> {
        if provider_id.is_nil() {
            return Err(crate::ledger::InputError::NilId("provider id").into());
        }
        let authority = self.db.authority()?;
        let hard_epoch = self
            .db
            .bounded(
                sqlx::query_scalar::<_, i64>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT epochs.hard_untrust_epoch
                    FROM rust_coord.provider_hard_untrust_epochs AS epochs
                    WHERE epochs.provider_id = $3
                      AND EXISTS (SELECT 1 FROM authority)
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(provider_id)
                .fetch_optional(self.db.pool()),
            )
            .await?;
        if hard_epoch.is_none() {
            self.db.verify_authority(&authority).await?;
        }
        if hard_epoch.is_some_and(|epoch| epoch >= session_epoch.as_i64()) {
            Err(LedgerError::ProviderHardUntrusted)
        } else {
            Ok(())
        }
    }

    /// Persists each post-authorization dispatch observation. A sent-unknown
    /// attempt remains bound to its exact provider lease; running records the
    /// provider's durable StartAck.
    pub async fn record_start_dispatch(
        &self,
        request: &StartDispatchRequest,
    ) -> Result<StartDispatchResult, LedgerError> {
        let transition_allowed = match request.disposition {
            StartDispatchDisposition::Queued => matches!(
                request.expected_attempt_state,
                AttemptState::NotSent
                    | AttemptState::Queued
                    | AttemptState::OnWire
                    | AttemptState::SentUnknown
            ),
            StartDispatchDisposition::OnWire | StartDispatchDisposition::SentUnknown => {
                request.expected_attempt_state == AttemptState::Queued
            }
            StartDispatchDisposition::Running => matches!(
                request.expected_attempt_state,
                AttemptState::Queued | AttemptState::OnWire | AttemptState::SentUnknown
            ),
        };
        if !transition_allowed {
            return Err(LedgerError::StaleVersion);
        }
        let authority = self.db.authority()?;
        let (job_state, attempt_state) = match request.disposition {
            StartDispatchDisposition::Queued => (request.expected_job_state, AttemptState::Queued),
            StartDispatchDisposition::OnWire => (request.expected_job_state, AttemptState::OnWire),
            StartDispatchDisposition::SentUnknown => {
                (request.expected_job_state, AttemptState::SentUnknown)
            }
            StartDispatchDisposition::Running => {
                (super::types::JobState::Running, AttemptState::Started)
            }
        };
        let row = self
            .db
            .bounded(
                sqlx::query_as::<_, StartDispatchRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    locked AS MATERIALIZED (
                        SELECT jobs.job_id, attempts.attempt_id
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN rust_coord.inference_attempts AS attempts
                          ON attempts.job_id = jobs.job_id
                        CROSS JOIN authority
                        WHERE jobs.job_id = $3
                          AND jobs.owner_epoch = $2
                          AND jobs.version = $4
                          AND jobs.state = $5
                          AND attempts.attempt_id = $6
                          AND attempts.owner_epoch = $2
                          AND attempts.version = $7
                          AND attempts.state = $8
                        FOR UPDATE OF jobs, attempts
                    ),
                    attempt_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            state = $10,
                            owner_epoch = $2,
                            version = attempts.version + 1,
                            updated_at = NOW()
                        FROM locked
                        WHERE attempts.attempt_id = locked.attempt_id
                        RETURNING attempts.version, attempts.state
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = $9,
                            version = jobs.version + 1,
                            updated_at = NOW()
                        FROM locked
                        WHERE jobs.job_id = locked.job_id
                        RETURNING jobs.version, jobs.state
                    )
                    SELECT
                        job_update.version AS job_version,
                        job_update.state AS job_state,
                        attempt_update.version AS attempt_version,
                        attempt_update.state AS attempt_state
                    FROM job_update
                    CROSS JOIN attempt_update
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(request.job_id.as_uuid())
                .bind(request.expected_job_version.as_i64())
                .bind(request.expected_job_state.as_str())
                .bind(request.attempt_id.as_uuid())
                .bind(request.expected_attempt_version.as_i64())
                .bind(request.expected_attempt_state.as_str())
                .bind(job_state.as_str())
                .bind(attempt_state.as_str())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(row) = row else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::StaleVersion);
        };
        Ok(StartDispatchResult {
            job_version: Version::from_database(row.job_version)?,
            job_state: super::types::JobState::from_database(&row.job_state)?,
            attempt_version: Version::from_database(row.attempt_version)?,
            attempt_state: AttemptState::from_database(&row.attempt_state)?,
        })
    }

    /// Reconciles a StartAck received after the process-local request route was
    /// lost. The exact durable attempt identity is the only lookup key.
    pub async fn record_recovered_start_ack(
        &self,
        attempt_id: super::types::AttemptId,
        provider_id: Uuid,
        provider_process_generation_id: Uuid,
        session_epoch: Version,
    ) -> Result<(), LedgerError> {
        self.ensure_provider_trusted(provider_id, session_epoch)
            .await?;
        let authority = self.db.authority()?;
        let updated = self
            .db
            .bounded(
                sqlx::query_scalar::<_, Uuid>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    attempt_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            state = 'started',
                            owner_epoch = $2,
                            version = attempts.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW()
                        FROM authority
                        WHERE attempts.attempt_id = $3
                          AND attempts.provider_id = $4
                          AND attempts.provider_process_generation_id = $5
                          AND attempts.session_epoch = $6
                          AND attempts.owner_epoch = $2
                          AND attempts.state IN (
                              'queued',
                              'on_wire',
                              'sent_unknown'
                          )
                        RETURNING attempts.job_id
                    )
                    UPDATE rust_coord.inference_jobs AS jobs
                    SET
                        state = 'running',
                        owner_epoch = $2,
                        version = jobs.version + 1,
                        worker_owner = NULL,
                        lease_until = NULL,
                        updated_at = NOW()
                    FROM attempt_update
                    WHERE jobs.job_id = attempt_update.job_id
                      AND jobs.owner_epoch = $2
                      AND jobs.state = 'start_authorized'
                    RETURNING jobs.job_id
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(attempt_id.as_uuid())
                .bind(provider_id)
                .bind(provider_process_generation_id)
                .bind(session_epoch.as_i64())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        if updated.is_some() {
            return Ok(());
        }
        self.db.verify_authority(&authority).await?;
        let known = self
            .db
            .bounded(
                sqlx::query_scalar::<_, bool>(
                    r#"
                    SELECT EXISTS (
                        SELECT 1
                        FROM rust_coord.inference_attempts AS attempts
                        JOIN rust_coord.inference_jobs AS jobs
                          ON jobs.job_id = attempts.job_id
                        WHERE attempts.attempt_id = $1
                          AND attempts.provider_id = $2
                          AND attempts.provider_process_generation_id = $3
                          AND attempts.session_epoch = $4
                          AND attempts.state IN (
                              'started',
                              'terminal_recorded',
                              'acknowledged'
                          )
                          AND jobs.state IN (
                              'running',
                              'settled',
                              'released',
                              'review_pending',
                              'settled_reviewed',
                              'released_reviewed'
                          )
                    )
                    "#,
                )
                .bind(attempt_id.as_uuid())
                .bind(provider_id)
                .bind(provider_process_generation_id)
                .bind(session_epoch.as_i64())
                .fetch_one(self.db.pool()),
            )
            .await?;
        if known {
            Ok(())
        } else {
            Err(LedgerError::NotFound)
        }
    }

    /// Database-authoritative historical terminal lookup. Any second digest
    /// for one attempt is a conflict even when one digest was already settled.
    pub async fn lookup_terminal(
        &self,
        identity: DurableAttemptIdentity,
        terminal_digest: Digest,
    ) -> Result<TerminalLookup, LedgerError> {
        identity.validate()?;
        let authority = self.db.authority()?;
        let rows = self
            .db
            .bounded(
                sqlx::query_as::<_, TerminalDispositionRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    )
                    SELECT
                        terminals.job_id,
                        jobs.request_id,
                        jobs.reservation_id,
                        attempts.lease_id,
                        terminals.provider_id,
                        terminals.provider_process_generation_id,
                        terminals.origin_session_epoch,
                        terminals.terminal_digest,
                        terminals.status,
                        terminals.conflict
                    FROM rust_coord.provider_terminals AS terminals
                    JOIN rust_coord.inference_attempts AS attempts
                      ON attempts.attempt_id = terminals.attempt_id
                     AND attempts.job_id = terminals.job_id
                    JOIN rust_coord.inference_jobs AS jobs
                      ON jobs.job_id = terminals.job_id
                    WHERE terminals.attempt_id = $3
                      AND EXISTS (SELECT 1 FROM authority)
                    ORDER BY terminals.received_at, terminals.terminal_id
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(identity.attempt_id.as_uuid())
                .fetch_all(self.db.pool()),
            )
            .await?;
        if rows.is_empty() {
            self.db.verify_authority(&authority).await?;
            return Ok(TerminalLookup::Absent);
        }
        let matching = rows.iter().find(|row| {
            row.request_id == identity.request_id
                && row.reservation_id == identity.reservation_id.as_uuid()
                && row.lease_id == Some(identity.lease_id)
                && row.provider_id == identity.provider_id
                && row.provider_process_generation_id == identity.provider_process_generation_id
                && row.origin_session_epoch == identity.session_epoch.as_i64()
                && row.terminal_digest.as_slice() == terminal_digest.as_bytes().as_slice()
        });
        let Some(matching) = matching else {
            return Ok(TerminalLookup::Conflict {
                job_id: super::types::JobId::new(rows[0].job_id).map_err(LedgerError::Invalid)?,
            });
        };
        let reviewed = terminal_disposition(&matching.status)?;
        if matches!(
            reviewed,
            DurableTerminalDisposition::SettledReviewed
                | DurableTerminalDisposition::ReleasedReviewed
        ) && rows.iter().all(|row| row.status == matching.status)
        {
            return Ok(TerminalLookup::Known(reviewed));
        }
        if rows.iter().any(|row| row.conflict) {
            return Ok(TerminalLookup::Conflict {
                job_id: super::types::JobId::new(rows[0].job_id).map_err(LedgerError::Invalid)?,
            });
        }
        Ok(TerminalLookup::Known(reviewed))
    }

    /// Persists a signed terminal that arrived after the process-local request
    /// route was lost. Output usage is supplied by the caller and must be the
    /// last coordinator-accepted checkpoint; callers without one use zero.
    pub async fn record_terminal_for_recovery(
        &self,
        terminal: &TerminalFacts,
    ) -> Result<RecoveryTerminalRecordResult, LedgerError> {
        terminal.validate()?;
        let authority = self.db.authority()?;
        let row = self
            .db
            .bounded(
                sqlx::query_as::<_, RecoveryTerminalRecordRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    locked AS MATERIALIZED (
                        SELECT
                            jobs.job_id,
                            jobs.version AS job_version,
                            jobs.state AS job_state,
                            attempts.attempt_id
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN rust_coord.inference_attempts AS attempts
                          ON attempts.job_id = jobs.job_id
                        CROSS JOIN authority
                        WHERE attempts.attempt_id = $3
                          AND attempts.provider_id = $4
                          AND attempts.provider_process_generation_id = $5
                          AND attempts.session_epoch = $6
                          AND attempts.owner_epoch = $2
                          AND attempts.state IN (
                              'queued',
                              'on_wire',
                              'sent_unknown',
                              'started'
                          )
                          AND jobs.owner_epoch = $2
                          AND jobs.state IN (
                              'start_authorized',
                              'running',
                              'review_pending'
                          )
                        FOR UPDATE OF jobs, attempts
                    ),
                    existing AS MATERIALIZED (
                        SELECT terminals.*
                        FROM rust_coord.provider_terminals AS terminals
                        JOIN locked USING (attempt_id)
                        WHERE terminals.provider_id = $4
                          AND terminals.provider_process_generation_id = $5
                          AND terminals.origin_session_epoch = $6
                        FOR UPDATE OF terminals
                    ),
                    conflict_existing AS (
                        UPDATE rust_coord.provider_terminals AS terminals
                        SET
                            status = CASE
                                WHEN terminals.status IN (
                                    'settled',
                                    'released',
                                    'settled_reviewed',
                                    'released_reviewed'
                                ) THEN terminals.status
                                ELSE 'conflict'
                            END,
                            conflict = TRUE,
                            owner_epoch = $2,
                            version = terminals.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            disposition_at =
                                COALESCE(terminals.disposition_at, NOW()),
                            updated_at = NOW()
                        FROM existing
                        WHERE terminals.terminal_id = existing.terminal_id
                          AND existing.terminal_digest <> $8
                        RETURNING terminals.job_id
                    ),
                    terminal_insert AS (
                        INSERT INTO rust_coord.provider_terminals AS terminals (
                            terminal_id,
                            job_id,
                            attempt_id,
                            provider_id,
                            provider_process_generation_id,
                            origin_session_epoch,
                            terminal_digest,
                            raw_terminal,
                            outcome,
                            error_class,
                            prompt_tokens,
                            completion_tokens,
                            reasoning_tokens,
                            response_digest,
                            rolling_digest,
                            final_generated_tokens,
                            provider_signature,
                            status,
                            conflict,
                            owner_epoch,
                            disposition_at
                        )
                        SELECT
                            $7,
                            locked.job_id,
                            locked.attempt_id,
                            $4,
                            $5,
                            $6,
                            $8,
                            $9,
                            $10,
                            $11,
                            $12,
                            $13,
                            $14,
                            $15,
                            $16,
                            $17,
                            $18,
                            CASE
                                WHEN EXISTS (
                                    SELECT 1 FROM conflict_existing
                                ) THEN 'conflict'
                                ELSE 'pending'
                            END,
                            EXISTS (SELECT 1 FROM conflict_existing),
                            $2,
                            CASE
                                WHEN EXISTS (
                                    SELECT 1 FROM conflict_existing
                                ) THEN NOW()
                                ELSE NULL
                            END
                        FROM locked
                        ON CONFLICT (terminal_digest) DO UPDATE SET
                            received_count = terminals.received_count + 1,
                            updated_at = NOW()
                        WHERE terminals.job_id = EXCLUDED.job_id
                          AND terminals.attempt_id = EXCLUDED.attempt_id
                          AND terminals.provider_id = EXCLUDED.provider_id
                          AND terminals.provider_process_generation_id
                              = EXCLUDED.provider_process_generation_id
                          AND terminals.origin_session_epoch
                              = EXCLUDED.origin_session_epoch
                        RETURNING
                            terminals.job_id,
                            terminals.status,
                            terminals.conflict
                    ),
                    untrust AS (
                        INSERT INTO rust_coord.provider_hard_untrust_epochs (
                            provider_id,
                            hard_untrust_epoch,
                            reason,
                            evidence_digest,
                            owner_epoch
                        )
                        SELECT
                            $4,
                            $6,
                            'terminal_digest_conflict',
                            $8,
                            $2
                        FROM terminal_insert
                        WHERE terminal_insert.conflict
                        ON CONFLICT (provider_id) DO UPDATE SET
                            hard_untrust_epoch = GREATEST(
                                provider_hard_untrust_epochs.hard_untrust_epoch,
                                EXCLUDED.hard_untrust_epoch
                            ),
                            reason = EXCLUDED.reason,
                            evidence_digest = EXCLUDED.evidence_digest,
                            owner_epoch = EXCLUDED.owner_epoch,
                            version = provider_hard_untrust_epochs.version + 1,
                            updated_at = NOW()
                        RETURNING provider_id
                    ),
                    job_update AS (
                        UPDATE rust_coord.inference_jobs AS jobs
                        SET
                            state = CASE
                                WHEN terminal_insert.conflict
                                THEN 'review_pending'
                                WHEN locked.job_state <> 'review_pending'
                                     AND jobs.request_deadline <= NOW()
                                THEN 'review_pending'
                                ELSE jobs.state
                            END,
                            error_class = CASE
                                WHEN terminal_insert.conflict
                                THEN 'terminal_digest_conflict'
                                WHEN locked.job_state <> 'review_pending'
                                     AND jobs.request_deadline <= NOW()
                                THEN 'authorized_terminal_timeout'
                                ELSE jobs.error_class
                            END,
                            version = jobs.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW()
                        FROM locked, terminal_insert
                        LEFT JOIN untrust ON TRUE
                        WHERE jobs.job_id = locked.job_id
                          AND jobs.version = locked.job_version
                          AND jobs.state = locked.job_state
                        RETURNING jobs.job_id
                    ),
                    attempt_update AS (
                        UPDATE rust_coord.inference_attempts AS attempts
                        SET
                            version = attempts.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            updated_at = NOW()
                        FROM locked, terminal_insert
                        WHERE attempts.attempt_id = locked.attempt_id
                        RETURNING attempts.attempt_id
                    )
                    SELECT
                        terminal_insert.job_id,
                        terminal_insert.status,
                        terminal_insert.conflict
                    FROM terminal_insert
                    JOIN job_update USING (job_id)
                    CROSS JOIN attempt_update
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(terminal.attempt_id.as_uuid())
                .bind(terminal.provider_id)
                .bind(terminal.provider_process_generation_id)
                .bind(terminal.origin_session_epoch.as_i64())
                .bind(terminal.terminal_id.as_uuid())
                .bind(terminal.terminal_digest.as_bytes().as_slice())
                .bind(Json(&terminal.raw_terminal))
                .bind(terminal.outcome.as_str())
                .bind(terminal.error_class.as_deref())
                .bind(terminal.prompt_tokens as i64)
                .bind(terminal.completion_tokens as i64)
                .bind(terminal.reasoning_tokens as i64)
                .bind(terminal.response_digest.as_bytes().as_slice())
                .bind(terminal.rolling_digest.as_bytes().as_slice())
                .bind(terminal.final_generated_tokens as i64)
                .bind(terminal.provider_signature.as_slice())
                .fetch_optional(self.db.pool()),
            )
            .await?;
        let Some(row) = row else {
            self.db.verify_authority(&authority).await?;
            return Err(LedgerError::NotFound);
        };
        let job_id = super::types::JobId::new(row.job_id).map_err(LedgerError::Invalid)?;
        if row.conflict || row.status == "conflict" {
            return Ok(RecoveryTerminalRecordResult::Conflict { job_id });
        }
        if row.status == "pending" {
            return Ok(RecoveryTerminalRecordResult::Pending { job_id });
        }
        Ok(RecoveryTerminalRecordResult::Known(terminal_disposition(
            &row.status,
        )?))
    }

    /// Persists contradictory terminal evidence and hard-untrusts the exact
    /// provider epoch. Historical financial dispositions are never mutated;
    /// active jobs move to review and terminalized jobs retain their one money
    /// disposition while carrying durable conflict evidence.
    pub async fn record_terminal_conflict(
        &self,
        job_id: super::types::JobId,
        attempt_id: super::types::AttemptId,
        terminal: &TerminalFacts,
        reason: &str,
        accepted_cumulative_tokens: u64,
    ) -> Result<(), LedgerError> {
        terminal.validate()?;
        if reason.is_empty() {
            return Err(crate::ledger::InputError::Empty("terminal conflict reason").into());
        }
        let accepted_cumulative_tokens = i64::try_from(accepted_cumulative_tokens)
            .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?;
        let authority = self.db.authority()?;
        let recorded = self
            .db
            .bounded(
                sqlx::query_scalar::<_, Uuid>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    locked AS MATERIALIZED (
                        SELECT jobs.job_id, jobs.state, attempts.attempt_id
                        FROM rust_coord.inference_jobs AS jobs
                        JOIN rust_coord.inference_attempts AS attempts
                          ON attempts.job_id = jobs.job_id
                        CROSS JOIN authority
                        WHERE jobs.job_id = $3
                          AND attempts.attempt_id = $4
                          AND attempts.provider_id = $5
                          AND attempts.provider_process_generation_id = $6
                          AND attempts.session_epoch = $7
                        FOR UPDATE OF jobs, attempts
                    ),
                    existing_conflict AS (
                        UPDATE rust_coord.provider_terminals AS terminals
                        SET
                            status = CASE
                                WHEN terminals.status IN (
                                    'settled',
                                    'released',
                                    'settled_reviewed',
                                    'released_reviewed'
                                ) THEN terminals.status
                                ELSE 'conflict'
                            END,
                            conflict = TRUE,
                            owner_epoch = $2,
                            version = terminals.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            disposition_at = COALESCE(terminals.disposition_at, NOW()),
                            updated_at = NOW()
                        FROM locked
                        WHERE terminals.attempt_id = locked.attempt_id
                        RETURNING terminals.job_id
                    ),
                    terminal_insert AS (
                        INSERT INTO rust_coord.provider_terminals (
                            terminal_id,
                            job_id,
                            attempt_id,
                            provider_id,
                            provider_process_generation_id,
                            origin_session_epoch,
                            terminal_digest,
                            raw_terminal,
                            outcome,
                            error_class,
                            prompt_tokens,
                            completion_tokens,
                            reasoning_tokens,
                            response_digest,
                            rolling_digest,
                            final_generated_tokens,
                            provider_signature,
                            status,
                            conflict,
                            owner_epoch,
                            disposition_at
                        )
                        SELECT
                            $8,
                            locked.job_id,
                            locked.attempt_id,
                            $5,
                            $6,
                            $7,
                            $9,
                            $10,
                            $11,
                            $12,
                            $13,
                            $14,
                            $15,
                            $16,
                            $17,
                            $18,
                            $19,
                            'conflict',
                            TRUE,
                            $2,
                            NOW()
                        FROM locked
                        LEFT JOIN (
                            SELECT COUNT(*) AS existing_count
                            FROM existing_conflict
                        ) AS existing ON TRUE
                        WHERE NOT EXISTS (
                            SELECT 1
                            FROM rust_coord.provider_terminals AS same_digest
                            WHERE same_digest.terminal_digest = $9
                        )
                        ON CONFLICT (terminal_digest) DO UPDATE SET
                            status = 'conflict',
                            conflict = TRUE,
                            owner_epoch = $2,
                            version = provider_terminals.version + 1,
                            worker_owner = NULL,
                            lease_until = NULL,
                            disposition_at =
                                COALESCE(provider_terminals.disposition_at, NOW()),
                            received_count =
                                provider_terminals.received_count + 1,
                            updated_at = NOW()
                        WHERE provider_terminals.job_id = EXCLUDED.job_id
                          AND provider_terminals.attempt_id = EXCLUDED.attempt_id
                          AND provider_terminals.provider_id = EXCLUDED.provider_id
                          AND provider_terminals.provider_process_generation_id
                              = EXCLUDED.provider_process_generation_id
                          AND provider_terminals.origin_session_epoch
                              = EXCLUDED.origin_session_epoch
                        RETURNING job_id
                    ),
                    evidence AS MATERIALIZED (
                        SELECT job_id FROM terminal_insert
                        UNION
                        SELECT job_id FROM existing_conflict
                    ),
                    untrust AS (
                        INSERT INTO rust_coord.provider_hard_untrust_epochs (
                            provider_id,
                            hard_untrust_epoch,
                            reason,
                            evidence_digest,
                            owner_epoch
                        )
                        SELECT $5, $7, $20, $9, $2
                        FROM evidence
                        ON CONFLICT (provider_id) DO UPDATE SET
                            hard_untrust_epoch = GREATEST(
                                provider_hard_untrust_epochs.hard_untrust_epoch,
                                EXCLUDED.hard_untrust_epoch
                            ),
                            reason = EXCLUDED.reason,
                            evidence_digest = EXCLUDED.evidence_digest,
                            owner_epoch = EXCLUDED.owner_epoch,
                            version = provider_hard_untrust_epochs.version + 1,
                            updated_at = NOW()
                        RETURNING provider_id
                    )
                    UPDATE rust_coord.inference_jobs AS jobs
                    SET
                        state = CASE
                            WHEN jobs.state IN (
                                'reserved',
                                'preparing',
                                'prepared',
                                'start_authorized',
                                'running'
                            ) THEN 'review_pending'
                            ELSE jobs.state
                        END,
                        error_class = $20,
                        accepted_cumulative_tokens = GREATEST(
                            jobs.accepted_cumulative_tokens,
                            LEAST(
                                $21,
                                COALESCE(jobs.bounded_output_tokens, 0)
                            )
                        ),
                        owner_epoch = $2,
                        version = jobs.version + 1,
                        worker_owner = NULL,
                        lease_until = NULL,
                        updated_at = NOW()
                    FROM evidence, untrust
                    WHERE jobs.job_id = evidence.job_id
                    RETURNING jobs.job_id
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .bind(job_id.as_uuid())
                .bind(attempt_id.as_uuid())
                .bind(terminal.provider_id)
                .bind(terminal.provider_process_generation_id)
                .bind(terminal.origin_session_epoch.as_i64())
                .bind(terminal.terminal_id.as_uuid())
                .bind(terminal.terminal_digest.as_bytes().as_slice())
                .bind(Json(&terminal.raw_terminal))
                .bind(terminal.outcome.as_str())
                .bind(terminal.error_class.as_deref())
                .bind(
                    i64::try_from(terminal.prompt_tokens)
                        .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?,
                )
                .bind(
                    i64::try_from(terminal.completion_tokens)
                        .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?,
                )
                .bind(
                    i64::try_from(terminal.reasoning_tokens)
                        .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?,
                )
                .bind(terminal.response_digest.as_bytes().as_slice())
                .bind(terminal.rolling_digest.as_bytes().as_slice())
                .bind(
                    i64::try_from(terminal.final_generated_tokens)
                        .map_err(|_| crate::ledger::InputError::ArithmeticOverflow)?,
                )
                .bind(terminal.provider_signature.as_slice())
                .bind(reason)
                .bind(accepted_cumulative_tokens)
                .fetch_optional(self.db.pool()),
            )
            .await?;
        if recorded.is_some() {
            Ok(())
        } else {
            self.db.verify_authority(&authority).await?;
            Err(LedgerError::NotFound)
        }
    }
}

#[derive(Debug, FromRow)]
struct StartDispatchRow {
    job_version: i64,
    job_state: String,
    attempt_version: i64,
    attempt_state: String,
}

#[derive(Debug, FromRow)]
struct TerminalDispositionRow {
    job_id: Uuid,
    request_id: Uuid,
    reservation_id: Uuid,
    lease_id: Option<Uuid>,
    provider_id: Uuid,
    provider_process_generation_id: Uuid,
    origin_session_epoch: i64,
    terminal_digest: Vec<u8>,
    status: String,
    conflict: bool,
}

#[derive(Debug, FromRow)]
struct RecoveryTerminalRecordRow {
    job_id: Uuid,
    status: String,
    conflict: bool,
}

fn terminal_disposition(status: &str) -> Result<DurableTerminalDisposition, LedgerError> {
    match status {
        "settled" => Ok(DurableTerminalDisposition::Settled),
        "released" => Ok(DurableTerminalDisposition::Released),
        "settled_reviewed" => Ok(DurableTerminalDisposition::SettledReviewed),
        "released_reviewed" => Ok(DurableTerminalDisposition::ReleasedReviewed),
        "late" | "duplicate" => Ok(DurableTerminalDisposition::Late),
        "conflict" | "rejected" => Ok(DurableTerminalDisposition::Conflict),
        "pending" => Ok(DurableTerminalDisposition::ReviewPending),
        _ => Err(LedgerError::CorruptData(
            "unknown stored terminal disposition",
        )),
    }
}
