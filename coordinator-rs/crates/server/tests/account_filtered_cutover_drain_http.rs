//! Account-filtered cutover-drain + orphan_summary_by_account (DECISIONS #111).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn account_filtered_cutover_drain_leaves_foreign_in_by_account() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("yara", 300_000, 0).unwrap();
        led.credit("zane", 300_000, 0).unwrap();
        for (id, acct) in [
            ("afc-y1", "yara"),
            ("afc-y2", "yara"),
            ("afc-z1", "zane"),
            ("afc-z2", "zane"),
        ] {
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

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "yara", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drained");
    assert_eq!(v["clear_orphans"]["settled_count"], 2);
    assert_eq!(v["clear_orphans"]["account_filter"], "yara");
    // Not fully ready — zane orphans remain.
    assert_eq!(v["ready"], false);
    assert_eq!(state.ledger.lock().await.balance("yara").0, 300_000);
    assert_eq!(state.ledger.lock().await.balance("zane").0, 220_000);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 2);

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
    assert_eq!(q.status(), StatusCode::SERVICE_UNAVAILABLE);
    let qv = body_json(q).await;
    assert_eq!(qv["ready"], false);
    assert_eq!(qv["cutover_hint"], "cutover-drain-all");
    let by = qv["orphan_summary_by_account"].as_array().unwrap();
    assert!(by.iter().all(|r| r["account"] != "yara"));
    let zane = by.iter().find(|r| r["account"] == "zane").unwrap();
    assert_eq!(zane["held_start_authorized_count"], 2);
    assert_eq!(zane["reserved_not_started_count"], 0);

    // Clear zane via account-filtered cutover-drain.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "zane", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("zane").0, 300_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn concurrent_per_account_cutover_drain_conserves() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("ada", 250_000, 0).unwrap();
        led.credit("ben", 250_000, 0).unwrap();
        for (id, acct) in [("cpc-a1", "ada"), ("cpc-a2", "ada"), ("cpc-b1", "ben"), ("cpc-b2", "ben")]
        {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                35_000,
                epoch,
            )
            .unwrap();
            if id.ends_with('1') {
                led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
            }
        }
    }
    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for acct in ["ada", "ben"] {
        for _ in 0..3 {
            let app = app.clone();
            let acct = acct.to_string();
            handles.push(tokio::spawn(async move {
                let res = app
                    .as_ref()
                    .clone()
                    .oneshot(
                        Request::builder()
                            .method("POST")
                            .uri("/v1/admin/cutover-drain")
                            .header("content-type", "application/json")
                            .body(Body::from(
                                json!({ "account": acct, "actual_micro_usd": 0 }).to_string(),
                            ))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(res.status(), StatusCode::OK);
                body_json(res).await
            }));
        }
    }
    let mut ada_settled = 0u64;
    let mut ada_released = 0u64;
    let mut ben_settled = 0u64;
    let mut ben_released = 0u64;
    for h in handles {
        let v = h.await.unwrap();
        let clear = &v["clear_orphans"];
        let settled = clear["settled_count"].as_u64().unwrap_or(0);
        let released = clear["released_count"].as_u64().unwrap_or(0);
        match clear["account_filter"].as_str() {
            Some("ada") => {
                ada_settled += settled;
                ada_released += released;
            }
            Some("ben") => {
                ben_settled += settled;
                ben_released += released;
            }
            _ => panic!("unexpected: {v}"),
        }
    }
    assert_eq!(ada_settled, 1);
    assert_eq!(ada_released, 1);
    assert_eq!(ben_settled, 1);
    assert_eq!(ben_released, 1);
    assert_eq!(state.ledger.lock().await.balance("ada").0, 250_000);
    assert_eq!(state.ledger.lock().await.balance("ben").0, 250_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

    let q = app
        .as_ref()
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::OK);
    let qv = body_json(q).await;
    assert_eq!(qv["ready"], true);
    assert!(qv["orphan_summary_by_account"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn quiescence_without_ownership_still_lists_by_account() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("cara", 150_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-c1".into()),
            "qo-c1",
            "cara",
            20_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "qo-c1", "cara")
            .unwrap();
    }
    ownership.release();

    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["ownership_holding"], false);
    // needs_adopt false when not holding (unknown epoch), but by_account still lists holds.
    assert_eq!(v["orphan_summary"]["needs_adopt_count"], 0);
    assert_eq!(v["orphan_summary"]["held_start_authorized_count"], 1);
    let by = v["orphan_summary_by_account"].as_array().unwrap();
    assert_eq!(by.len(), 1);
    assert_eq!(by[0]["account"], "cara");
    assert_eq!(by[0]["held_start_authorized_count"], 1);
    assert_eq!(by[0]["needs_adopt_count"], 0);
}
