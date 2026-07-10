//! Bulk adopt-jobs after ownership re-acquire (DECISIONS #72).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn adopt_jobs_bulk_adopts_all_active_orphans() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (i, amount) in [("a", 50_000), ("b", 75_000), ("c", 90_000)] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-bulk-{i}")),
                &format!("orphan-{i}"),
                "pilot-account",
                amount,
                epoch0,
            )
            .unwrap();
        }
        led.mark_start_authorized_fenced(epoch0, "orphan-c", "pilot-account")
            .unwrap();
    }

    state.ownership.release();
    state.ownership.acquire(Epoch(20)).unwrap();

    let app = router(state.clone());
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
    let v = body_json(res).await;
    assert_eq!(v["action"], "adopted_batch");
    assert_eq!(v["fencing_epoch"], 20);
    assert_eq!(v["adopted_count"], 3);
    assert_eq!(v["failed_count"], 0);

    // Recover reserved orphans; force-settle the held one.
    for id in ["orphan-a", "orphan-b"] {
        let res = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/recover-undispatched")
                    .header("content-type", "application/json")
                    .body(Body::from(json!({ "job_id": id }).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(body_json(res).await["action"], "released");
    }

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "orphan-c",
                        "actual_micro_usd": 10_000,
                        "terminal_digest": "bulk-c-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["action"], "released");
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn concurrent_adopt_job_all_succeed_same_epoch() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cadopt".into()),
            "j-cadopt",
            "pilot-account",
            100_000,
            epoch0,
        )
        .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(21)).unwrap();

    let app = router(state.clone());
    let mut handles = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/adopt-job")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "job_id": "j-cadopt" }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            let v = body_json(res).await;
            v["fencing_epoch"] == 21
        }));
    }
    for h in handles {
        assert!(h.await.unwrap());
    }
    assert_eq!(
        state.ledger.lock().await.job_fencing_epoch("j-cadopt"),
        Some(21)
    );
}
