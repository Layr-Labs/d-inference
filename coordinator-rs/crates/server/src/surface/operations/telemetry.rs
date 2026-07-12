use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    net::{IpAddr, SocketAddr},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Instant,
};

use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{ConnectInfo, Path, Query, Request, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};
use sqlx::Row;
use uuid::Uuid;

use crate::surface::identity::{AuthContext, AuthPrincipal};

use super::{
    OperationsState,
    auth::{require_admin, require_public},
    error::OperationsError,
    lock,
    telemetry_durable::DurableTelemetryEvent,
};

const MAX_TELEMETRY_BODY: usize = 64 * 1024;
const MAX_TELEMETRY_BATCH: usize = 100;
const MAX_TELEMETRY_MESSAGE: usize = 4_096;
const MAX_TELEMETRY_STACK: usize = 32 * 1024;
const MAX_TELEMETRY_FIELDS: usize = 8 * 1024;
const MAX_LOG_REPORT: usize = 10 * 1024 * 1024;
const MAX_REPORT_LIST: i64 = 100;
const MAX_RATE_IDENTITIES: usize = 50_000;
const AUTH_RATE_CAPACITY: f64 = 200.0;
const AUTH_RATE_PER_SECOND: f64 = 100.0 / 60.0;
const ANON_RATE_CAPACITY: f64 = 30.0;
const ANON_RATE_PER_SECOND: f64 = 10.0 / 60.0;

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
    rates: Mutex<HashMap<String, RateBucket>>,
    dropped: AtomicU64,
}

impl TelemetryBuffer {
    pub(super) fn new(capacity: usize) -> Self {
        Self {
            capacity,
            records: Mutex::new(VecDeque::with_capacity(capacity)),
            rates: Mutex::new(HashMap::new()),
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

    fn admit(&self, identity: &TelemetryIdentity, cost: usize) -> bool {
        let now = Instant::now();
        let (capacity, rate) = if identity.authenticated {
            (AUTH_RATE_CAPACITY, AUTH_RATE_PER_SECOND)
        } else {
            (ANON_RATE_CAPACITY, ANON_RATE_PER_SECOND)
        };
        let mut buckets = lock(&self.rates);
        if !buckets.contains_key(&identity.rate_key) && buckets.len() >= MAX_RATE_IDENTITIES {
            buckets.retain(|_, bucket| {
                now.saturating_duration_since(bucket.last_refill).as_secs() < 3600
            });
            if buckets.len() >= MAX_RATE_IDENTITIES {
                return false;
            }
        }
        let bucket = buckets
            .entry(identity.rate_key.clone())
            .or_insert(RateBucket {
                tokens: capacity,
                capacity,
                refill_per_second: rate,
                last_refill: now,
            });
        let elapsed = now
            .saturating_duration_since(bucket.last_refill)
            .as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * bucket.refill_per_second).min(bucket.capacity);
        bucket.last_refill = now;
        let cost = cost as f64;
        if bucket.tokens < cost {
            return false;
        }
        bucket.tokens -= cost;
        true
    }

    #[cfg(test)]
    pub(super) fn records(&self) -> Vec<Value> {
        lock(&self.records)
            .iter()
            .map(|record| serde_json::to_value(record).expect("telemetry record serializes"))
            .collect()
    }
}

#[derive(Clone, Copy, Debug)]
struct RateBucket {
    tokens: f64,
    capacity: f64,
    refill_per_second: f64,
    last_refill: Instant,
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
    let identity = TelemetryIdentity::from_request(&request);
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
    if !state.telemetry.admit(&identity, batch.events.len()) {
        return Err(OperationsError::rate_limited(
            "telemetry rate limit exceeded",
        ));
    }
    let received_at = database_now(state.pool()).await?;
    let mut rejected = 0_usize;
    let mut records = Vec::with_capacity(batch.events.len());
    let mut durable = Vec::with_capacity(batch.events.len());
    for event in batch.events {
        let Some(record) = sanitize(event, &received_at, &identity) else {
            rejected += 1;
            continue;
        };
        let payload = serde_json::to_value(&record)
            .map_err(|error| OperationsError::internal("encode telemetry event", error))?;
        let payload_bytes = serde_json::to_vec(&payload)
            .ok()
            .and_then(|payload| i32::try_from(payload.len()).ok())
            .ok_or_else(|| OperationsError::payload_too_large("telemetry event is too large"))?;
        durable.push(DurableTelemetryEvent {
            id: Uuid::parse_str(&record.id).expect("sanitizer emits UUID ids"),
            event_name: record.kind.clone(),
            identity_hash: identity.identity_hash.clone(),
            authenticated: identity.authenticated,
            payload,
            payload_bytes,
        });
        records.push(record);
    }
    let accepted = usize::try_from(
        state
            .telemetry_service
            .persist(&durable)
            .await
            .map_err(|error| OperationsError::internal("persist telemetry batch", error))?,
    )
    .unwrap_or(usize::MAX);
    for record in records {
        state.telemetry.push(record);
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
    let authenticated = request.extensions().get::<AuthContext>();
    let account_id = authenticated
        .map(|auth| truncate(&auth.account_id, 128))
        .unwrap_or_default();
    let provider_id = authenticated
        .filter(|auth| matches!(auth.principal, AuthPrincipal::ProviderToken { .. }))
        .map(|auth| {
            format!(
                "tok:{}",
                &opaque_hash(auth.credential_hash.as_bytes())[..16]
            )
        })
        .unwrap_or_default();
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
    Query(query): Query<LogListQuery>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &request)?;
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
    Path(id): Path<i64>,
    request: Request,
) -> Result<Response, OperationsError> {
    require_admin(&state.auth, &state.admin_sessions, &request)?;
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

#[derive(Clone, Debug)]
struct TelemetryIdentity {
    rate_key: String,
    identity_hash: String,
    authenticated: bool,
    account_id: String,
    machine_id: String,
    provider: bool,
}

impl TelemetryIdentity {
    fn from_request(request: &Request) -> Self {
        if let Some(auth) = request.extensions().get::<AuthContext>() {
            let provider = matches!(auth.principal, AuthPrincipal::ProviderToken { .. });
            let identity_hash = opaque_hash(auth.credential_hash.as_bytes());
            return Self {
                rate_key: format!("auth:{identity_hash}"),
                identity_hash: identity_hash.clone(),
                authenticated: true,
                account_id: truncate(&auth.account_id, 128),
                machine_id: if provider {
                    format!("tok:{}", &identity_hash[..16])
                } else {
                    String::new()
                },
                provider,
            };
        }
        let address = request
            .extensions()
            .get::<ConnectInfo<SocketAddr>>()
            .map(|ConnectInfo(address)| address.ip())
            .unwrap_or(IpAddr::from([0, 0, 0, 0]));
        let identity_hash = opaque_hash(address.to_string().as_bytes());
        Self {
            rate_key: format!("anon:{identity_hash}"),
            identity_hash,
            authenticated: false,
            account_id: String::new(),
            machine_id: String::new(),
            provider: false,
        }
    }
}

fn sanitize(
    event: Event,
    received_at: &str,
    identity: &TelemetryIdentity,
) -> Option<TelemetryRecord> {
    if event.message.is_empty() {
        return None;
    }
    let source = if identity.provider {
        "provider".to_owned()
    } else {
        match event.source.as_str() {
            "provider" | "console" | "app" | "coordinator" | "custom" => event.source,
            _ => "custom".to_owned(),
        }
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
        machine_id: identity.machine_id.clone(),
        account_id: identity.account_id.clone(),
        request_id: truncate(&event.request_id, 128),
        session_id: truncate(&event.session_id, 64),
        message: truncate(&event.message, MAX_TELEMETRY_MESSAGE),
        fields: Value::Object(fields),
        stack: truncate(&event.stack, MAX_TELEMETRY_STACK),
    })
}

fn opaque_hash(value: &[u8]) -> String {
    let digest = Sha256::digest(value);
    let mut encoded = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(encoded, "{byte:02x}");
    }
    encoded
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

async fn database_now(pool: &sqlx::PgPool) -> Result<String, OperationsError> {
    sqlx::query_scalar(
        r#"SELECT to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')"#,
    )
    .fetch_one(pool)
    .await
    .map_err(|error| OperationsError::internal("read telemetry time", error))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::{
        body::Body,
        http::{Request, header},
    };

    use crate::surface::identity::{AuthContext, AuthPrincipal};

    use super::{TelemetryIdentity, opaque_hash};

    #[test]
    fn telemetry_identity_uses_authenticated_context_and_ignores_client_identity_headers() {
        let credential_hash = Arc::<str>::from("provider-credential-hash");
        let request = Request::builder()
            .header(header::AUTHORIZATION, "Bearer client-controlled")
            .header("x-machine-id", "spoofed-machine")
            .header("x-account-id", "spoofed-account")
            .extension(AuthContext {
                principal: AuthPrincipal::ProviderToken {
                    label: Arc::from("provider"),
                },
                account_id: Arc::from("provider-account"),
                credential_hash: credential_hash.clone(),
                email: Arc::from(""),
                role: Arc::from(""),
                stripe_account_status: Arc::from(""),
                api_key: None,
            })
            .body(Body::empty())
            .expect("authenticated telemetry request");

        let identity = TelemetryIdentity::from_request(&request);
        let expected_hash = opaque_hash(credential_hash.as_bytes());
        assert!(identity.authenticated);
        assert!(identity.provider);
        assert_eq!(identity.account_id, "provider-account");
        assert_eq!(identity.identity_hash, expected_hash);
        assert_eq!(identity.machine_id, format!("tok:{}", &expected_hash[..16]));
        assert_ne!(identity.machine_id, "spoofed-machine");
        assert_ne!(identity.account_id, "spoofed-account");
    }
}
