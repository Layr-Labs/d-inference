//! Single-job force-settle / recover / held-review return remaining accounts (DECISIONS #127).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn force_settle_returns_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("tess", 200_000, 0).unwrap();
        led.credit("uma", 200_000, 0).unwrap();
        for (id, acct) in [("sj-t1", "tess"), ("sj-u1", "uma")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "sj-t1",
                        "actual_micro_usd": 0,
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["charged_micro_usd"], 0);
    assert_eq!(v["accounts_needing_cutover"], json!(["uma"]));
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(state.ledger.lock().await.balance("tess").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("uma").0, 160_000);
}

#[tokio::test]
async fn recover_undispatched_returns_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("vera", 150_000, 0).unwrap();
        led.credit("wade", 150_000, 0).unwrap();
        for (id, acct) in [("sj-v1", "vera"), ("sj-w1", "wade")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                25_000,
                epoch,
            )
            .unwrap();
        }
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "sj-v1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["accounts_needing_cutover"], json!(["wade"]));
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["active_jobs"], 1);
    assert_eq!(state.ledger.lock().await.balance("vera").0, 150_000);
    assert_eq!(state.ledger.lock().await.balance("wade").0, 125_000);
}

#[tokio::test]
async fn held_review_returns_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("xena", 130_000, 0).unwrap();
        led.credit("yuri", 130_000, 0).unwrap();
        for (id, acct) in [("sj-x1", "xena"), ("sj-y1", "yuri")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                30_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "sj-x1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "held_for_review");
    assert_eq!(v["account"], "xena");
    assert_eq!(v["reserved_micro_usd"], 30_000);
    assert_eq!(v["needs_adopt_count"], 0);
    let mut accounts = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["xena".to_string(), "yuri".to_string()]);
    // No money moved.
    assert_eq!(state.ledger.lock().await.balance("xena").0, 100_000);
    assert_eq!(state.ledger.lock().await.balance("yuri").0, 100_000);
}

#[tokio::test]
async fn force_settle_chain_to_cutover_without_quiescence() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("zane", 180_000, 0).unwrap();
        led.credit("abby", 180_000, 0).unwrap();
        for (id, acct) in [("sj-z1", "zane"), ("sj-a1", "abby")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                45_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_id": "sj-z1", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let accounts = body_json(res).await["accounts_needing_cutover"].clone();
    assert_eq!(accounts, json!(["abby"]));

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "actual_micro_usd": 0,
                        "accounts": accounts,
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("zane").0, 180_000);
    assert_eq!(state.ledger.lock().await.balance("abby").0, 180_000);
}
