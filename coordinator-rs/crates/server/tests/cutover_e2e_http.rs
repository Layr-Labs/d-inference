//! Full cutover e2e + clear-orphans charged settle (DECISIONS #84).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn cutover_e2e_steal_clear_drain_ready() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("cut-a", 12_000, false),
            ("cut-b", 18_000, false),
            ("cut-h", 22_000, true),
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
    state.ownership.acquire(Epoch(42)).unwrap();

    let app = router(state);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let q = body_json(res).await;
    assert_eq!(q["ready"], false);
    assert_eq!(q["orphan_summary"]["needs_adopt_count"], 3);
    assert_eq!(q["orphan_summary"]["reserved_not_started_count"], 2);
    assert_eq!(q["orphan_summary"]["held_start_authorized_count"], 1);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    let v = body_json(res).await;
    assert_eq!(v["action"], "cleared_orphans");
    assert_eq!(v["adopted_count"], 3);
    assert_eq!(v["released_count"], 2);
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["active_jobs"], 0);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["ready"], false); // outbox pending

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["ready"], true);

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
    assert_eq!(res.status(), StatusCode::OK);
    let q = body_json(res).await;
    assert_eq!(q["ready"], true);
    assert_eq!(q["orphan_summary"]["needs_adopt_count"], 0);
    assert_eq!(q["active_jobs"], 0);
}

#[tokio::test]
async fn clear_orphans_with_actual_charges_held() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-chg".into()),
            "chg-held",
            "pilot-account",
            100_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "chg-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(8)).unwrap();

    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":25000}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["charged_micro_usd"], 25_000);
    assert_eq!(v["released_count"], 0);
    // 1_000_000 - 100_000 reserved + (100_000 - 25_000) refund = 975_000
    assert_eq!(v["balance_micro_usd"], 975_000);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        975_000
    );
}
