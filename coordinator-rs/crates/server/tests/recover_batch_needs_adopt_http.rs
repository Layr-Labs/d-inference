//! needs_adopt in quiescence + recover-undispatched-batch (DECISIONS #77).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn quiescence_needs_adopt_when_fencing_mismatches() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-need".into()),
            "need-adopt",
            "pilot-account",
            70_000,
            epoch0,
        )
        .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(epoch0 + 5)).unwrap();

    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["ownership_holding"], true);
    assert_eq!(v["ownership_epoch"], epoch0 + 5);
    assert_eq!(v["active_jobs_detail"][0]["job_id"], "need-adopt");
    assert_eq!(v["active_jobs_detail"][0]["fencing_epoch"], epoch0);
    assert_eq!(v["active_jobs_detail"][0]["needs_adopt"], true);
}

#[tokio::test]
async fn recover_undispatched_batch_clears_reserved_skips_held() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("batch-a", 50_000, false),
            ("batch-b", 60_000, false),
            ("batch-held", 80_000, true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                amt,
                epoch0,
            )
            .unwrap();
            if hold {
                led.mark_start_authorized_fenced(epoch0, id, "pilot-account")
                    .unwrap();
            }
        }
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(40)).unwrap();

    let app = router(state.clone());
    // Adopt all first.
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
    assert_eq!(body_json(res).await["adopted_count"], 3);

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched-batch")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "recovered_batch");
    assert_eq!(v["released_count"], 2);
    assert_eq!(v["skipped_count"], 0); // held jobs not in reserved_not_started list
    assert_eq!(v["failed_count"], 0);
    assert_eq!(v["refunded_micro_usd"], 110_000);
    assert_eq!(v["active_jobs"], 1); // batch-held remains
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);
}
