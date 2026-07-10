use std::{fs, path::PathBuf, time::Duration};

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use darkbloom_coordinator_server::{
    app::{AppState, router},
    database::Database,
};
use http_body_util::BodyExt;
use serde::Deserialize;
use serde_json::Value;
use tower::ServiceExt;

#[derive(Deserialize)]
struct HttpContracts {
    exchanges: Vec<HttpExchange>,
}

#[derive(Deserialize)]
struct HttpExchange {
    name: String,
    response: HttpResponse,
}

#[derive(Deserialize)]
struct HttpResponse {
    status: u16,
    body: String,
}

fn database_url() -> Option<String> {
    std::env::var("DARKBLOOM_TEST_DATABASE_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
}

#[tokio::test]
async fn health_and_readiness_use_real_postgres() {
    let Some(url) = database_url() else {
        assert_ne!(
            std::env::var("CI").as_deref(),
            Ok("true"),
            "DARKBLOOM_TEST_DATABASE_URL is required in CI"
        );
        eprintln!("DATABASE_URL is unset; skipping real PostgreSQL integration test");
        return;
    };
    let database = Database::connect(&url, 2, Duration::from_secs(3))
        .await
        .expect("connect real PostgreSQL");
    let state = AppState::new(database.clone());
    let app = router(state.clone());
    let contracts = load_http_contracts();

    assert_matches_contract(&app, "/health", contract(&contracts, "health")).await;
    assert_matches_contract(&app, "/readyz", contract(&contracts, "readiness")).await;

    state.set_inflight(3);
    state.set_draining(true);
    let (status, payload) = request_json(&app, "/health").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        payload,
        serde_json::json!({
            "status": "ok",
            "draining": true,
            "providers": 0,
            "version": "dev",
            "build_commit": "unknown",
            "build_date": "unknown"
        })
    );
    let (status, payload) = request_json(&app, "/readyz").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        payload,
        serde_json::json!({"draining": true, "inflight": 3, "ready": false})
    );

    state.set_draining(false);
    database
        .clone()
        .close(Duration::from_secs(1))
        .await
        .expect("close test database pool");
    let (status, payload) = request_json(&app, "/readyz").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        payload,
        serde_json::json!({"draining": false, "inflight": 3, "ready": false})
    );
    drop(app);
    database
        .close(Duration::from_secs(1))
        .await
        .expect("close database pool");
}

async fn assert_matches_contract(app: &axum::Router, path: &str, contract: &HttpResponse) {
    let (status, payload) = request_json(app, path).await;
    assert_eq!(status.as_u16(), contract.status);
    let expected: Value = serde_json::from_str(&contract.body).expect("contract body JSON");
    assert_eq!(payload, expected);
}

async fn request_json(app: &axum::Router, path: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(path)
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    let status = response.status();
    let body = response
        .into_body()
        .collect()
        .await
        .expect("response body")
        .to_bytes();
    let payload = serde_json::from_slice(&body).expect("response JSON");
    (status, payload)
}

fn contract<'a>(contracts: &'a HttpContracts, name: &str) -> &'a HttpResponse {
    &contracts
        .exchanges
        .iter()
        .find(|exchange| exchange.name == name)
        .unwrap_or_else(|| panic!("missing HTTP contract {name}"))
        .response
}

fn load_http_contracts() -> HttpContracts {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("tests/contracts/http/core.json");
    let data = fs::read(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_slice(&data)
        .unwrap_or_else(|error| panic!("decode {}: {error}", path.display()))
}
