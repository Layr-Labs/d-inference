use std::{
    fmt,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use reqwest::{Client, Url};
use serde_json::{Value, json};
use sqlx::{FromRow, Postgres, QueryBuilder, types::Json};
use uuid::Uuid;

use crate::database::Database;

const MAX_PERSISTENT_CAPACITY: u32 = 1_000_000;
const MAX_DELIVERY_BATCH: u32 = 100;
const MAX_DELIVERY_ATTEMPTS: u32 = 100;
const MAX_ERROR_BYTES: usize = 512;

#[derive(Clone)]
pub struct DatadogTelemetrySettings {
    pub api_key: Arc<str>,
    pub logs_url: Url,
    pub environment: Arc<str>,
    pub service: Arc<str>,
}

impl fmt::Debug for DatadogTelemetrySettings {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DatadogTelemetrySettings")
            .field("api_key", &"<redacted>")
            .field("logs_url", &self.logs_url)
            .field("environment", &self.environment)
            .field("service", &self.service)
            .finish()
    }
}

#[derive(Clone, Debug)]
pub struct TelemetrySettings {
    pub persistent_capacity: u32,
    pub delivery_batch_size: u32,
    pub maximum_delivery_attempts: u32,
    pub lease_duration: Duration,
    pub retry_after: Duration,
    pub request_timeout: Duration,
    pub datadog: Option<DatadogTelemetrySettings>,
}

impl Default for TelemetrySettings {
    fn default() -> Self {
        Self {
            persistent_capacity: 65_536,
            delivery_batch_size: 100,
            maximum_delivery_attempts: 10,
            lease_duration: Duration::from_secs(30),
            retry_after: Duration::from_secs(2),
            request_timeout: Duration::from_secs(10),
            datadog: None,
        }
    }
}

impl TelemetrySettings {
    pub fn validate(&self) -> Result<(), TelemetryServiceError> {
        if self.persistent_capacity == 0
            || self.persistent_capacity > MAX_PERSISTENT_CAPACITY
            || self.delivery_batch_size == 0
            || self.delivery_batch_size > MAX_DELIVERY_BATCH
            || self.maximum_delivery_attempts == 0
            || self.maximum_delivery_attempts > MAX_DELIVERY_ATTEMPTS
            || self.lease_duration.is_zero()
            || self.lease_duration > Duration::from_secs(300)
            || self.retry_after.is_zero()
            || self.retry_after > Duration::from_secs(300)
            || self.request_timeout.is_zero()
            || self.request_timeout > Duration::from_secs(30)
        {
            return Err(TelemetryServiceError::InvalidConfiguration);
        }
        if let Some(datadog) = &self.datadog {
            let local_http = datadog.logs_url.scheme() == "http"
                && datadog
                    .logs_url
                    .host_str()
                    .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1"));
            if datadog.api_key.is_empty()
                || datadog.api_key.len() > 16 * 1024
                || datadog.environment.is_empty()
                || datadog.service.is_empty()
                || datadog.logs_url.host_str().is_none()
                || !datadog.logs_url.username().is_empty()
                || datadog.logs_url.password().is_some()
                || datadog.logs_url.fragment().is_some()
                || (datadog.logs_url.scheme() != "https" && !local_http)
            {
                return Err(TelemetryServiceError::InvalidConfiguration);
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub(crate) struct DurableTelemetryEvent {
    pub id: Uuid,
    pub event_name: String,
    pub identity_hash: String,
    pub authenticated: bool,
    pub payload: Value,
    pub payload_bytes: i32,
}

#[derive(Clone)]
pub struct TelemetryService {
    database: Database,
    settings: TelemetrySettings,
    client: Client,
    metrics: Arc<TelemetryDeliveryMetrics>,
}

impl fmt::Debug for TelemetryService {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TelemetryService")
            .field("settings", &self.settings)
            .finish_non_exhaustive()
    }
}

impl TelemetryService {
    pub fn new(
        database: Database,
        settings: TelemetrySettings,
    ) -> Result<Self, TelemetryServiceError> {
        settings.validate()?;
        let client = Client::builder()
            .timeout(settings.request_timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            database,
            settings,
            client,
            metrics: Arc::new(TelemetryDeliveryMetrics::default()),
        })
    }

    pub(crate) async fn persist(
        &self,
        events: &[DurableTelemetryEvent],
    ) -> Result<u64, TelemetryServiceError> {
        if events.is_empty() {
            return Ok(0);
        }
        if events.len() > MAX_DELIVERY_BATCH as usize {
            return Err(TelemetryServiceError::InvalidBatch);
        }
        let mut transaction = self.database.begin_owned().await?;
        sqlx::query(
            "SELECT pg_advisory_xact_lock(hashtextextended('darkbloom-telemetry-capacity', 0))",
        )
        .execute(transaction.connection())
        .await?;
        let owner_epoch = transaction.context().epoch();
        let mut query = QueryBuilder::<Postgres>::new(
            "INSERT INTO rust_coord.telemetry_events \
             (telemetry_event_id,event_name,identity_hash,authenticated,fields,payload_bytes,owner_epoch) ",
        );
        query.push_values(events, |mut row, event| {
            row.push_bind(event.id)
                .push_bind(&event.event_name)
                .push_bind(&event.identity_hash)
                .push_bind(event.authenticated)
                .push_bind(Json(&event.payload))
                .push_bind(event.payload_bytes)
                .push_bind(owner_epoch);
        });
        query.push(" ON CONFLICT (telemetry_event_id) DO NOTHING");
        let inserted = query
            .build()
            .execute(transaction.connection())
            .await?
            .rows_affected();

        let capacity = i64::from(self.settings.persistent_capacity);
        let dropped: i64 = sqlx::query_scalar(
            r#"
            WITH overflow AS MATERIALIZED (
                SELECT telemetry_event_id
                FROM rust_coord.telemetry_events
                ORDER BY created_at DESC, telemetry_event_id DESC
                OFFSET $1
            ), marked AS (
                UPDATE rust_coord.telemetry_events AS events
                SET
                    status = 'dropped',
                    worker_owner = NULL,
                    lease_until = NULL,
                    last_error = 'persistent telemetry capacity exceeded',
                    version = version + 1,
                    updated_at = NOW()
                FROM overflow
                WHERE events.telemetry_event_id = overflow.telemetry_event_id
                  AND events.status IN ('pending', 'processing')
                RETURNING events.telemetry_event_id
            )
            SELECT COUNT(*)::BIGINT FROM marked
            "#,
        )
        .bind(capacity)
        .fetch_one(transaction.connection())
        .await?;
        sqlx::query(
            r#"
            DELETE FROM rust_coord.telemetry_events
            WHERE telemetry_event_id IN (
                SELECT telemetry_event_id
                FROM rust_coord.telemetry_events
                ORDER BY created_at DESC, telemetry_event_id DESC
                OFFSET $1
            )
            "#,
        )
        .bind(capacity)
        .execute(transaction.connection())
        .await?;
        transaction.commit().await?;
        self.metrics.accepted.fetch_add(inserted, Ordering::Relaxed);
        self.metrics.dropped.fetch_add(
            u64::try_from(dropped).unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
        Ok(inserted)
    }

    pub async fn process_once(&self, worker_id: Uuid) -> Result<u64, TelemetryServiceError> {
        if worker_id.is_nil() {
            return Err(TelemetryServiceError::InvalidWorker);
        }
        let leases = self.claim(worker_id).await?;
        if leases.is_empty() {
            return Ok(0);
        }
        let ids = leases
            .iter()
            .map(|lease| lease.telemetry_event_id)
            .collect::<Vec<_>>();
        let Some(datadog) = &self.settings.datadog else {
            self.complete(worker_id, &ids, DeliveryDisposition::Delivered, "")
                .await?;
            self.metrics
                .delivered
                .fetch_add(ids.len() as u64, Ordering::Relaxed);
            return Ok(ids.len() as u64);
        };

        let body = leases
            .iter()
            .map(|lease| datadog_log(&lease.payload, datadog))
            .collect::<Vec<_>>();
        let response = self
            .client
            .post(datadog.logs_url.clone())
            .header("DD-API-KEY", datadog.api_key.as_ref())
            .json(&body)
            .send()
            .await;
        match response {
            Ok(response) if response.status().is_success() => {
                self.complete(worker_id, &ids, DeliveryDisposition::Delivered, "")
                    .await?;
                self.metrics
                    .delivered
                    .fetch_add(ids.len() as u64, Ordering::Relaxed);
            }
            Ok(response) if response.status().is_client_error() => {
                let reason = format!("Datadog rejected telemetry with {}", response.status());
                self.complete(worker_id, &ids, DeliveryDisposition::Dropped, &reason)
                    .await?;
                self.metrics
                    .dropped
                    .fetch_add(ids.len() as u64, Ordering::Relaxed);
                self.metrics.sink_failures.fetch_add(1, Ordering::Relaxed);
            }
            Ok(response) => {
                let reason = format!("Datadog telemetry sink returned {}", response.status());
                self.retry_or_drop(worker_id, &leases, &reason).await?;
            }
            Err(error) => {
                let reason = format!("Datadog telemetry transport failed: {error}");
                self.retry_or_drop(worker_id, &leases, &reason).await?;
            }
        }
        Ok(ids.len() as u64)
    }

    #[must_use]
    pub fn metrics(&self) -> TelemetryDeliverySnapshot {
        self.metrics.snapshot()
    }

    async fn claim(&self, worker_id: Uuid) -> Result<Vec<TelemetryLease>, TelemetryServiceError> {
        let mut transaction = self.database.begin_owned().await?;
        let owner_id = transaction.context().owner_id().to_owned();
        let owner_epoch = transaction.context().epoch();
        let lease_millis = i64::try_from(self.settings.lease_duration.as_millis())
            .map_err(|_| TelemetryServiceError::InvalidConfiguration)?;
        let rows = sqlx::query_as::<_, TelemetryLease>(
            r#"
            WITH authority AS MATERIALIZED (
                SELECT 1
                FROM public.coordinator_ownership
                WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
            ), candidates AS MATERIALIZED (
                SELECT telemetry_event_id
                FROM rust_coord.telemetry_events
                WHERE status IN ('pending', 'processing')
                  AND next_attempt_at <= NOW()
                  AND (worker_owner IS NULL OR lease_until <= NOW())
                ORDER BY next_attempt_at, created_at, telemetry_event_id
                FOR UPDATE SKIP LOCKED
                LIMIT $4
            )
            UPDATE rust_coord.telemetry_events AS events
            SET
                status = 'processing',
                attempts = events.attempts + 1,
                worker_owner = $3,
                lease_until = NOW() + ($5::BIGINT * INTERVAL '1 millisecond'),
                owner_epoch = $2,
                version = events.version + 1,
                updated_at = NOW()
            FROM candidates, authority
            WHERE events.telemetry_event_id = candidates.telemetry_event_id
            RETURNING
                events.telemetry_event_id,
                events.fields AS payload,
                events.attempts
            "#,
        )
        .bind(owner_id)
        .bind(owner_epoch)
        .bind(worker_id)
        .bind(i64::from(self.settings.delivery_batch_size))
        .bind(lease_millis)
        .fetch_all(transaction.connection())
        .await?;
        transaction.commit().await?;
        Ok(rows)
    }

    async fn retry_or_drop(
        &self,
        worker_id: Uuid,
        leases: &[TelemetryLease],
        reason: &str,
    ) -> Result<(), TelemetryServiceError> {
        self.metrics.sink_failures.fetch_add(1, Ordering::Relaxed);
        let mut retry = Vec::new();
        let mut dropped = Vec::new();
        for lease in leases {
            if u32::try_from(lease.attempts).unwrap_or(u32::MAX)
                >= self.settings.maximum_delivery_attempts
            {
                dropped.push(lease.telemetry_event_id);
            } else {
                retry.push(lease.telemetry_event_id);
            }
        }
        if !retry.is_empty() {
            self.complete(worker_id, &retry, DeliveryDisposition::Retry, reason)
                .await?;
            self.metrics
                .retried
                .fetch_add(retry.len() as u64, Ordering::Relaxed);
        }
        if !dropped.is_empty() {
            self.complete(worker_id, &dropped, DeliveryDisposition::Dropped, reason)
                .await?;
            self.metrics
                .dropped
                .fetch_add(dropped.len() as u64, Ordering::Relaxed);
        }
        Ok(())
    }

    async fn complete(
        &self,
        worker_id: Uuid,
        ids: &[Uuid],
        disposition: DeliveryDisposition,
        reason: &str,
    ) -> Result<(), TelemetryServiceError> {
        if ids.is_empty() {
            return Ok(());
        }
        let mut transaction = self.database.begin_owned().await?;
        let owner_id = transaction.context().owner_id().to_owned();
        let owner_epoch = transaction.context().epoch();
        let retry_millis = i64::try_from(self.settings.retry_after.as_millis())
            .map_err(|_| TelemetryServiceError::InvalidConfiguration)?;
        let reason = truncate(reason, MAX_ERROR_BYTES);
        let updated = sqlx::query(
            r#"
            WITH authority AS MATERIALIZED (
                SELECT 1
                FROM public.coordinator_ownership
                WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
            )
            UPDATE rust_coord.telemetry_events AS events
            SET
                status = $5,
                worker_owner = NULL,
                lease_until = NULL,
                next_attempt_at = CASE
                    WHEN $5 = 'pending'
                    THEN NOW() + ($6::BIGINT * INTERVAL '1 millisecond')
                    ELSE events.next_attempt_at
                END,
                last_error = $7,
                version = events.version + 1,
                updated_at = NOW(),
                delivered_at = CASE WHEN $5 = 'delivered' THEN NOW() ELSE NULL END
            FROM authority
            WHERE events.telemetry_event_id = ANY($3)
              AND events.status = 'processing'
              AND events.worker_owner = $4
              AND events.lease_until > NOW()
            "#,
        )
        .bind(owner_id)
        .bind(owner_epoch)
        .bind(ids)
        .bind(worker_id)
        .bind(disposition.status())
        .bind(retry_millis)
        .bind(reason)
        .execute(transaction.connection())
        .await?;
        if updated.rows_affected() != ids.len() as u64 {
            return Err(TelemetryServiceError::StaleLease);
        }
        transaction.commit().await?;
        Ok(())
    }
}

#[derive(Clone, Debug, FromRow)]
struct TelemetryLease {
    telemetry_event_id: Uuid,
    payload: Value,
    attempts: i32,
}

#[derive(Clone, Copy, Debug)]
enum DeliveryDisposition {
    Delivered,
    Retry,
    Dropped,
}

impl DeliveryDisposition {
    const fn status(self) -> &'static str {
        match self {
            Self::Delivered => "delivered",
            Self::Retry => "pending",
            Self::Dropped => "dropped",
        }
    }
}

#[derive(Debug, Default)]
struct TelemetryDeliveryMetrics {
    accepted: AtomicU64,
    delivered: AtomicU64,
    retried: AtomicU64,
    dropped: AtomicU64,
    sink_failures: AtomicU64,
}

impl TelemetryDeliveryMetrics {
    fn snapshot(&self) -> TelemetryDeliverySnapshot {
        TelemetryDeliverySnapshot {
            accepted: self.accepted.load(Ordering::Relaxed),
            delivered: self.delivered.load(Ordering::Relaxed),
            retried: self.retried.load(Ordering::Relaxed),
            dropped: self.dropped.load(Ordering::Relaxed),
            sink_failures: self.sink_failures.load(Ordering::Relaxed),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub struct TelemetryDeliverySnapshot {
    pub accepted: u64,
    pub delivered: u64,
    pub retried: u64,
    pub dropped: u64,
    pub sink_failures: u64,
}

fn datadog_log(payload: &Value, settings: &DatadogTelemetrySettings) -> Value {
    let source = payload
        .get("source")
        .and_then(Value::as_str)
        .unwrap_or("custom");
    let severity = payload
        .get("severity")
        .and_then(Value::as_str)
        .unwrap_or("info");
    let kind = payload
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("custom");
    let machine_id = payload
        .get("machine_id")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let message = payload
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("telemetry event");
    json!({
        "ddsource": source,
        "ddtags": format!(
            "env:{},kind:{kind},severity:{severity}",
            settings.environment
        ),
        "hostname": machine_id,
        "service": settings.service,
        "status": datadog_status(severity),
        "message": message,
        "attributes": payload,
    })
}

fn datadog_status(severity: &str) -> &'static str {
    match severity {
        "debug" => "debug",
        "warning" => "warning",
        "error" => "error",
        "fatal" => "critical",
        _ => "info",
    }
}

fn truncate(value: &str, maximum: usize) -> &str {
    if value.len() <= maximum {
        return value;
    }
    let mut boundary = maximum;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    &value[..boundary]
}

#[derive(Debug, thiserror::Error)]
pub enum TelemetryServiceError {
    #[error("invalid durable telemetry configuration")]
    InvalidConfiguration,
    #[error("invalid durable telemetry batch")]
    InvalidBatch,
    #[error("invalid durable telemetry worker identity")]
    InvalidWorker,
    #[error("durable telemetry lease is stale")]
    StaleLease,
    #[error(transparent)]
    Database(#[from] crate::database::DatabaseError),
    #[error(transparent)]
    Sql(#[from] sqlx::Error),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
}
