use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
};

use axum::{
    Json, Router, extract::State, http::StatusCode, middleware, response::IntoResponse,
    routing::get,
};
use serde::Serialize;

use crate::{
    database::Database, ownership::OwnershipStatus, pilot::PilotHandle, surface::FullSurfaceState,
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
    #[serde(skip_serializing_if = "is_false")]
    draining: bool,
    providers: usize,
    version: &'static str,
    build_commit: &'static str,
    build_date: &'static str,
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
    if full_surface_enabled {
        router.layer(middleware::from_fn(
            crate::surface::enforce_registered_method,
        ))
    } else {
        router
    }
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let providers = state.pilot.as_ref().map_or_else(
        || state.providers.load(Ordering::Acquire),
        PilotHandle::visible_provider_count,
    );
    Json(HealthResponse {
        status: "ok",
        draining: state.full_surface.as_ref().map_or_else(
            || state.draining.load(Ordering::Acquire),
            |surface| surface.operations.is_draining(),
        ),
        providers,
        version: option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
        build_commit: option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
        build_date: option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
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
