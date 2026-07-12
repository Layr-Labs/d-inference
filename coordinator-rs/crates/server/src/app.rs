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
    #[serde(skip_serializing_if = "is_false")]
    draining: bool,
    providers: usize,
    version: &'static str,
    build_commit: &'static str,
    build_date: &'static str,
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
        .route("/readyz", get(readiness))
        .with_state(state)
        .merge(domain_routes);
    let router = if full_surface_enabled {
        router.layer(middleware::from_fn(
            crate::surface::enforce_registered_method,
        ))
    } else {
        router
    };
    router.layer(middleware::from_fn(observe_http))
}

async fn observe_http(request: axum::extract::Request, next: Next) -> axum::response::Response {
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
        draining: state.full_surface.as_ref().map_or_else(
            || state.draining.load(Ordering::Acquire),
            |surface| surface.operations.is_draining(),
        ),
        providers,
        version: option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
        build_commit: option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
        build_date: option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
        build: BuildMetadata {
            version: option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
            commit: option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
            date: option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
            rust_package_version: env!("CARGO_PKG_VERSION"),
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
