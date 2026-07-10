use std::time::Duration;

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use darkbloom_coordinator_server::{
    app::{AppState, router},
    database::Database,
};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

fn database_url() -> Option<String> {
    std::env::var("DATABASE_URL")
        .or_else(|_| std::env::var("EIGENINFERENCE_DATABASE_URL"))
        .ok()
        .filter(|value| !value.trim().is_empty())
}

#[tokio::test]
async fn health_and_readiness_use_real_postgres() {
    let Some(url) = database_url() else {
        eprintln!("DATABASE_URL is unset; skipping real PostgreSQL integration test");
        return;
    };
    let database = Database::connect(&url, 2, Duration::from_secs(3))
        .await
        .expect("connect real PostgreSQL");
    let app = router(AppState::new(database.clone()));

    let health = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/health")
                .body(Body::empty())
                .expect("health request"),
        )
        .await
        .expect("health response");
    assert_eq!(health.status(), StatusCode::OK);
    let body = health
        .into_body()
        .collect()
        .await
        .expect("health body")
        .to_bytes();
    let payload: Value = serde_json::from_slice(&body).expect("health JSON");
    assert_eq!(payload["status"], "ok");
    assert_eq!(payload["protocol_minimum_major"], 1);
    assert_eq!(payload["protocol_preferred_major"], 2);

    let readiness = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/readyz")
                .body(Body::empty())
                .expect("readiness request"),
        )
        .await
        .expect("readiness response");
    assert_eq!(readiness.status(), StatusCode::OK);
    drop(app);
    database.close().await;
}
