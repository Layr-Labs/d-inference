use std::{
    collections::{BTreeMap, VecDeque},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Path, Query, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sqlx::Row;
use uuid::Uuid;

use super::{
    OperationsState,
    auth::{require_admin, require_public},
    error::OperationsError,
    lock,
};

const MAX_TELEMETRY_BODY: usize = 64 * 1024;
const MAX_TELEMETRY_BATCH: usize = 100;
const MAX_TELEMETRY_MESSAGE: usize = 4_096;
const MAX_TELEMETRY_STACK: usize = 32 * 1024;
const MAX_TELEMETRY_FIELDS: usize = 8 * 1024;
const MAX_LOG_REPORT: usize = 10 * 1024 * 1024;
const MAX_REPORT_LIST: i64 = 100;

const ALLOWED_FIELDS: &[&str] = &[
    "component",
    "operation",
    "duration_ms",
    "attempt",
    "endpoint",
    "status_code",
    "error_class",
    "error",
    "target",
    "model",
    "backend",
    "exit_code",
    "signal",
    "hardware_chip",
    "memory_gb",
    "macos_version",
    "handler",
    "provider_id",
    "trust_level",
    "queue_depth",
    "reason",
    "runtime_component",
    "reconnect_count",
    "last_error",
    "ws_state",
    "network_reachable",
    "coordinator_url",
    "billing_method",
    "payment_failed",
    "detect_source",
    "peak_memory_bytes",
    "report",
    "pressure",
    "available_bytes",
    "mlx_active_bytes",
    "memory_pressure",
    "in_flight",
    "steps_executed",
    "admits",
    "first_tokens_emitted",
    "consecutive_admits_without_first_token",
    "seconds_since_last_step",
    "seconds_since_last_first_token",
    "num_running",
    "wedge_suspected",
    "eval_in_flight_ms",
    "longest_eval_ms",
    "evals_completed",
    "idle_clear_in_flight_ms",
    "idle_clears_completed",
    "prefill_samples_accepted",
    "prefill_samples_dropped_floor",
    "prefill_samples_dropped_ceiling",
    "last_prefill_sample_tps",
    "observed_prefill_tps_ewma",
    "streak_seconds",
    "reservation_count",
    "reserved_bytes",
    "mlx_cache_bytes",
    "system_available_bytes",
    "reservations",
    "request_id",
    "age_seconds",
    "multimodal",
    "media_kind",
    "url",
    "user_agent",
    "route",
];

#[derive(Debug)]
pub(super) struct TelemetryBuffer {
    capacity: usize,
    records: Mutex<VecDeque<TelemetryRecord>>,
    dropped: AtomicU64,
}

impl TelemetryBuffer {
    pub(super) fn new(capacity: usize) -> Self {
        Self {
            capacity,
            records: Mutex::new(VecDeque::with_capacity(capacity)),
            dropped: AtomicU64::new(0),
        }
    }

    fn push(&self, record: TelemetryRecord) {
        let mut records = lock(&self.records);
        if records.len() == self.capacity {
            records.pop_front();
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
        records.push_back(record);
    }

    pub(super) fn summary(&self) -> Value {
        let records = lock(&self.records);
        let mut by_source = BTreeMap::<String, u64>::new();
        let mut by_severity = BTreeMap::<String, u64>::new();
        for record in records.iter() {
            *by_source.entry(record.source.clone()).or_default() += 1;
            *by_severity.entry(record.severity.clone()).or_default() += 1;
        }
        json!({
            "retained": records.len(),
            "capacity": self.capacity,
            "dropped": self.dropped.load(Ordering::Relaxed),
            "by_source": by_source,
            "by_severity": by_severity,
        })
    }

    #[cfg(test)]
    pub(super) fn records(&self) -> Vec<Value> {
        lock(&self.records)
            .iter()
            .map(|record| serde_json::to_value(record).expect("telemetry record serializes"))
            .collect()
    }
}

#[derive(Clone, Debug, Serialize)]
struct TelemetryRecord {
    id: String,
    timestamp: String,
    received_at: String,
    source: String,
    severity: String,
    kind: String,
    version: String,
    machine_id: String,
    account_id: String,
    request_id: String,
    session_id: String,
    message: String,
    fields: Value,
    stack: String,
}

#[derive(Debug, Deserialize)]
struct Batch {
    #[serde(default)]
    events: Vec<Event>,
}

#[derive(Debug, Deserialize)]
struct Event {
    #[serde(default)]
    id: String,
    #[serde(default)]
    timestamp: String,
    #[serde(default)]
    source: String,
    #[serde(default)]
    severity: String,
    #[serde(default)]
    kind: String,
    #[serde(default)]
    version: String,
    #[serde(default)]
    machine_id: String,
    #[serde(default)]
    account_id: String,
    #[serde(default)]
    request_id: String,
    #[serde(default)]
    session_id: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    fields: Map<String, Value>,
    #[serde(default)]
    stack: String,
}

pub(super) async fn ingest(
    State(state): State<std::sync::Arc<OperationsState>>,
    request: Request,
) -> Result<(StatusCode, Json<Value>), OperationsError> {
    let body = to_bytes(request.into_body(), MAX_TELEMETRY_BODY)
        .await
        .map_err(|_| OperationsError::payload_too_large("telemetry body exceeds 64KB"))?;
    let batch: Batch = serde_json::from_slice(&body)
        .map_err(|_| OperationsError::bad_request("malformed JSON batch"))?;
    if batch.events.len() > MAX_TELEMETRY_BATCH {
        return Err(OperationsError::payload_too_large(
            "maximum 100 events per batch",
        ));
    }
    if batch.events.is_empty() {
        return Ok((StatusCode::OK, Json(json!({"accepted": 0, "rejected": 0}))));
    }
    let received_at = database_now(state.pool()).await?;
    let mut accepted = 0_usize;
    let mut rejected = 0_usize;
    for event in batch.events {
        let Some(record) = sanitize(event, &received_at) else {
            rejected += 1;
            continue;
        };
        state.telemetry.push(record);
        accepted += 1;
    }
    state.metrics.increment("telemetry_batches");
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({"accepted": accepted, "rejected": rejected})),
    ))
}

#[derive(Debug, Deserialize)]
pub(super) struct LogUploadQuery {
    serial: Option<String>,
}

pub(super) async fn upload_log_report(
    State(state): State<std::sync::Arc<OperationsState>>,
    Query(query): Query<LogUploadQuery>,
    request: Request,
) -> Result<(StatusCode, Json<Value>), OperationsError> {
    require_public(&state.auth, request.headers())?;
    let serial = query.serial.unwrap_or_default();
    if !valid_serial(&serial) {
        return Err(OperationsError::bad_request(
            "serial query parameter is required and must be 8-64 uppercase letters/digits",
        ));
    }
    let account_id = request
        .headers()
        .get("x-darkbloom-account-id")
        .and_then(|value| value.to_str().ok())
        .filter(|value| valid_identifier(value))
        .unwrap_or_default()
        .to_owned();
    let provider_id = request
        .headers()
        .get("x-darkbloom-provider-id")
        .and_then(|value| value.to_str().ok())
        .filter(|value| valid_identifier(value))
        .unwrap_or_default()
        .to_owned();
    let body = to_bytes(request.into_body(), MAX_LOG_REPORT)
        .await
        .map_err(|_| OperationsError::payload_too_large("log data exceeds 10MB limit"))?;
    if body.is_empty() {
        return Err(OperationsError::bad_request("empty log data"));
    }
    let size = i64::try_from(body.len())
        .map_err(|_| OperationsError::payload_too_large("log report is too large"))?;
    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin log report upload", error))?;
    let id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO public.provider_log_reports
            (serial_number, provider_id, account_id, log_data, log_size_bytes)
        VALUES ($1,$2,$3,$4,$5) RETURNING id
        "#,
    )
    .bind(&serial)
    .bind(&provider_id)
    .bind(&account_id)
    .bind(body.as_ref())
    .bind(size)
    .fetch_one(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("store log report", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit log report", error))?;
    state.mark_mutation();
    state.metrics.increment("log_reports_uploaded");
    Ok((
        StatusCode::CREATED,
        Json(json!({"status": "stored", "id": id, "serial": serial, "size_bytes": size})),
    ))
}

#[derive(Debug, Deserialize)]
pub(super) struct LogListQuery {
    serial: Option<String>,
    limit: Option<i64>,
}

pub(super) async fn list_log_reports(
    State(state): State<std::sync::Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<LogListQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &headers)?;
    let serial = query.serial.unwrap_or_default();
    if !valid_serial(&serial) {
        return Err(OperationsError::bad_request(
            "serial query parameter is required",
        ));
    }
    let limit = query
        .limit
        .filter(|limit| (1..=MAX_REPORT_LIST).contains(limit))
        .unwrap_or(10);
    let rows = sqlx::query(
        r#"
        SELECT id, serial_number, provider_id, account_id, log_size_bytes,
               to_char(created_at AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at
        FROM public.provider_log_reports
        WHERE serial_number=$1
        ORDER BY created_at DESC LIMIT $2
        "#,
    )
    .bind(&serial)
    .bind(limit)
    .fetch_all(state.pool())
    .await
    .map_err(|error| OperationsError::internal("list log reports", error))?
    .into_iter()
    .map(|row| {
        json!({
            "id": row.get::<i64, _>("id"),
            "serial_number": row.get::<String, _>("serial_number"),
            "provider_id": row.get::<String, _>("provider_id"),
            "account_id": row.get::<String, _>("account_id"),
            "log_size_bytes": row.get::<i64, _>("log_size_bytes"),
            "created_at": row.get::<String, _>("created_at"),
        })
    })
    .collect::<Vec<_>>();
    Ok(Json(
        json!({"serial": serial, "count": rows.len(), "reports": rows}),
    ))
}

pub(super) async fn get_log_report(
    State(state): State<std::sync::Arc<OperationsState>>,
    headers: HeaderMap,
    Path(id): Path<i64>,
) -> Result<Response, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &headers)?;
    if id <= 0 {
        return Err(OperationsError::bad_request("invalid report id"));
    }
    let row =
        sqlx::query("SELECT log_data, log_size_bytes FROM public.provider_log_reports WHERE id=$1")
            .bind(id)
            .fetch_optional(state.pool())
            .await
            .map_err(|error| OperationsError::internal("load log report", error))?
            .ok_or_else(|| OperationsError::not_found("log report not found"))?;
    let data = row.get::<Vec<u8>, _>("log_data");
    let mut response = Body::from(data).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    if let Ok(length) = HeaderValue::from_str(&row.get::<i64, _>("log_size_bytes").to_string()) {
        response
            .headers_mut()
            .insert(header::CONTENT_LENGTH, length);
    }
    Ok(response)
}

fn sanitize(event: Event, received_at: &str) -> Option<TelemetryRecord> {
    if event.message.is_empty() {
        return None;
    }
    let source = match event.source.as_str() {
        "provider" | "console" | "app" | "coordinator" | "custom" => event.source,
        _ => "custom".to_owned(),
    };
    let severity = match event.severity.as_str() {
        "debug" | "info" | "warning" | "error" | "fatal" => event.severity,
        _ => "info".to_owned(),
    };
    let kind = match event.kind.as_str() {
        "lifecycle" | "network" | "inference" | "billing" | "security" | "custom" => event.kind,
        _ => "custom".to_owned(),
    };
    let mut fields = Map::new();
    for (key, value) in event.fields {
        if ALLOWED_FIELDS.contains(&key.as_str()) {
            fields.insert(key, value);
        }
    }
    if serde_json::to_vec(&fields).map_or(true, |value| value.len() > MAX_TELEMETRY_FIELDS) {
        fields.clear();
    }
    Some(TelemetryRecord {
        id: Uuid::parse_str(&event.id)
            .unwrap_or_else(|_| Uuid::new_v4())
            .to_string(),
        timestamp: truncate(
            if event.timestamp.is_empty() {
                received_at
            } else {
                &event.timestamp
            },
            64,
        ),
        received_at: received_at.to_owned(),
        source,
        severity,
        kind,
        version: truncate(&event.version, 64),
        machine_id: truncate(&event.machine_id, 128),
        account_id: truncate(&event.account_id, 128),
        request_id: truncate(&event.request_id, 128),
        session_id: truncate(&event.session_id, 64),
        message: truncate(&event.message, MAX_TELEMETRY_MESSAGE),
        fields: Value::Object(fields),
        stack: truncate(&event.stack, MAX_TELEMETRY_STACK),
    })
}

fn truncate(value: &str, maximum: usize) -> String {
    if value.len() <= maximum {
        return value.to_owned();
    }
    let mut boundary = maximum;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value[..boundary].to_owned()
}

fn valid_serial(serial: &str) -> bool {
    (8..=64).contains(&serial.len())
        && serial
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'-')
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && !value.chars().any(char::is_control)
        && value.trim() == value
}

async fn database_now(pool: &sqlx::PgPool) -> Result<String, OperationsError> {
    sqlx::query_scalar(
        r#"SELECT to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')"#,
    )
    .fetch_one(pool)
    .await
    .map_err(|error| OperationsError::internal("read telemetry time", error))
}
