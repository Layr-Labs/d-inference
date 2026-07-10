//! Adopt then cutover-drain-all after fencing abort (DECISIONS #120).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn adopt_then_cutover_drain_all_after_fencing_abort() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("nora", 300_000, 0).unwrap();
        led.credit("owen", 300_000, 0).unwrap();
        for (id, acct) in [("af-n1", "nora"), ("af-n2", "nora"), ("af-o1", "owen")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    // Steal fencing: re-acquire without adopt.
    ownership.release();
    ownership.acquire(Epoch(epoch + 12)).unwrap();

    let app = router(state.clone());

    // Quiescence hints adopt first.
    let q = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let qv = body_json(q).await;
    assert_eq!(qv["cutover_hint"], "adopt-jobs then cutover-drain-all");
    assert!(qv["orphan_summary"]["needs_adopt_count"].as_u64().unwrap() >= 3);

    // Force-settle-batch without adopt aborts.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 3);

    // Single-job force-settle also ownership_lost.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "af-n1",
                        "actual_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    // Adopt then cutover-drain-all clears everything.
    let res = app
        .clone()
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
    assert_eq!(body_json(res).await["adopted_count"], 3);

    let q = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(q).await["cutover_hint"], "cutover-drain-all");

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("nora").0, 300_000);
    assert_eq!(state.ledger.lock().await.balance("owen").0, 300_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

    let q = app
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(q).await["cutover_hint"], "ready");
}
