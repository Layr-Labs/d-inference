use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
};
use std::time::Duration;

use axum::{
    Json, Router, extract::State, http::StatusCode, middleware, middleware::Next,
    response::IntoResponse, routing::get,
};
use opentelemetry::{global, propagation::Extractor};
use serde::Serialize;
use tracing::Instrument as _;
use tracing_opentelemetry::OpenTelemetrySpanExt as _;

use crate::{
    database::Database,
    ownership::OwnershipStatus,
    pilot::PilotHandle,
    surface::FullSurfaceState,
    telemetry::datadog::{self, Metric, Tag, TagKey},
};

#[derive(Clone)]
pub struct AppState {
    database: Database,
    ownership: Option<OwnershipStatus>,
    pilot: Option<PilotHandle>,
    full_surface: Option<FullSurfaceState>,
    providers: Arc<AtomicUsize>,
    draining: Arc<AtomicBool>,
    inflight: Arc<AtomicU64>,
}

impl AppState {
    pub fn new(database: Database) -> Self {
        Self {
            database,
            ownership: None,
            pilot: None,
            full_surface: None,
            providers: Arc::new(AtomicUsize::new(0)),
            draining: Arc::new(AtomicBool::new(false)),
            inflight: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn with_ownership(mut self, ownership: OwnershipStatus) -> Self {
        self.ownership = Some(ownership);
        self
    }

    pub fn with_pilot(mut self, pilot: PilotHandle) -> Self {
        self.pilot = Some(pilot);
        self
    }

    pub fn with_full_surface(mut self, full_surface: FullSurfaceState) -> Self {
        self.full_surface = Some(full_surface);
        self
    }

    #[must_use]
    pub fn pilot(&self) -> Option<&PilotHandle> {
        self.pilot.as_ref()
    }

    pub fn set_draining(&self, draining: bool) {
        self.draining.store(draining, Ordering::Release);
    }

    pub fn set_provider_count(&self, providers: usize) {
        self.providers.store(providers, Ordering::Release);
    }

    pub fn set_inflight(&self, inflight: u64) {
        self.inflight.store(inflight, Ordering::Release);
    }
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
    binary: &'static str,
    service: String,
    environment: String,
    listener_identity: String,
    coordinator_ownership_id: String,
    coordinator_app_id: String,
    environment_id: String,
    #[serde(skip_serializing_if = "is_false")]
    draining: bool,
    providers: usize,
    version: &'static str,
    build_commit: &'static str,
    build_date: &'static str,
    image_digest: String,
    build: BuildMetadata,
    schema: HealthSchema,
    ownership_healthy: bool,
}

#[derive(Debug, Serialize)]
struct BuildMetadata {
    version: &'static str,
    commit: &'static str,
    date: &'static str,
    rust_package_version: &'static str,
    image_digest: String,
}

#[derive(Debug, Serialize)]
struct HealthSchema {
    public_version: i64,
    rust_version: i64,
    migration_checksum_valid: bool,
}

#[derive(Debug, Serialize)]
struct ReadinessResponse {
    draining: bool,
    inflight: u64,
    ready: bool,
}

pub fn router(state: AppState) -> Router {
    let full_surface_enabled = state.full_surface.is_some();
    let domain_routes = state.full_surface.as_ref().map_or_else(
        || crate::http::routes(state.pilot.clone()),
        |full_surface| crate::surface::router(full_surface.clone()),
    );
    let router = Router::new()
        .route("/health", get(health))
        .route("/readyz", get(readiness));
    #[cfg(feature = "pilot-load")]
    let router = router.route("/_pilot/counters", get(pilot_counters));
    let router = router.with_state(state).merge(domain_routes);
    let router = if full_surface_enabled {
        router.layer(middleware::from_fn(
            crate::surface::enforce_registered_method,
        ))
    } else {
        router
    };
    router.layer(middleware::from_fn(observe_http))
}

#[cfg(feature = "pilot-load")]
async fn pilot_counters(
    State(state): State<AppState>,
    axum::extract::ConnectInfo(remote): axum::extract::ConnectInfo<std::net::SocketAddr>,
    headers: axum::http::HeaderMap,
) -> impl IntoResponse {
    let expected = std::env::var("EIGENINFERENCE_PILOT_COUNTER_TOKEN").unwrap_or_default();
    if let Err(status) = pilot_counter_authorized(remote, &headers, &expected) {
        let message = if status == StatusCode::FORBIDDEN {
            "pilot counters require a loopback client"
        } else {
            "pilot counter authorization required"
        };
        return (status, Json(serde_json::json!({"error": message})));
    }
    let (mailbox_used, mailbox_capacity) = state.pilot.as_ref().map_or((0, 0), |pilot| {
        let used = pilot.active_request_count();
        (used, used + pilot.request_dispatcher().remaining_capacity())
    });
    let provider_sessions = state
        .pilot
        .as_ref()
        .map_or(0, crate::pilot::PilotHandle::visible_provider_count);
    let (protocol_v1_sessions, protocol_v2_sessions, _) = state.pilot.as_ref().map_or(
        (0, 0, 0),
        crate::pilot::PilotHandle::provider_protocol_counts,
    );
    let (untrusted_sessions, self_signed_sessions, hardware_sessions) = state
        .pilot
        .as_ref()
        .map_or((0, 0, 0), crate::pilot::PilotHandle::provider_trust_counts);
    let (database_pool_used, database_pool_capacity) = state.database.pilot_pool_stats();
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "pilot_counters": {
                "mailbox_used": mailbox_used,
                "mailbox_capacity": mailbox_capacity,
                "active_tasks": pilot_task_count(),
                "file_descriptors": pilot_descriptor_count(),
                "database_pool_used": database_pool_used,
                "database_pool_capacity": database_pool_capacity,
                "provider_sessions": provider_sessions,
                "protocol_v1_sessions": protocol_v1_sessions,
                "protocol_v2_sessions": protocol_v2_sessions,
                "untrusted_sessions": untrusted_sessions,
                "self_signed_sessions": self_signed_sessions,
                "hardware_sessions": hardware_sessions,
            }
        })),
    )
}

#[cfg(feature = "pilot-load")]
fn pilot_counter_authorized(
    remote: std::net::SocketAddr,
    headers: &axum::http::HeaderMap,
    expected: &str,
) -> Result<(), StatusCode> {
    use subtle::ConstantTimeEq as _;

    if !remote.ip().is_loopback() {
        return Err(StatusCode::FORBIDDEN);
    }
    let presented = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or_default();
    if expected.len() < 32
        || presented.len() != expected.len()
        || !bool::from(presented.as_bytes().ct_eq(expected.as_bytes()))
    {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(())
}

#[cfg(feature = "pilot-load")]
fn pilot_task_count() -> usize {
    std::fs::read_dir("/proc/self/task")
        .map(|entries| entries.count())
        .unwrap_or_default()
}

#[cfg(feature = "pilot-load")]
fn pilot_descriptor_count() -> usize {
    std::fs::read_dir("/proc/self/fd")
        .map(|entries| entries.count())
        .unwrap_or_default()
}

#[cfg(all(test, feature = "pilot-load"))]
mod pilot_counter_tests {
    use super::*;
    use axum::http::{HeaderMap, HeaderValue, header};
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};

    const TOKEN: &str = "0123456789abcdef0123456789abcdef";

    fn headers(token: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).expect("header"),
        );
        headers
    }

    #[test]
    fn pilot_counter_authorization_requires_loopback_and_exact_long_token() {
        let loopback = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 1234);
        let remote = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(203, 0, 113, 7)), 1234);
        assert_eq!(
            pilot_counter_authorized(remote, &headers(TOKEN), TOKEN),
            Err(StatusCode::FORBIDDEN)
        );
        assert_eq!(
            pilot_counter_authorized(loopback, &HeaderMap::new(), TOKEN),
            Err(StatusCode::UNAUTHORIZED)
        );
        assert_eq!(
            pilot_counter_authorized(loopback, &headers("wrong"), TOKEN),
            Err(StatusCode::UNAUTHORIZED)
        );
        assert_eq!(
            pilot_counter_authorized(loopback, &headers(TOKEN), "short"),
            Err(StatusCode::UNAUTHORIZED)
        );
        assert_eq!(
            pilot_counter_authorized(loopback, &headers(TOKEN), TOKEN),
            Ok(())
        );
    }
}

async fn observe_http(request: axum::extract::Request, next: Next) -> axum::response::Response {
    if observability_exempt_read(request.method(), request.uri().path()) {
        return next.run(request).await;
    }
    let started = std::time::Instant::now();
    let method = http_method_tag(request.method());
    let route = http_route_tag(request.method(), request.uri().path());
    let inference_route = matches!(
        route.as_ref(),
        "/v1/chat/completions" | "/v1/responses" | "/v1/completions" | "/v1/messages"
    );
    let span = tracing::info_span!(
        "http.request",
        "span.type" = "web",
        "otel.kind" = "server",
        "http.request.method" = method,
        "http.route" = %route,
        "http.response.status_code" = tracing::field::Empty,
        "otel.status_code" = tracing::field::Empty,
    );
    let parent = global::get_text_map_propagator(|propagator| {
        propagator.extract(&HeaderExtractor(request.headers()))
    });
    let _ = span.set_parent(parent);
    let response = next.run(request).instrument(span.clone()).await;
    let elapsed = started.elapsed();
    span.record("http.response.status_code", response.status().as_u16());
    span.record(
        "otel.status_code",
        if response.status().is_server_error() {
            "ERROR"
        } else {
            "OK"
        },
    );
    let status_class = match response.status().as_u16() / 100 {
        2 => "2xx",
        3 => "3xx",
        4 => "4xx",
        5 => "5xx",
        _ => "other",
    };
    let tags = [
        Tag::new(TagKey::Method, method),
        Tag::new(TagKey::Route, route.clone()),
        Tag::new(TagKey::StatusClass, status_class),
    ];
    datadog::counter(Metric::HttpRequests, 1, &tags);
    datadog::histogram(
        Metric::HttpStageDurationMs,
        elapsed.as_secs_f64() * 1_000.0,
        &[
            Tag::new(TagKey::Stage, "total"),
            tags[0].clone(),
            tags[1].clone(),
            tags[2].clone(),
        ],
    );
    let budget = if inference_route {
        Duration::from_secs(120)
    } else {
        Duration::from_secs(10)
    };
    if elapsed > budget {
        datadog::counter(
            Metric::HttpStageBudgetExceeded,
            1,
            &[
                Tag::new(TagKey::Stage, "total"),
                tags[1].clone(),
                tags[2].clone(),
            ],
        );
    }
    response
}

fn observability_exempt_read(method: &axum::http::Method, path: &str) -> bool {
    method == axum::http::Method::GET
        && matches!(path, "/v1/admin/metrics" | "/v1/admin/quiescence")
}

struct HeaderExtractor<'a>(&'a axum::http::HeaderMap);

impl Extractor for HeaderExtractor<'_> {
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(|value| value.to_str().ok())
    }

    fn keys(&self) -> Vec<&str> {
        self.0.keys().map(axum::http::HeaderName::as_str).collect()
    }
}

fn http_method_tag(method: &axum::http::Method) -> &'static str {
    match *method {
        axum::http::Method::GET => "GET",
        axum::http::Method::POST => "POST",
        axum::http::Method::PUT => "PUT",
        axum::http::Method::PATCH => "PATCH",
        axum::http::Method::DELETE => "DELETE",
        axum::http::Method::HEAD => "HEAD",
        axum::http::Method::OPTIONS => "OPTIONS",
        _ => "OTHER",
    }
}

fn http_route_tag(method: &axum::http::Method, path: &str) -> std::borrow::Cow<'static, str> {
    match path {
        "/health" => std::borrow::Cow::Borrowed("/health"),
        "/readyz" => std::borrow::Cow::Borrowed("/readyz"),
        _ => crate::surface::registered_route(method, path)
            .map_or(std::borrow::Cow::Borrowed("unmatched"), |route| {
                std::borrow::Cow::Owned(route.path.replace('{', ":").replace('}', ""))
            }),
    }
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let compatibility = state.database.compatibility();
    let image_digest = std::env::var("EIGENINFERENCE_IMAGE_DIGEST").unwrap_or_default();
    let providers = state.pilot.as_ref().map_or_else(
        || state.providers.load(Ordering::Acquire),
        PilotHandle::visible_provider_count,
    );
    Json(HealthResponse {
        status: "ok",
        binary: "rust",
        service: std::env::var("DD_SERVICE")
            .unwrap_or_else(|_| "d-inference-coordinator".to_owned()),
        environment: std::env::var("DD_ENV").unwrap_or_else(|_| "development".to_owned()),
        listener_identity: std::env::var("EIGENINFERENCE_LISTENER_IDENTITY").unwrap_or_default(),
        coordinator_ownership_id: std::env::var("EIGENINFERENCE_COORDINATOR_OWNERSHIP_ID")
            .unwrap_or_default(),
        coordinator_app_id: std::env::var("EIGENINFERENCE_PRIVY_APP_ID").unwrap_or_default(),
        environment_id: std::env::var("EIGENINFERENCE_ENVIRONMENT_ID").unwrap_or_default(),
        draining: state.full_surface.as_ref().map_or_else(
            || state.draining.load(Ordering::Acquire),
            |surface| surface.operations.is_draining(),
        ),
        providers,
        version: option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
        build_commit: option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
        build_date: option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
        image_digest: image_digest.clone(),
        build: BuildMetadata {
            version: option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
            commit: option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
            date: option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
            rust_package_version: env!("CARGO_PKG_VERSION"),
            image_digest,
        },
        schema: HealthSchema {
            public_version: compatibility.public_version,
            rust_version: compatibility.rust_version,
            migration_checksum_valid: compatibility.migration_checksum_valid,
        },
        ownership_healthy: state
            .ownership
            .as_ref()
            .is_none_or(OwnershipStatus::is_healthy),
    })
}

async fn readiness(State(state): State<AppState>) -> impl IntoResponse {
    let draining = state.full_surface.as_ref().map_or_else(
        || state.draining.load(Ordering::Acquire),
        |surface| surface.operations.is_draining(),
    );
    let inflight = state.pilot.as_ref().map_or_else(
        || state.inflight.load(Ordering::Acquire),
        |pilot| u64::try_from(pilot.active_request_count()).unwrap_or(u64::MAX),
    );
    if draining {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ReadinessResponse {
                draining,
                inflight,
                ready: false,
            }),
        );
    }
    if state
        .ownership
        .as_ref()
        .is_some_and(|ownership| !ownership.is_healthy())
    {
        tracing::warn!("readiness coordinator ownership check failed");
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ReadinessResponse {
                draining,
                inflight,
                ready: false,
            }),
        );
    }
    if state.pilot.as_ref().is_some_and(|pilot| !pilot.is_ready()) {
        tracing::warn!("readiness pilot supervisor is not ready");
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ReadinessResponse {
                draining,
                inflight,
                ready: false,
            }),
        );
    }
    match state.database.ping().await {
        Ok(()) => (
            StatusCode::OK,
            Json(ReadinessResponse {
                draining,
                inflight,
                ready: true,
            }),
        ),
        Err(error) => {
            tracing::warn!(error = %error, "readiness database check failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(ReadinessResponse {
                    draining,
                    inflight,
                    ready: false,
                }),
            )
        }
    }
}

const fn is_false(value: &bool) -> bool {
    !*value
}

#[cfg(test)]
mod observability_exemption_tests {
    use super::observability_exempt_read;

    #[test]
    fn evidence_reads_have_no_observability_write_path() {
        assert!(observability_exempt_read(
            &axum::http::Method::GET,
            "/v1/admin/metrics"
        ));
        assert!(observability_exempt_read(
            &axum::http::Method::GET,
            "/v1/admin/quiescence"
        ));
        assert!(!observability_exempt_read(
            &axum::http::Method::POST,
            "/v1/admin/quiescence"
        ));
        assert!(!observability_exempt_read(
            &axum::http::Method::GET,
            "/v1/admin/utilization"
        ));
    }
}
