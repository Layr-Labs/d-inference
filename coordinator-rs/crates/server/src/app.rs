use axum::{Json, Router, extract::State, http::StatusCode, response::IntoResponse, routing::get};
use darkbloom_coordinator_core::ProtocolSupport;
use serde::Serialize;

use crate::database::Database;

#[derive(Clone, Debug)]
pub struct AppState {
    database: Database,
    protocol: ProtocolSupport,
}

impl AppState {
    pub fn new(database: Database) -> Self {
        Self {
            database,
            protocol: ProtocolSupport::default(),
        }
    }
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
    version: &'static str,
    protocol_minimum_major: u16,
    protocol_preferred_major: u16,
}

#[derive(Debug, Serialize)]
struct ReadinessResponse {
    ready: bool,
    database: &'static str,
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
        version: env!("CARGO_PKG_VERSION"),
        protocol_minimum_major: state.protocol.minimum_major,
        protocol_preferred_major: state.protocol.preferred_major,
    })
}

async fn readiness(State(state): State<AppState>) -> impl IntoResponse {
    match state.database.ping().await {
        Ok(()) => (
            StatusCode::OK,
            Json(ReadinessResponse {
                ready: true,
                database: "ready",
            }),
        ),
        Err(error) => {
            tracing::warn!(error = %error, "readiness database check failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(ReadinessResponse {
                    ready: false,
                    database: "unavailable",
                }),
            )
        }
    }
}
