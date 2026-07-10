//! adopt-jobs / batch recover+force return remaining cutover accounts (DECISIONS #124).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn adopt_jobs_returns_remaining_accounts_for_chaining() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("ada", 200_000, 0).unwrap();
        led.credit("ben", 200_000, 0).unwrap();
        for (id, acct, held) in [
            ("aj-a1", "ada", true),
            ("aj-a2", "ada", false),
            ("aj-b1", "ben", true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                30_000,
                old,
            )
            .unwrap();
            if held {
                led.mark_start_authorized_fenced(old, id, acct).unwrap();
            }
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 7)).unwrap();

    let app = router(state.clone());

    // Adopt all — fencing cleared; money still reserved/held.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from(json!({}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["adopted_count"], 3);
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["active_jobs"], 3);
    assert_eq!(v["held_start_authorized"], 2);
    let mut accounts = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["ada".to_string(), "ben".to_string()]);

    // Chain cutover-drain-all without quiescence — uses remaining accounts.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["accounts_needing_cutover"], json!([]));
    assert_eq!(state.ledger.lock().await.balance("ada").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("ben").0, 200_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn account_filtered_adopt_lists_foreign_remaining() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("cara", 150_000, 0).unwrap();
        led.credit("dan", 150_000, 0).unwrap();
        for (id, acct) in [("aj-c1", "cara"), ("aj-d1", "dan")] {
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
    ownership.acquire(Epoch(old + 9)).unwrap();

    let app = router(state.clone());

    // Filtered adopt only cara — dan still needs adopt for fencing, but
    // adopt_fencing on cara alone leaves dan's fencing stale → needs_adopt.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "account": "cara" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["adopted_count"], 1);
    assert_eq!(v["account_filter"], "cara");
    assert_eq!(v["needs_adopt_count"], 1);
    assert_eq!(v["accounts_needing_cutover"], json!(["cara", "dan"]));
}

#[tokio::test]
async fn force_settle_batch_returns_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("eve", 180_000, 0).unwrap();
        led.credit("finn", 180_000, 0).unwrap();
        for (id, acct) in [("fs-e1", "eve"), ("fs-f1", "finn")] {
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

    // Settle only eve — finn remains.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "eve", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["accounts_needing_cutover"], json!(["finn"]));
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(state.ledger.lock().await.balance("eve").0, 180_000);
    assert_eq!(state.ledger.lock().await.balance("finn").0, 140_000);
}

#[tokio::test]
async fn recover_batch_returns_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("gina", 160_000, 0).unwrap();
        led.credit("hank", 160_000, 0).unwrap();
        for (id, acct) in [("rb-g1", "gina"), ("rb-h1", "hank")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                35_000,
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
                .uri("/v1/admin/recover-undispatched-batch")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "account": "gina" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["accounts_needing_cutover"], json!(["hank"]));
    assert_eq!(v["active_jobs"], 1);
    assert_eq!(state.ledger.lock().await.balance("gina").0, 160_000);
    assert_eq!(state.ledger.lock().await.balance("hank").0, 125_000);
}
