use std::{fs, path::PathBuf, time::Duration};

use axum::http::StatusCode;
use darkbloom_coordinator_server::{
    app::{AppState, router},
    database::Database,
};
use serde::Deserialize;
use serde_json::Value;

use super::support::{request_json, reset_schema, with_isolated_database};

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

#[tokio::test]
async fn health_and_readiness_use_real_postgres() {
    with_isolated_database(|url| async move {
        reset_schema(&url, 5, 3, 5, 5).await;
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
    })
    .await;
}

async fn assert_matches_contract(app: &axum::Router, path: &str, contract: &HttpResponse) {
    let (status, payload) = request_json(app, path).await;
    assert_eq!(status.as_u16(), contract.status);
    let expected: Value = serde_json::from_str(&contract.body).expect("contract body JSON");
    assert_eq!(payload, expected);
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
