use std::{collections::BTreeMap, sync::Arc, time::Duration};

use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Query, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use futures_util::StreamExt as _;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Row, types::Json as SqlJson};
use tokio::time::{Instant, sleep};

use crate::telemetry::{
    datadog::{self, Metric, Tag, TagKey},
    state as state_metrics,
};

use super::{
    OperationsState,
    auth::{require_admin, require_admin_key, require_read_only},
    error::OperationsError,
};

const MAX_ADMIN_BODY: usize = 64 * 1024;
const DEFAULT_BROWSE_LIMIT: i64 = 1_000;
const MAX_EXPORT_ROWS: i64 = 50_000;
const MAX_AUTH_RESPONSE: usize = 64 * 1024;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SetRole {
    account_id: String,
    role: String,
}

pub(super) async fn set_user_role(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &request)?;
    let input: SetRole = json_body(request, MAX_ADMIN_BODY).await?;
    if !valid_account(&input.account_id) {
        return Err(OperationsError::bad_request("account_id is required"));
    }
    if !matches!(input.role.as_str(), "" | "service") {
        return Err(OperationsError::bad_request(
            "role must be \"service\" or empty",
        ));
    }
    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin user role update", error))?;
    let result = sqlx::query("UPDATE public.users SET role=$2 WHERE account_id=$1")
        .bind(&input.account_id)
        .bind(&input.role)
        .execute(transaction.connection())
        .await
        .map_err(|error| OperationsError::internal("update user role", error))?;
    if result.rows_affected() == 0 {
        return Err(OperationsError::not_found("user not found"));
    }
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit user role", error))?;
    state.mark_mutation();
    state.metrics.increment("admin_user_role_updates");
    Ok(Json(json!({
        "status": "role_updated",
        "account_id": input.account_id,
        "role": input.role,
    })))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SetPlatformFee {
    account_id: String,
    platform_fee_percent: Option<i64>,
}

pub(super) async fn set_user_platform_fee(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &request)?;
    let input: SetPlatformFee = json_body(request, MAX_ADMIN_BODY).await?;
    if !valid_account(&input.account_id) {
        return Err(OperationsError::bad_request("account_id is required"));
    }
    if input
        .platform_fee_percent
        .is_some_and(|value| !(0..=100).contains(&value))
    {
        return Err(OperationsError::bad_request(
            "platform_fee_percent must be between 0 and 100",
        ));
    }
    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin platform fee update", error))?;
    let result = sqlx::query("UPDATE public.users SET platform_fee_percent=$2 WHERE account_id=$1")
        .bind(&input.account_id)
        .bind(input.platform_fee_percent)
        .execute(transaction.connection())
        .await
        .map_err(|error| OperationsError::internal("update platform fee", error))?;
    if result.rows_affected() == 0 {
        return Err(OperationsError::not_found("user not found"));
    }
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit platform fee", error))?;
    state.mark_mutation();
    state.metrics.increment("admin_platform_fee_updates");
    Ok(Json(json!({
        "status": "platform_fee_updated",
        "account_id": input.account_id,
        "platform_fee_percent": input.platform_fee_percent,
    })))
}

#[derive(Debug, Deserialize)]
pub(super) struct MetricsQuery {
    format: Option<String>,
}

pub(super) async fn metrics(
    State(state): State<Arc<OperationsState>>,
    Query(query): Query<MetricsQuery>,
    headers: HeaderMap,
) -> Result<Response, OperationsError> {
    require_read_only(&state.auth, &headers)?;
    let counters = state.metrics.snapshot();
    let telemetry = state.telemetry.summary();
    let telemetry_delivery = state.telemetry_service.metrics();
    let datadog_bridge = datadog::snapshot();
    let durable_states = state_metrics::snapshot(&state.database)
        .await
        .map_err(|error| OperationsError::internal("snapshot durable state counts", error))?;
    let fleet = state.pilot().map(|pilot| pilot.fleet_snapshot());
    let pilot_telemetry = state.pilot().map(|pilot| {
        let latency = pilot.telemetry().latency_summary().map(|summary| {
            json!({
                "samples": summary.samples,
                "minimum_ms": summary.minimum.as_secs_f64() * 1000.0,
                "p50_ms": summary.p50.as_secs_f64() * 1000.0,
                "p95_ms": summary.p95.as_secs_f64() * 1000.0,
                "p99_ms": summary.p99.as_secs_f64() * 1000.0,
                "maximum_ms": summary.maximum.as_secs_f64() * 1000.0,
            })
        });
        json!({
            "dropped": pilot.telemetry().dropped(),
            "remaining_capacity": pilot.telemetry().remaining_capacity(),
            "latency": latency,
        })
    });
    let gauges = json!({
        "draining": state.is_draining(),
        "mutation_count": state.mutation_count(),
        "providers": fleet.as_ref().map_or(0, |snapshot| snapshot.provider_count()),
        "active_leases": fleet.as_ref().map_or(0, |snapshot| snapshot.active_lease_count()),
        "fleet_revision": fleet.as_ref().map_or(0, |snapshot| snapshot.revision().get()),
        "active_http_inference": state.active_http_inference(),
        "active_http_mutations": state.active_http_mutations(),
        "active_external_operations": state.active_external_operations(),
        "ownership_healthy": state.database.authority().is_some_and(|(_, status)| status.is_healthy()),
        "ownership_epoch": state.database.authority().map_or(0, |(context, _)| context.epoch()),
        "public_schema_version": state.database.compatibility().public_version,
        "rust_schema_version": state.database.compatibility().rust_version,
        "migration_checksum_valid": state.database.compatibility().migration_checksum_valid,
    });
    if query.format.as_deref() == Some("prom") {
        let mut body = String::new();
        for (name, value) in &counters {
            body.push_str(&format!("# TYPE {name} counter\n{name} {value}\n"));
        }
        body.push_str("# TYPE operations_draining gauge\n");
        body.push_str(&format!(
            "operations_draining {}\n",
            u8::from(state.is_draining())
        ));
        body.push_str("# TYPE operations_mutations counter\n");
        body.push_str(&format!(
            "operations_mutations {}\n",
            state.mutation_count()
        ));
        for (name, value) in [
            (
                "operations_active_http_inference",
                state.active_http_inference(),
            ),
            (
                "operations_active_http_mutations",
                state.active_http_mutations(),
            ),
            (
                "operations_active_external_operations",
                state.active_external_operations(),
            ),
        ] {
            body.push_str(&format!("# TYPE {name} gauge\n{name} {value}\n"));
        }
        for (name, value) in [
            (
                "telemetry_durable_accepted_total",
                telemetry_delivery.accepted,
            ),
            (
                "telemetry_durable_delivered_total",
                telemetry_delivery.delivered,
            ),
            (
                "telemetry_durable_retried_total",
                telemetry_delivery.retried,
            ),
            (
                "telemetry_durable_dropped_total",
                telemetry_delivery.dropped,
            ),
            (
                "telemetry_durable_sink_failures_total",
                telemetry_delivery.sink_failures,
            ),
        ] {
            body.push_str(&format!("# TYPE {name} counter\n{name} {value}\n"));
        }
        for (name, value) in [
            ("datadog_bridge_accepted_total", datadog_bridge.accepted),
            (
                "datadog_bridge_dropped_full_total",
                datadog_bridge.dropped_full,
            ),
            (
                "datadog_bridge_dropped_closed_total",
                datadog_bridge.dropped_closed,
            ),
            (
                "datadog_bridge_dropped_transport_total",
                datadog_bridge.dropped_transport,
            ),
            (
                "datadog_bridge_send_failures_total",
                datadog_bridge.send_failures,
            ),
        ] {
            body.push_str(&format!("# TYPE {name} counter\n{name} {value}\n"));
        }
        body.push_str("# TYPE datadog_bridge_remaining_capacity gauge\n");
        body.push_str(&format!(
            "datadog_bridge_remaining_capacity {}\n",
            datadog_bridge.remaining_capacity
        ));
        let mut response = Body::from(body).into_response();
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/plain; version=0.0.4"),
        );
        return Ok(response);
    }
    Ok(Json(json!({
        "counters": counters,
        "gauges": gauges,
        "telemetry": telemetry,
        "durable_telemetry": telemetry_delivery,
        "datadog_bridge": datadog_bridge,
        "pilot_telemetry": pilot_telemetry,
        "durable_states": durable_states.states,
        "rollback_guard": durable_states.rollback_guard,
        "build": {
            "binary": "rust",
            "version": option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
            "commit": option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
            "date": option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
            "rust_package_version": env!("CARGO_PKG_VERSION"),
        },
    }))
    .into_response())
}

pub(super) async fn base_rewards(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    require_admin_key(&state.auth, request.headers())?;
    let epoch: Option<String> = sqlx::query_scalar(
        "SELECT epoch_id FROM public.provider_floor_draws ORDER BY created_at DESC LIMIT 1",
    )
    .fetch_optional(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load base reward epoch", error))?;
    let Some(epoch) = epoch else {
        return Ok(Json(json!({"enabled": false, "draws": []})));
    };
    let rows = sqlx::query(
        r#"
        SELECT provider_key, account_id, amount_micro_usd, floor_micro_usd,
               earned_micro_usd, uptime_frac, memory_gb,
               to_char(created_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at
        FROM public.provider_floor_draws
        WHERE epoch_id=$1 ORDER BY amount_micro_usd DESC, provider_key LIMIT 1000
        "#,
    )
    .bind(&epoch)
    .fetch_all(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load base reward draws", error))?;
    let mut used = 0_i64;
    let draws = rows
        .into_iter()
        .map(|row| {
            let amount = row.get::<i64, _>("amount_micro_usd");
            used = used.saturating_add(amount);
            json!({
                "provider_key": row.get::<String, _>("provider_key"),
                "account_id": row.get::<String, _>("account_id"),
                "amount_micro_usd": amount,
                "floor_micro_usd": row.get::<i64, _>("floor_micro_usd"),
                "earned_micro_usd": row.get::<i64, _>("earned_micro_usd"),
                "uptime_frac": row.get::<f64, _>("uptime_frac"),
                "memory_gb": row.get::<i32, _>("memory_gb"),
                "created_at": row.get::<String, _>("created_at"),
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "enabled": true,
        "epoch_id": epoch,
        "pool_used": used,
        "draw_count": draws.len(),
        "draws": draws,
    })))
}

pub(super) async fn utilization(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_read_only(&state.auth, &headers)?;
    let Some(pilot) = state.pilot() else {
        return Ok(Json(json!({
            "providers": 0, "active_leases": 0, "by_model": [],
            "token_capacity": 0, "tokens_in_use": 0,
            "concurrency_limit": 0, "concurrency_in_use": 0,
            "protocol": {
                "v1": 0,
                "v2": 0,
                "v2_inference_eligible": 0,
            },
        })));
    };
    let fleet = pilot.fleet_snapshot();
    let (protocol_v1, protocol_v2, protocol_v2_inference_eligible) =
        pilot.provider_protocol_counts();
    let mut token_capacity = 0_u64;
    let mut tokens_in_use = 0_u64;
    let mut concurrency_limit = 0_u64;
    let mut concurrency_in_use = 0_u64;
    let mut by_model = BTreeMap::<String, (u64, u64, u64, u64, usize)>::new();
    for runtime in fleet.providers() {
        let provider = runtime.provider();
        let capacity = provider.capacity();
        token_capacity = token_capacity.saturating_add(capacity.token_capacity().get());
        tokens_in_use = tokens_in_use.saturating_add(capacity.tokens_in_use().get());
        concurrency_limit =
            concurrency_limit.saturating_add(u64::from(capacity.concurrency_limit()));
        concurrency_in_use =
            concurrency_in_use.saturating_add(u64::from(capacity.concurrency_in_use()));
        let current = by_model
            .entry(provider.fence().model_id.to_string())
            .or_default();
        current.0 = current.0.saturating_add(capacity.token_capacity().get());
        current.1 = current.1.saturating_add(capacity.tokens_in_use().get());
        current.2 = current
            .2
            .saturating_add(u64::from(capacity.concurrency_limit()));
        current.3 = current
            .3
            .saturating_add(u64::from(capacity.concurrency_in_use()));
        current.4 = current.4.saturating_add(1);
    }
    let by_model = by_model
        .into_iter()
        .map(|(model, value)| {
            json!({
                "model": model,
                "token_capacity": value.0,
                "tokens_in_use": value.1,
                "concurrency_limit": value.2,
                "concurrency_in_use": value.3,
                "providers": value.4,
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "providers": fleet.provider_count(),
        "active_leases": fleet.active_lease_count(),
        "token_capacity": token_capacity,
        "tokens_in_use": tokens_in_use,
        "concurrency_limit": concurrency_limit,
        "concurrency_in_use": concurrency_in_use,
        "token_utilization": ratio(tokens_in_use, token_capacity),
        "concurrency_utilization": ratio(concurrency_in_use, concurrency_limit),
        "protocol": {
            "v1": protocol_v1,
            "v2": protocol_v2,
            "v2_inference_eligible": protocol_v2_inference_eligible,
        },
        "by_model": by_model,
    })))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DrainRequest {
    draining: Option<bool>,
    mode: Option<DrainMode>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
enum DrainMode {
    Inference,
    Handoff,
}

pub(super) async fn drain(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &request)?;
    let body = to_bytes(request.into_body(), MAX_ADMIN_BODY)
        .await
        .map_err(|_| OperationsError::payload_too_large("drain body exceeds 64KB"))?;
    let request = if body.is_empty() {
        DrainRequest {
            draining: None,
            mode: None,
        }
    } else {
        serde_json::from_slice::<DrainRequest>(&body)
            .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?
    };
    let draining = request.draining.unwrap_or(true);
    let mode = request.mode.unwrap_or(DrainMode::Inference);
    if mode == DrainMode::Handoff && !draining {
        return Err(OperationsError::bad_request(
            "handoff drain cannot be disabled",
        ));
    }
    match mode {
        DrainMode::Inference => state.set_draining(draining),
        DrainMode::Handoff => state.begin_handoff(),
    }
    let draining = state.is_draining();
    state.metrics.increment("drain_changes");
    let mut quiescent = !draining;
    if draining {
        let deadline = Instant::now() + state.operation_timeout;
        loop {
            if ready_to_fence_external(&state).await? {
                state.admission.fence_external();
            }
            if state.admission.external_fenced()
                && state.active_external_operations() == 0
                && ready_to_fence_external(&state).await?
            {
                quiescent = true;
                break;
            }
            if Instant::now() >= deadline {
                break;
            }
            sleep(Duration::from_millis(25)).await;
        }
    }
    datadog::gauge(
        Metric::DrainState,
        f64::from(u8::from(draining)),
        &[Tag::new(
            TagKey::Mode,
            match mode {
                DrainMode::Inference => "inference",
                DrainMode::Handoff => "handoff",
            },
        )],
    );
    datadog::gauge(Metric::Quiescent, f64::from(u8::from(quiescent)), &[]);
    Ok(Json(json!({
        "draining": draining,
        "mode": match mode {
            DrainMode::Inference => "inference",
            DrainMode::Handoff => "handoff",
        },
        "quiescent": quiescent,
        "external_fenced": state.admission.external_fenced(),
        "inflight": state.pilot().map_or(0, |pilot| pilot.active_request_count()),
        "http_inference": state.active_http_inference(),
        "http_mutations": state.active_http_mutations(),
        "external_operations": state.active_external_operations(),
    })))
}

async fn ready_to_fence_external(state: &OperationsState) -> Result<bool, OperationsError> {
    let durable_pending: i64 = sqlx::query_scalar(
        r#"
        SELECT
            (SELECT COUNT(*) FROM rust_coord.inference_jobs
             WHERE state IN (
               'reserved','preparing','prepared','start_authorized',
               'running','review_pending'
             ))
          + (SELECT COUNT(*) FROM rust_coord.provider_terminals
             WHERE status='pending')
          + (SELECT COUNT(*) FROM rust_coord.external_events
             WHERE status IN ('pending','processing'))
          + (SELECT COUNT(*) FROM rust_coord.outbox
             WHERE status IN ('pending','processing'))
          + (SELECT COUNT(*) FROM rust_coord.fee_allocations
             WHERE status IN ('pending','processing','failed'))
          + (SELECT COUNT(*) FROM rust_coord.telemetry_events
             WHERE status IN ('pending','processing'))
        "#,
    )
    .fetch_one(state.pool())
    .await
    .map_err(|error| OperationsError::internal("inspect drain progress", error))?;
    let fleet = state.pilot().map(|pilot| pilot.fleet_snapshot());
    let active_leases = fleet
        .as_ref()
        .map_or(0, |snapshot| snapshot.active_lease_count());
    let writer_reservations = fleet.as_ref().map_or(0, |snapshot| {
        snapshot
            .providers()
            .map(|provider| {
                provider
                    .writer_headroom()
                    .available_items()
                    .saturating_sub(provider.effective_writer_items())
            })
            .sum::<usize>()
    });
    Ok(durable_pending == 0
        && state.active_http_inference() == 0
        && state.active_http_mutations() == 0
        && state
            .pilot()
            .map_or(0, |pilot| pilot.active_request_count())
            == 0
        && active_leases == 0
        && writer_reservations == 0)
}

pub(super) async fn quiescence(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_read_only(&state.auth, &headers)?;
    let fleet = state.pilot().map(|pilot| pilot.fleet_snapshot());
    let providers = fleet
        .as_ref()
        .map_or(0, |snapshot| snapshot.provider_count());
    let leases = fleet
        .as_ref()
        .map_or(0, |snapshot| snapshot.active_lease_count());
    let requests = state
        .pilot()
        .map_or(0, |pilot| pilot.active_request_count());
    let supervisor = state.pilot().map(crate::pilot::PilotHandle::readiness);
    let pilot_ready = supervisor
        .as_ref()
        .is_none_or(crate::supervisor::SupervisorReadiness::is_ready);
    let writer_count = fleet
        .as_ref()
        .map_or(0, |snapshot| snapshot.providers().count());
    let (writer_available_items, writer_available_bytes, writer_reserved_items) = fleet
        .as_ref()
        .map(|snapshot| {
            snapshot.providers().fold(
                (0_usize, 0_usize, 0_usize),
                |(items, bytes, reserved), provider| {
                    (
                        items.saturating_add(provider.effective_writer_items()),
                        bytes.saturating_add(provider.effective_writer_bytes()),
                        reserved.saturating_add(
                            provider
                                .writer_headroom()
                                .available_items()
                                .saturating_sub(provider.effective_writer_items()),
                        ),
                    )
                },
            )
        })
        .unwrap_or_default();
    let durable = sqlx::query(
        r#"
        SELECT
          (SELECT COUNT(*) FROM rust_coord.inference_jobs
             WHERE state IN (
               'reserved','preparing','prepared','start_authorized',
               'running','review_pending'
             ))::BIGINT AS active_jobs,
          (SELECT COUNT(*) FROM rust_coord.provider_terminals
             WHERE status='pending')::BIGINT AS pending_terminals,
          (SELECT COUNT(*) FROM rust_coord.external_events
             WHERE status IN ('pending','processing'))::BIGINT AS pending_external_events,
          (SELECT COUNT(*) FROM rust_coord.outbox
             WHERE status IN ('pending','processing'))::BIGINT AS pending_outbox,
          (SELECT COUNT(*) FROM rust_coord.fee_allocations
             WHERE status IN ('pending','processing','failed'))::BIGINT AS pending_fees,
          (SELECT COUNT(*) FROM rust_coord.telemetry_events
             WHERE status IN ('pending','processing'))::BIGINT AS pending_telemetry,
          (
            (SELECT COUNT(*) FROM rust_coord.inference_jobs
               WHERE worker_owner IS NOT NULL)
            + (SELECT COUNT(*) FROM rust_coord.provider_terminals
               WHERE worker_owner IS NOT NULL)
            + (SELECT COUNT(*) FROM rust_coord.external_events
               WHERE worker_owner IS NOT NULL)
            + (SELECT COUNT(*) FROM rust_coord.outbox
               WHERE worker_owner IS NOT NULL)
            + (SELECT COUNT(*) FROM rust_coord.fee_allocations
               WHERE worker_owner IS NOT NULL)
            + (SELECT COUNT(*) FROM rust_coord.telemetry_events
               WHERE worker_owner IS NOT NULL)
          )::BIGINT AS active_recovery_leases
        "#,
    )
    .fetch_one(state.pool())
    .await
    .map_err(|error| OperationsError::internal("snapshot durable quiescence", error))?;
    let active_jobs = durable.get::<i64, _>("active_jobs");
    let pending_terminals = durable.get::<i64, _>("pending_terminals");
    let pending_external_events = durable.get::<i64, _>("pending_external_events");
    let pending_outbox = durable.get::<i64, _>("pending_outbox");
    let pending_fees = durable.get::<i64, _>("pending_fees");
    let pending_telemetry = durable.get::<i64, _>("pending_telemetry");
    let active_recovery_leases = durable.get::<i64, _>("active_recovery_leases");
    let ownership_healthy = state
        .database
        .authority()
        .is_some_and(|(_, status)| status.is_healthy());
    let http_inference = state.active_http_inference();
    let http_mutations = state.active_http_mutations();
    let external_operations = state.active_external_operations();
    let quiescent = leases == 0
        && requests == 0
        && writer_reserved_items == 0
        && http_inference == 0
        && http_mutations == 0
        && external_operations == 0
        && active_jobs == 0
        && pending_terminals == 0
        && pending_external_events == 0
        && pending_outbox == 0
        && pending_fees == 0
        && pending_telemetry == 0
        && active_recovery_leases == 0
        && ownership_healthy
        && pilot_ready;
    Ok(Json(json!({
        "draining": state.is_draining(),
        "external_fenced": state.admission.external_fenced(),
        "supervisor": {
            "status": supervisor
                .as_ref()
                .map_or_else(|| "absent".to_owned(), |snapshot| format!("{:?}", snapshot.status).to_ascii_lowercase()),
            "ready": pilot_ready,
            "failed": supervisor.as_ref().is_some_and(|snapshot| snapshot.failure.is_some()),
        },
        "fleet": {
            "providers_connected": providers,
            "active_leases": leases,
            "revision": fleet.as_ref().map_or(0, |snapshot| snapshot.revision().get()),
        },
        "requests": {
            "active": requests,
            "durable_active": active_jobs,
            "http_inference": http_inference,
            "http_mutations": http_mutations,
        },
        "writers": {
            "active": writer_count,
            "available_items": writer_available_items,
            "available_bytes": writer_available_bytes,
            "reserved_items": writer_reserved_items,
        },
        "recovery": {
            "pending_terminals": pending_terminals,
            "pending_external_events": pending_external_events,
            "active_leases": active_recovery_leases,
            "active_external_operations": external_operations,
        },
        "outbox": {
            "pending": pending_outbox,
            "pending_fee_allocations": pending_fees,
        },
        "ownership_healthy": ownership_healthy,
        "telemetry": state.telemetry.summary(),
        "durable_telemetry": {
            "pending": pending_telemetry,
            "delivery": state.telemetry_service.metrics(),
        },
        "quiescent": quiescent,
    })))
}

#[derive(Debug, Deserialize)]
pub(super) struct RouteQuery {
    since: Option<String>,
    limit: Option<i64>,
    provider: Option<String>,
    model: Option<String>,
    outcome: Option<String>,
    final_status: Option<String>,
    format: Option<String>,
}

pub(super) async fn routes(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_admin_key(&state.auth, &headers)?;
    let routes = crate::surface::registered_routes();
    Ok(Json(json!({
        "schema_version": 1,
        "object": "list",
        "count": routes.len(),
        "data": routes,
    })))
}

pub(super) async fn routes_export(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<RouteQuery>,
) -> Result<Response, OperationsError> {
    require_admin_key(&state.auth, &headers)?;
    let records = route_records(state.pool(), &query, export_limit(query.limit)).await?;
    export_records("routes", query.format.as_deref(), &records)
}

#[derive(Debug, Deserialize)]
pub(super) struct RejectionQuery {
    since: Option<String>,
    limit: Option<i64>,
    reason: Option<String>,
    model: Option<String>,
    could_have_served: Option<bool>,
    format: Option<String>,
}

pub(super) async fn rejections(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<RejectionQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_admin_key(&state.auth, &headers)?;
    let records = rejection_records(state.pool(), &query, browse_limit(query.limit)).await?;
    Ok(Json(json!({
        "object": "list",
        "count": records.len(),
        "data": records,
    })))
}

pub(super) async fn rejections_export(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<RejectionQuery>,
) -> Result<Response, OperationsError> {
    require_admin_key(&state.auth, &headers)?;
    let records = rejection_records(state.pool(), &query, export_limit(query.limit)).await?;
    export_records("rejections", query.format.as_deref(), &records)
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthInit {
    email: String,
}

pub(super) async fn auth_init(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    let input: AuthInit = json_body(request, MAX_ADMIN_BODY).await?;
    let config = state
        .settings
        .admin_otp
        .as_ref()
        .ok_or_else(|| OperationsError::unavailable("admin OTP is not configured"))?;
    let email = normalize_admin_email(config, &input.email)?;
    let url = config
        .base_url
        .join("init")
        .map_err(|error| OperationsError::internal("construct OTP init URL", error))?;
    let response = state
        .http_client
        .post(url)
        .basic_auth(config.app_id.as_ref(), Some(config.app_secret.as_ref()))
        .header("privy-app-id", config.app_id.as_ref())
        .json(&json!({"email": email}))
        .timeout(config.request_timeout)
        .send()
        .await
        .map_err(|error| OperationsError::internal("send admin OTP", error))?;
    if !response.status().is_success() {
        return Err(OperationsError::internal(
            "send admin OTP",
            format!("identity provider returned {}", response.status()),
        ));
    }
    state.metrics.increment("admin_otp_init");
    Ok(Json(json!({"status": "otp_sent", "email": email})))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthVerify {
    email: String,
    code: String,
}

pub(super) async fn auth_verify(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    let input: AuthVerify = json_body(request, MAX_ADMIN_BODY).await?;
    let config = state
        .settings
        .admin_otp
        .as_ref()
        .ok_or_else(|| OperationsError::unavailable("admin OTP is not configured"))?;
    let email = normalize_admin_email(config, &input.email)?;
    if input.code.is_empty()
        || input.code.len() > 32
        || !input.code.bytes().all(|byte| byte.is_ascii_alphanumeric())
    {
        return Err(OperationsError::bad_request("valid OTP code is required"));
    }
    let url = config
        .base_url
        .join("authenticate")
        .map_err(|error| OperationsError::internal("construct OTP verify URL", error))?;
    let response = state
        .http_client
        .post(url)
        .basic_auth(config.app_id.as_ref(), Some(config.app_secret.as_ref()))
        .header("privy-app-id", config.app_id.as_ref())
        .json(&json!({"email": email, "code": input.code}))
        .timeout(config.request_timeout)
        .send()
        .await
        .map_err(|error| OperationsError::internal("verify admin OTP", error))?;
    if response.status() == StatusCode::UNAUTHORIZED
        || response.status() == StatusCode::FORBIDDEN
        || response.status() == StatusCode::BAD_REQUEST
    {
        return Err(OperationsError::unauthorized("OTP verification failed"));
    }
    if !response.status().is_success() {
        return Err(OperationsError::internal(
            "verify admin OTP",
            format!("identity provider returned {}", response.status()),
        ));
    }
    let bytes = bounded_response(response, MAX_AUTH_RESPONSE).await?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|error| OperationsError::internal("decode OTP response", error))?;
    let token = value
        .get("token")
        .and_then(Value::as_str)
        .filter(|token| !token.is_empty() && token.len() <= 16 * 1024)
        .ok_or_else(|| OperationsError::internal("decode OTP response", "missing token"))?;
    state.admin_sessions.authorize(token);
    state.metrics.increment("admin_otp_verify");
    Ok(Json(json!({"token": token, "email": email})))
}

async fn route_records(
    pool: &sqlx::PgPool,
    query: &RouteQuery,
    limit: i64,
) -> Result<Vec<Value>, OperationsError> {
    let since = since_seconds(query.since.as_deref())?;
    sqlx::query(
        r#"
        SELECT to_jsonb(routes) - 'id' AS record
        FROM public.inference_routes routes
        WHERE created_at >= NOW() - ($1 * INTERVAL '1 second')
          AND ($2::TEXT IS NULL OR provider_id=$2)
          AND ($3::TEXT IS NULL OR model=$3 OR public_model=$3)
          AND ($4::TEXT IS NULL OR outcome=$4)
          AND ($5::TEXT IS NULL OR final_status=$5)
        ORDER BY created_at DESC LIMIT $6
        "#,
    )
    .bind(since)
    .bind(nonempty(query.provider.as_deref()))
    .bind(nonempty(query.model.as_deref()))
    .bind(nonempty(query.outcome.as_deref()))
    .bind(nonempty(query.final_status.as_deref()))
    .bind(limit)
    .fetch_all(pool)
    .await
    .map_err(|error| OperationsError::internal("load routing telemetry", error))
    .map(json_rows)
}

async fn rejection_records(
    pool: &sqlx::PgPool,
    query: &RejectionQuery,
    limit: i64,
) -> Result<Vec<Value>, OperationsError> {
    let since = since_seconds(query.since.as_deref())?;
    sqlx::query(
        r#"
        SELECT to_jsonb(rejections) - 'id' AS record
        FROM public.request_rejections rejections
        WHERE created_at >= NOW() - ($1 * INTERVAL '1 second')
          AND ($2::TEXT IS NULL OR reason_code=$2)
          AND ($3::TEXT IS NULL OR requested_model=$3 OR resolved_model=$3)
          AND ($4::BOOL IS NULL OR could_have_served=$4)
        ORDER BY created_at DESC LIMIT $5
        "#,
    )
    .bind(since)
    .bind(nonempty(query.reason.as_deref()))
    .bind(nonempty(query.model.as_deref()))
    .bind(query.could_have_served)
    .bind(limit)
    .fetch_all(pool)
    .await
    .map_err(|error| OperationsError::internal("load rejection telemetry", error))
    .map(json_rows)
}

fn json_rows(rows: Vec<sqlx::postgres::PgRow>) -> Vec<Value> {
    rows.into_iter()
        .map(|row| row.get::<SqlJson<Value>, _>("record").0)
        .collect()
}

fn export_records(
    base: &str,
    format: Option<&str>,
    records: &[Value],
) -> Result<Response, OperationsError> {
    let ndjson = format.is_some_and(|format| format.eq_ignore_ascii_case("ndjson"));
    let (body, content_type, extension) = if ndjson {
        let mut body = Vec::new();
        for record in records {
            serde_json::to_writer(&mut body, record)
                .map_err(|error| OperationsError::internal("encode NDJSON export", error))?;
            body.push(b'\n');
        }
        (body, "application/x-ndjson", "ndjson")
    } else {
        (csv(records), "text/csv; charset=utf-8", "csv")
    };
    let mut response = Body::from(body).into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    if let Ok(value) =
        HeaderValue::from_str(&format!("attachment; filename=\"{base}.{extension}\""))
    {
        response
            .headers_mut()
            .insert(header::CONTENT_DISPOSITION, value);
    }
    Ok(response)
}

fn csv(records: &[Value]) -> Vec<u8> {
    let mut columns = records
        .iter()
        .filter_map(Value::as_object)
        .flat_map(|object| object.keys().cloned())
        .collect::<std::collections::BTreeSet<_>>();
    if columns.is_empty() {
        columns.insert("record".to_owned());
    }
    let columns = columns.into_iter().collect::<Vec<_>>();
    let mut output = String::new();
    output.push_str(
        &columns
            .iter()
            .map(|column| csv_cell(column))
            .collect::<Vec<_>>()
            .join(","),
    );
    output.push('\n');
    for record in records {
        let object = record.as_object();
        output.push_str(
            &columns
                .iter()
                .map(|column| {
                    let value = object
                        .and_then(|object| object.get(column))
                        .cloned()
                        .unwrap_or(Value::Null);
                    let text = value
                        .as_str()
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| value.to_string());
                    csv_cell(&text)
                })
                .collect::<Vec<_>>()
                .join(","),
        );
        output.push('\n');
    }
    output.into_bytes()
}

fn csv_cell(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn since_seconds(value: Option<&str>) -> Result<i64, OperationsError> {
    match value.unwrap_or("24h") {
        "" | "24h" | "1d" => Ok(24 * 60 * 60),
        "1h" => Ok(60 * 60),
        "7d" | "168h" => Ok(7 * 24 * 60 * 60),
        "30d" | "720h" => Ok(30 * 24 * 60 * 60),
        other => {
            let Some(hours) = other.strip_suffix('h') else {
                return Err(OperationsError::bad_request(
                    "since must be 1h, 24h, 7d, 30d, or positive Nh",
                ));
            };
            let hours = hours
                .parse::<i64>()
                .ok()
                .filter(|hours| (1..=24 * 365).contains(hours))
                .ok_or_else(|| {
                    OperationsError::bad_request("since must be 1h, 24h, 7d, 30d, or positive Nh")
                })?;
            Ok(hours * 60 * 60)
        }
    }
}

fn browse_limit(value: Option<i64>) -> i64 {
    value
        .filter(|limit| *limit > 0)
        .unwrap_or(DEFAULT_BROWSE_LIMIT)
        .min(MAX_EXPORT_ROWS)
}

fn export_limit(value: Option<i64>) -> i64 {
    value
        .filter(|limit| *limit > 0)
        .unwrap_or(MAX_EXPORT_ROWS)
        .min(MAX_EXPORT_ROWS)
}

fn nonempty(value: Option<&str>) -> Option<&str> {
    value.filter(|value| !value.is_empty())
}

fn normalize_admin_email<'a>(
    config: &'a super::AdminOtpConfig,
    email: &str,
) -> Result<&'a str, OperationsError> {
    let email = email.trim().to_ascii_lowercase();
    config
        .admin_emails
        .iter()
        .find(|allowed| allowed.as_ref().eq_ignore_ascii_case(&email))
        .map(AsRef::as_ref)
        .ok_or_else(|| OperationsError::forbidden("email is not an administrator"))
}

async fn bounded_response(
    response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, OperationsError> {
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(OperationsError::internal(
            "read OTP response",
            "response is too large",
        ));
    }
    let mut output = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| OperationsError::internal("read OTP response", error))?;
        if output.len().saturating_add(chunk.len()) > limit {
            return Err(OperationsError::internal(
                "read OTP response",
                "response is too large",
            ));
        }
        output.extend_from_slice(&chunk);
    }
    Ok(output)
}

async fn json_body<T: serde::de::DeserializeOwned>(
    request: Request,
    limit: usize,
) -> Result<T, OperationsError> {
    let body = to_bytes(request.into_body(), limit)
        .await
        .map_err(|_| OperationsError::payload_too_large("admin body exceeds 64KB"))?;
    let mut deserializer = serde_json::Deserializer::from_slice(&body);
    let value = T::deserialize(&mut deserializer)
        .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?;
    deserializer
        .end()
        .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?;
    Ok(value)
}

fn valid_account(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

fn ratio(used: u64, capacity: u64) -> f64 {
    if capacity == 0 {
        0.0
    } else {
        used as f64 / capacity as f64
    }
}
