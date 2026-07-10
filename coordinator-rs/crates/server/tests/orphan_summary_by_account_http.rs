//! Quiescence orphan_summary_by_account + deposit vs cutover drain-abort (DECISIONS #110).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_outbox_drain_hook_tests, router, set_outbox_drain_entry_hook, Epoch,
};
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn quiescence_orphan_summary_by_account() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("wren", 200_000, 0).unwrap();
        led.credit("xena", 200_000, 0).unwrap();
        // wren: 1 reserved + 1 held
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-w1".into()),
            "os-w-res",
            "wren",
            20_000,
            old,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-w2".into()),
            "os-w-held",
            "wren",
            30_000,
            old,
        )
        .unwrap();
        led.mark_start_authorized_fenced(old, "os-w-held", "wren")
            .unwrap();
        // xena: 1 held under old epoch (needs adopt after re-acquire)
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-x1".into()),
            "os-x-held",
            "xena",
            40_000,
            old,
        )
        .unwrap();
        led.mark_start_authorized_fenced(old, "os-x-held", "xena")
            .unwrap();
    }
    ownership.release();
    ownership.acquire(Epoch(old + 5)).unwrap();

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
    assert_eq!(v["orphan_summary"]["needs_adopt_count"], 3);
    assert_eq!(v["orphan_summary"]["reserved_not_started_count"], 1);
    assert_eq!(v["orphan_summary"]["held_start_authorized_count"], 2);
    let by = v["orphan_summary_by_account"].as_array().unwrap();
    assert_eq!(by.len(), 2);
    let wren = by.iter().find(|r| r["account"] == "wren").unwrap();
    assert_eq!(wren["needs_adopt_count"], 2);
    assert_eq!(wren["reserved_not_started_count"], 1);
    assert_eq!(wren["held_start_authorized_count"], 1);
    let xena = by.iter().find(|r| r["account"] == "xena").unwrap();
    assert_eq!(xena["needs_adopt_count"], 1);
    assert_eq!(xena["reserved_not_started_count"], 0);
    assert_eq!(xena["held_start_authorized_count"], 1);
}

#[tokio::test]
async fn deposit_vs_cutover_drain_abort_conserves_balance() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["dv-a", "dv-b"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                25_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, "pilot-account")
                .unwrap();
        }
    }
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..4 {
            let _ = box_.enqueue_critical(
                "inference.settled",
                &format!(r#"{{"job_id":"seed-{i}"}}"#),
            );
        }
    }
    let bal_start = state.ledger.lock().await.balance("pilot-account").0;

    let gate = ownership.clone();
    let seen = Arc::new(AtomicUsize::new(0));
    let seen2 = seen.clone();
    set_outbox_drain_entry_hook(Some(Arc::new(move |_kind| {
        if seen2.fetch_add(1, Ordering::SeqCst) == 0 {
            gate.release();
        }
    })));

    let app = Arc::new(router(state.clone()));
    let cutover_app = app.clone();
    let cutover = tokio::spawn(async move {
        let res = cutover_app
            .as_ref()
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/cutover-drain")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"actual_micro_usd":0}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        (res.status(), body_json(res).await)
    });

    let mut deposit_handles = Vec::new();
    for i in 0..6 {
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
                                "event_id": format!("dep-abort-{i}"),
                                "amount_micro_usd": 10_000,
                                "account": "pilot-account"
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            // May succeed (holding) or 503 (stolen mid-flight).
            let status = res.status();
            let v = body_json(res).await;
            (status, v)
        }));
    }

    let (cut_status, cut_body) = cutover.await.unwrap();
    set_outbox_drain_entry_hook(None);
    assert_eq!(cut_status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(cut_body["action"], "cutover_drain_aborted");
    assert_eq!(cut_body["phase"], "outbox_drain");
    // Jobs cleared regardless of drain abort.
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

    for h in deposit_handles {
        let _ = h.await.unwrap();
    }

    // Re-acquire, apply any deposits that failed due to ownership_lost, drain outbox.
    ownership.acquire(Epoch(epoch + 40)).unwrap();
    for i in 0..6 {
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
                            "event_id": format!("dep-abort-{i}"),
                            "amount_micro_usd": 10_000,
                            "account": "pilot-account"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
    }
    let res = app
        .as_ref()
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
    assert_eq!(res.status(), StatusCode::OK);

    // Start bal had 50k reserved; clear refunded → bal_start+50k; +6*10k deposits.
    let expected = bal_start + 50_000 + 60_000;
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        expected
    );
}
