//! Single-job admin recover/force-settle default to job owner (DECISIONS #89).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use tower::ServiceExt;

#[tokio::test]
async fn admin_recover_defaults_to_job_owner_not_pilot() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("carol", 400_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-carol".into()),
            "carol-res",
            "carol",
            50_000,
            epoch,
        )
        .unwrap();
    }

    let app = router(state.clone());
    // Omit account — must refund carol, not pilot.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"job_id":"carol-res"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["account"], "carol");
    assert_eq!(v["balance_micro_usd"], 400_000);
    assert_eq!(state.ledger.lock().await.balance("carol").0, 400_000);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );

    // Explicit wrong account conflicts.
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-carol2".into()),
            "carol-res2",
            "carol",
            10_000,
            epoch,
        )
        .unwrap();
    }
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"job_id":"carol-res2","account":"pilot-account"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);
    assert_eq!(body_json(res).await["error"]["code"], "account_mismatch");
}

#[tokio::test]
async fn admin_force_settle_defaults_to_job_owner_not_pilot() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("dave", 300_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dave".into()),
            "dave-held",
            "dave",
            80_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "dave-held", "dave")
            .unwrap();
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"job_id":"dave-held","actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["account"], "dave");
    assert_eq!(v["balance_micro_usd"], 300_000);

    // Wrong account conflicts on a fresh hold.
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dave2".into()),
            "dave-held2",
            "dave",
            20_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "dave-held2", "dave")
            .unwrap();
    }
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"job_id":"dave-held2","actual_micro_usd":0,"account":"pilot-account"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);
    assert_eq!(body_json(res).await["error"]["code"], "account_mismatch");
}
