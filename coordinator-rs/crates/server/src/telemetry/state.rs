//! Bounded, PII-free durable state diagnostics and Datadog gauges.

use std::{collections::BTreeMap, time::Duration};

use serde::Serialize;
use sqlx::Row as _;
use thiserror::Error;
use tokio::time::timeout;

use crate::database::Database;

use super::datadog::{self, Metric, Tag, TagKey};

const STATE_CATALOG: &[(&str, &[&str])] = &[
    (
        "inference_jobs",
        &[
            "reserved",
            "preparing",
            "prepared",
            "start_authorized",
            "running",
            "review_pending",
        ],
    ),
    (
        "inference_attempts",
        &[
            "not_sent",
            "queued",
            "on_wire",
            "sent_unknown",
            "prepared",
            "started",
            "terminal_recorded",
        ],
    ),
    ("provider_terminals", &["pending", "conflict"]),
    ("financial_operations", &["pending"]),
    ("external_events", &["pending", "processing"]),
    ("outbox", &["pending", "processing"]),
    ("fee_allocations", &["pending", "processing", "failed"]),
    ("fee_projection_checkpoints", &["running", "failed"]),
    ("mdm_command_expectations", &["pending"]),
    ("telemetry_events", &["pending", "processing"]),
];

#[derive(Clone, Debug, Serialize)]
pub struct DurableStateCount {
    pub relation: &'static str,
    pub state: &'static str,
    pub count: i64,
    pub oldest_age_seconds: f64,
}

#[derive(Clone, Copy, Debug, Serialize)]
pub struct RollbackGuardSnapshot {
    pub go_fallback_safe: bool,
    pub unresolved: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct DurableStateSnapshot {
    pub states: Vec<DurableStateCount>,
    pub rollback_guard: RollbackGuardSnapshot,
}

impl DurableStateSnapshot {
    pub fn emit_datadog(&self) {
        for state in &self.states {
            let metric = match state.relation {
                "outbox" => Metric::OutboxState,
                "fee_allocations" | "fee_projection_checkpoints" => Metric::FeeState,
                _ => Metric::JobsState,
            };
            let tags = [
                Tag::new(TagKey::Kind, state.relation),
                Tag::new(TagKey::State, state.state),
            ];
            datadog::gauge(metric, state.count.max(0) as f64, &tags);
            datadog::gauge(
                Metric::JobsAgeSeconds,
                state.oldest_age_seconds.max(0.0),
                &tags,
            );
        }
        datadog::gauge(
            Metric::RollbackGuard,
            f64::from(u8::from(self.rollback_guard.go_fallback_safe)),
            &[Tag::new(TagKey::Mode, "go_fallback")],
        );
    }
}

pub async fn snapshot(database: &Database) -> Result<DurableStateSnapshot, StateDiagnosticsError> {
    let query = sqlx::query(
        r#"
        WITH durable(relation, state, updated_at) AS (
            SELECT 'inference_jobs'::TEXT, state::TEXT, updated_at
            FROM rust_coord.inference_jobs
            WHERE state IN (
                'reserved','preparing','prepared','start_authorized','running','review_pending'
            )
            UNION ALL
            SELECT 'inference_attempts', state::TEXT, updated_at
            FROM rust_coord.inference_attempts
            WHERE state IN (
                'not_sent','queued','on_wire','sent_unknown','prepared','started','terminal_recorded'
            )
            UNION ALL
            SELECT 'provider_terminals', status::TEXT, updated_at
            FROM rust_coord.provider_terminals
            WHERE status IN ('pending','conflict')
            UNION ALL
            SELECT 'financial_operations', status::TEXT, updated_at
            FROM rust_coord.financial_operations
            WHERE status = 'pending'
            UNION ALL
            SELECT 'external_events', status::TEXT, updated_at
            FROM rust_coord.external_events
            WHERE status IN ('pending','processing')
            UNION ALL
            SELECT 'outbox', status::TEXT, updated_at
            FROM rust_coord.outbox
            WHERE status IN ('pending','processing')
            UNION ALL
            SELECT 'fee_allocations', status::TEXT, updated_at
            FROM rust_coord.fee_allocations
            WHERE status IN ('pending','processing','failed')
            UNION ALL
            SELECT 'fee_projection_checkpoints', status::TEXT, updated_at
            FROM rust_coord.fee_projection_checkpoints
            WHERE status IN ('running','failed')
            UNION ALL
            SELECT 'mdm_command_expectations', status::TEXT, issued_at
            FROM rust_coord.mdm_command_expectations
            WHERE status = 'pending'
            UNION ALL
            SELECT 'telemetry_events', status::TEXT, updated_at
            FROM rust_coord.telemetry_events
            WHERE status IN ('pending','processing')
        ),
        state_counts AS (
            SELECT relation, state, COUNT(*)::BIGINT AS count,
                   COALESCE(MAX(EXTRACT(EPOCH FROM (NOW() - updated_at))), 0)::DOUBLE PRECISION
                       AS oldest_age_seconds
            FROM durable
            GROUP BY relation, state
        ),
        rollback_guard AS (
            SELECT (
                (SELECT COUNT(*) FROM rust_coord.inference_jobs
                 WHERE state NOT IN (
                    'settled','released','settled_reviewed','released_reviewed'
                 ) OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.inference_attempts
                 WHERE state NOT IN ('aborted','acknowledged')
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.provider_terminals
                 WHERE status NOT IN (
                    'settled','released','settled_reviewed','released_reviewed',
                    'duplicate','late','rejected'
                 ) OR (conflict AND status NOT IN ('settled_reviewed','released_reviewed'))
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.financial_operations
                 WHERE status NOT IN ('applied','released','failed')
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.external_events
                 WHERE status NOT IN ('applied','rejected','ignored','failed')
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.outbox
                 WHERE status NOT IN ('delivered','failed','cancelled')
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.fee_allocations
                 WHERE status NOT IN ('projected','cancelled')
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.fee_projection_checkpoints
                 WHERE status <> 'idle'
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
              + (SELECT COUNT(*) FROM rust_coord.mdm_command_expectations
                 WHERE status = 'pending')
              + (SELECT COUNT(*) FROM rust_coord.telemetry_events
                 WHERE status NOT IN ('delivered','dropped')
                    OR worker_owner IS NOT NULL OR lease_until IS NOT NULL)
            )::BIGINT AS unresolved
        )
        SELECT relation, state, count, oldest_age_seconds, NULL::BIGINT AS rollback_unresolved
        FROM state_counts
        UNION ALL
        SELECT '__rollback_guard', 'go_fallback', 0, 0::DOUBLE PRECISION, unresolved
        FROM rollback_guard
        ORDER BY relation, state
        "#,
    )
    .fetch_all(database.pool());
    let rows = timeout(database.operation_timeout(), query)
        .await
        .map_err(|_| StateDiagnosticsError::Timeout(database.operation_timeout()))?
        .map_err(StateDiagnosticsError::Database)?;

    let mut found = BTreeMap::<(String, String), (i64, f64)>::new();
    let mut rollback_unresolved = None;
    for row in rows {
        let relation = row.get::<String, _>("relation");
        let state = row.get::<String, _>("state");
        if relation == "__rollback_guard" {
            rollback_unresolved = row.get::<Option<i64>, _>("rollback_unresolved");
            continue;
        }
        let key = (relation, state);
        if !catalog_contains(&key.0, &key.1) {
            return Err(StateDiagnosticsError::UnexpectedState {
                relation: key.0,
                state: key.1,
            });
        }
        found.insert(
            key,
            (
                row.get::<i64, _>("count").max(0),
                row.get::<f64, _>("oldest_age_seconds").max(0.0),
            ),
        );
    }

    let states = STATE_CATALOG
        .iter()
        .flat_map(|(relation, states)| {
            states.iter().map(|state| {
                let (count, oldest_age_seconds) = found
                    .get(&(relation.to_string(), state.to_string()))
                    .copied()
                    .unwrap_or_default();
                DurableStateCount {
                    relation,
                    state,
                    count,
                    oldest_age_seconds,
                }
            })
        })
        .collect();
    let unresolved = rollback_unresolved
        .ok_or(StateDiagnosticsError::MissingRollbackGuard)?
        .max(0);
    Ok(DurableStateSnapshot {
        states,
        rollback_guard: RollbackGuardSnapshot {
            go_fallback_safe: unresolved == 0,
            unresolved,
        },
    })
}

fn catalog_contains(relation: &str, state: &str) -> bool {
    STATE_CATALOG
        .iter()
        .any(|(known_relation, states)| *known_relation == relation && states.contains(&state))
}

#[derive(Debug, Error)]
pub enum StateDiagnosticsError {
    #[error("read-only state diagnostics exceeded {0:?}")]
    Timeout(Duration),
    #[error("read-only state diagnostics failed: {0}")]
    Database(sqlx::Error),
    #[error("read-only state diagnostics found unexpected {relation} state {state}")]
    UnexpectedState { relation: String, state: String },
    #[error("read-only state diagnostics omitted the rollback guard")]
    MissingRollbackGuard,
}
