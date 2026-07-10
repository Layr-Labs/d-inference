//! Deposit ∥ clear-orphans remaining-accounts race (DECISIONS #130).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{lock_clear_orphans_hook_tests, router, set_clear_orphans_phase_hook};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_deposit_and_clear_conserves_with_remaining_accounts() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("nora", 200_000, 0).unwrap();
        led.credit("owen", 200_000, 0).unwrap();
        for (id, acct, held) in [
            ("dc-n1", "nora", true),
            ("dc-n2", "nora", false),
            ("dc-o1", "owen", true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                epoch,
            )
            .unwrap();
            if held {
                led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
            }
        }
    }

    let app = Arc::new(router(state.clone()));
    let mut deposit_handles = Vec::new();
    for i in 0..4 {
        let app = app.clone();
        deposit_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/deposits")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "event_id": format!("evt-dc-{i}"),
                                "account": if i % 2 == 0 { "nora" } else { "owen" },
                                "amount_micro_usd": 25_000,
                                "withdrawable_micro_usd": 0
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        }));
    }
    let mut clear_handles = Vec::new();
    for _ in 0..3 {
        let app = app.clone();
        clear_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/clear-orphans")
                        .header("content-type", "application/json")
                        .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        }));
    }

    let mut applied = 0usize;
    let mut saw_remaining_field = false;
    for h in deposit_handles {
        let v = h.await.unwrap();
        if v["applied"].as_bool().unwrap() {
            applied += 1;
        }
        assert!(v.get("accounts_needing_cutover").is_some());
        assert!(v.get("needs_adopt_count").is_some());
        saw_remaining_field = true;
    }
    assert!(saw_remaining_field);
    assert_eq!(applied, 4);

    let mut settled_total = 0u64;
    let mut released_total = 0u64;
    let mut final_remaining = None;
    for h in clear_handles {
        let v = h.await.unwrap();
        settled_total += v["settled_count"].as_u64().unwrap_or(0);
        released_total += v["released_count"].as_u64().unwrap_or(0);
        assert!(v.get("accounts_needing_cutover").is_some());
        final_remaining = Some(v["accounts_needing_cutover"].clone());
    }
    // Exactly one clear wins the money moves; others see already_terminal / empty.
    assert_eq!(settled_total + released_total, 3);
    assert_eq!(final_remaining.unwrap(), json!([]));
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

    // Start 200k each; reserves 80k nora + 40k owen; deposits +50k each account
    // (2×25k); clear refunds all reserved → bals = 200k + 50k.
    assert_eq!(state.ledger.lock().await.balance("nora").0, 250_000);
    assert_eq!(state.ledger.lock().await.balance("owen").0, 250_000);
}

#[tokio::test]
async fn deposit_remaining_accounts_empty_after_cutover() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("piper", 150_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dp".into()),
            "dp-1",
            "piper",
            30_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "dp-1", "piper")
            .unwrap();
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt-dp-1",
                        "account": "piper",
                        "amount_micro_usd": 20_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let v = body_json(res).await;
    assert_eq!(v["accounts_needing_cutover"], json!(["piper"]));

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
    assert_eq!(body_json(res).await["ready"], true);

    // Idempotent deposit replay still reports empty remaining.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt-dp-1",
                        "account": "piper",
                        "amount_micro_usd": 20_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let v = body_json(res).await;
    assert_eq!(v["applied"], false);
    assert_eq!(v["accounts_needing_cutover"], json!([]));
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(state.ledger.lock().await.balance("piper").0, 170_000);
}
