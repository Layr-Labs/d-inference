use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
};

use axum::{Json, Router, extract::State, http::StatusCode, response::IntoResponse, routing::get};
use serde::Serialize;

use crate::database::Database;

#[derive(Clone, Debug)]
pub struct AppState {
    database: Database,
    providers: Arc<AtomicUsize>,
    draining: Arc<AtomicBool>,
    inflight: Arc<AtomicU64>,
}

impl AppState {
    pub fn new(database: Database) -> Self {
        Self {
            database,
            providers: Arc::new(AtomicUsize::new(0)),
            draining: Arc::new(AtomicBool::new(false)),
            inflight: Arc::new(AtomicU64::new(0)),
        }
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
    Router::new()
        .route("/health", get(health))
        .route("/readyz", get(readiness))
        .with_state(state)
}

async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        draining: state.draining.load(Ordering::Acquire),
        providers: state.providers.load(Ordering::Acquire),
        version: option_env!("DARKBLOOM_BUILD_VERSION").unwrap_or("dev"),
        build_commit: option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown"),
        build_date: option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown"),
    })
}

async fn readiness(State(state): State<AppState>) -> impl IntoResponse {
    let draining = state.draining.load(Ordering::Acquire);
    let inflight = state.inflight.load(Ordering::Acquire);
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
