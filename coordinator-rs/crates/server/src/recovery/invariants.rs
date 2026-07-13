use std::sync::Arc;

use serde::Serialize;
use sqlx::FromRow;

use super::RecoveryService;
use crate::ledger::LedgerError;

/// One bounded invariant category reported by the recovery scanner.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct InvariantViolation {
    pub invariant: Arc<str>,
    pub count: u64,
}

/// Database-authoritative consistency report for operator and test use.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct InvariantReport {
    pub healthy: bool,
    pub violations: Vec<InvariantViolation>,
}

impl RecoveryService {
    /// Scans the finite set of cross-table money and lifecycle invariants that
    /// cannot be represented by one PostgreSQL CHECK constraint.
    pub async fn scan_invariants(&self) -> Result<InvariantReport, LedgerError> {
        let authority = self.db.authority()?;
        let rows = self
            .db
            .bounded(
                sqlx::query_as::<_, InvariantRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    violations AS (
                        SELECT
                            'invalid_balance_provenance'::TEXT AS invariant,
                            COUNT(*)::BIGINT AS violation_count
                        FROM public.balances
                        CROSS JOIN authority
                        WHERE balance_micro_usd < 0
                           OR withdrawable_micro_usd < 0
                           OR withdrawable_micro_usd > balance_micro_usd

                        UNION ALL

                        SELECT
                            'authorized_attempt_cardinality'::TEXT,
                            COUNT(*)::BIGINT
                        FROM rust_coord.inference_jobs AS jobs
                        CROSS JOIN authority
                        WHERE jobs.state IN ('start_authorized', 'running')
                          AND (
                              SELECT COUNT(*)
                              FROM rust_coord.inference_attempts AS attempts
                              WHERE attempts.job_id = jobs.job_id
                                AND attempts.state IN (
                                    'not_sent',
                                    'queued',
                                    'on_wire',
                                    'sent_unknown',
                                    'started',
                                    'terminal_recorded',
                                    'acknowledged'
                                )
                          ) <> 1

                        UNION ALL

                        SELECT
                            'active_job_without_predebit'::TEXT,
                            COUNT(*)::BIGINT
                        FROM rust_coord.inference_jobs AS jobs
                        CROSS JOIN authority
                        WHERE jobs.state IN (
                            'reserved',
                            'preparing',
                            'prepared',
                            'start_authorized',
                            'running',
                            'review_pending'
                        )
                          AND NOT jobs.reservation_pre_debited

                        UNION ALL

                        SELECT
                            'terminal_job_disposition_cardinality'::TEXT,
                            COUNT(*)::BIGINT
                        FROM rust_coord.inference_jobs AS jobs
                        CROSS JOIN authority
                        WHERE jobs.state IN (
                            'settled',
                            'released',
                            'settled_reviewed',
                            'released_reviewed'
                        )
                          AND (
                              SELECT COUNT(*)
                              FROM rust_coord.financial_operations AS operations
                              WHERE operations.job_id = jobs.job_id
                                AND operations.kind IN ('settle', 'release')
                                AND operations.status IN ('applied', 'released')
                          ) <> 1

                        UNION ALL

                        SELECT
                            'pending_terminal_without_authorized_job'::TEXT,
                            COUNT(*)::BIGINT
                        FROM rust_coord.provider_terminals AS terminals
                        JOIN rust_coord.inference_jobs AS jobs
                          ON jobs.job_id = terminals.job_id
                        CROSS JOIN authority
                        WHERE terminals.status = 'pending'
                          AND jobs.state NOT IN ('start_authorized', 'running')

                        UNION ALL

                        SELECT
                            'settled_usage_exceeds_frozen_bounds'::TEXT,
                            COUNT(*)::BIGINT
                        FROM rust_coord.inference_jobs AS jobs
                        CROSS JOIN authority
                        WHERE jobs.state IN ('settled', 'settled_reviewed')
                          AND (
                              jobs.usage_prompt_tokens IS NULL
                              OR jobs.usage_completion_tokens IS NULL
                              OR jobs.billable_input_tokens IS NULL
                              OR jobs.bounded_output_tokens IS NULL
                              OR jobs.usage_prompt_tokens <> jobs.billable_input_tokens
                              OR jobs.usage_completion_tokens
                                 > jobs.bounded_output_tokens
                              OR jobs.usage_completion_tokens
                                 > jobs.accepted_cumulative_tokens
                          )
                    )
                    SELECT invariant, violation_count
                    FROM violations
                    WHERE violation_count > 0
                    ORDER BY invariant
                    "#,
                )
                .bind(authority.owner_id())
                .bind(authority.epoch())
                .fetch_all(self.db.pool()),
            )
            .await?;
        if rows.is_empty() {
            self.db.verify_authority(&authority).await?;
        }
        let violations = rows
            .into_iter()
            .map(|row| {
                Ok(InvariantViolation {
                    invariant: row.invariant.into(),
                    count: u64::try_from(row.violation_count)
                        .map_err(|_| LedgerError::CorruptData("negative invariant count"))?,
                })
            })
            .collect::<Result<Vec<_>, LedgerError>>()?;
        Ok(InvariantReport {
            healthy: violations.is_empty(),
            violations,
        })
    }
}

#[derive(Debug, FromRow)]
struct InvariantRow {
    invariant: String,
    violation_count: i64,
}
