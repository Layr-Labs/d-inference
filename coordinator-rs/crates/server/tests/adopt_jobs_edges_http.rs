//! adopt-jobs edge cases: no ownership, explicit ids, partial failure (DECISIONS #72).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn adopt_jobs_without_ownership_returns_503() {
    let app = router(pilot_app_state(false));
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");
}

#[tokio::test]
async fn adopt_jobs_explicit_ids_partial_failure() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-partial".into()),
            "alive-1",
            "pilot-account",
            60_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-partial-d".into()),
            "dead-1",
            "pilot-account",
            40_000,
            epoch0,
        )
        .unwrap();
        led.release(
            darkbloom_coordinator::OperationKey("rel-dead".into()),
            "dead-1",
            "pilot-account",
        )
        .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(30)).unwrap();

    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_ids": ["alive-1", "dead-1", "missing-1"]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["adopted_count"], 1);
    assert_eq!(v["failed_count"], 2);
    assert_eq!(v["adopted"][0]["job_id"], "alive-1");
    assert_eq!(v["adopted"][0]["fencing_epoch"], 30);
}

#[tokio::test]
async fn concurrent_adopt_jobs_bulk_all_succeed() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for i in 0..4 {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-cab-{i}")),
                &format!("j-cab-{i}"),
                "pilot-account",
                25_000,
                epoch0,
            )
            .unwrap();
        }
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(31)).unwrap();

    let app = router(state.clone());
    let mut handles = Vec::new();
    for _ in 0..6 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/adopt-jobs")
                        .header("content-type", "application/json")
                        .body(Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            let v = body_json(res).await;
            v["fencing_epoch"] == 31 && v["adopted_count"] == 4
        }));
    }
    for h in handles {
        assert!(h.await.unwrap());
    }
    let led = state.ledger.lock().await;
    for i in 0..4 {
        assert_eq!(led.job_fencing_epoch(&format!("j-cab-{i}")), Some(31));
    }
}
