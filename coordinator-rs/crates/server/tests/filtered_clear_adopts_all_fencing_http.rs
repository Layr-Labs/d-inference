//! Account-filtered clear adopts all jobs for fencing (DECISIONS #121).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn filtered_clear_adopts_foreign_fencing_without_money_move() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("piper", 250_000, 0).unwrap();
        led.credit("quinn", 250_000, 0).unwrap();
        for (id, acct, amt, held) in [
            ("fc-p1", "piper", 40_000_i64, true),
            ("fc-q1", "quinn", 35_000, false),
            ("fc-q2", "quinn", 45_000, true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                amt,
                old,
            )
            .unwrap();
            if held {
                led.mark_start_authorized_fenced(old, id, acct).unwrap();
            }
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 20)).unwrap();

    let app = router(state.clone());

    // Before: all need adopt.
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
    assert_eq!(qv["orphan_summary"]["needs_adopt_count"], 3);

    // Clear only piper — adopts everyone, money only for piper.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "piper", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["adopted_count"], 3);
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["released_count"], 0);
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["accounts_needing_cutover"], json!(["quinn"]));
    assert_eq!(state.ledger.lock().await.balance("piper").0, 250_000);
    // quinn still reserved/held — no money move.
    assert_eq!(state.ledger.lock().await.balance("quinn").0, 170_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 2);

    // Foreign fencing rebound — no needs_adopt; can force-settle without adopt.
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
    assert_eq!(qv["orphan_summary"]["needs_adopt_count"], 0);
    assert_eq!(qv["cutover_hint"], "cutover-drain-all");
    assert_eq!(qv["accounts_needing_cutover"], json!(["quinn"]));

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "fc-q2",
                        "account": "quinn",
                        "actual_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["action"], "released");

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_id": "fc-q1", "account": "quinn" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(state.ledger.lock().await.balance("quinn").0, 250_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn filtered_cutover_drain_leaves_foreign_without_needs_adopt() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("rina", 200_000, 0).unwrap();
        led.credit("sam", 200_000, 0).unwrap();
        for (id, acct) in [("fd-r1", "rina"), ("fd-s1", "sam")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                25_000,
                old,
            )
            .unwrap();
            led.mark_start_authorized_fenced(old, id, acct).unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 33)).unwrap();

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "rina", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], false);
    assert_eq!(v["accounts_needing_cutover"], json!(["sam"]));
    assert_eq!(v["clear_orphans"]["adopted_count"], 2);

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
    assert_eq!(qv["orphan_summary"]["needs_adopt_count"], 0);
    assert_eq!(qv["cutover_hint"], "cutover-drain-all");

    // Direct force-settle works without adopt.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "accounts": ["sam"], "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("sam").0, 200_000);
}
