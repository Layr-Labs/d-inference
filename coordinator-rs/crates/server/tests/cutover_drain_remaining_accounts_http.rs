//! cutover-drain response includes remaining accounts_needing_cutover (DECISIONS #114).

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
async fn cutover_drain_response_lists_remaining_accounts() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("nova", 200_000, 0).unwrap();
        led.credit("opal", 200_000, 0).unwrap();
        for (id, acct) in [("cr-n1", "nova"), ("cr-o1", "opal"), ("cr-o2", "opal")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                30_000,
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
                    json!({ "account": "nova", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drained");
    assert_eq!(v["ready"], false);
    assert_eq!(v["accounts_needing_cutover"], json!(["opal"]));

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "opal", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert!(v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn cutover_drain_abort_includes_remaining_accounts() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("pax", 200_000, 0).unwrap();
        led.credit("quinn", 200_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-p1".into()),
            "ca-p1",
            "pax",
            25_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "ca-p1", "pax")
            .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-q1".into()),
            "ca-q1",
            "quinn",
            25_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "ca-q1", "quinn")
            .unwrap();
    }
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..3 {
            let _ = box_.enqueue_critical(
                "inference.settled",
                &format!(r#"{{"job_id":"seed-{i}"}}"#),
            );
        }
    }
    let gate = ownership.clone();
    let seen = Arc::new(AtomicUsize::new(0));
    let seen2 = seen.clone();
    set_outbox_drain_entry_hook(Some(Arc::new(move |_kind| {
        if seen2.fetch_add(1, Ordering::SeqCst) == 0 {
            gate.release();
        }
    })));

    let app = router(state.clone());
    // Clear only pax; quinn remains. Drain aborts mid-flight.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "account": "pax", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    set_outbox_drain_entry_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let abort = body_json(res).await;
    assert_eq!(abort["action"], "cutover_drain_aborted");
    assert_eq!(abort["accounts_needing_cutover"], json!(["quinn"]));
    assert_eq!(state.ledger.lock().await.balance("pax").0, 200_000);

    ownership.acquire(Epoch(epoch + 7)).unwrap();
}
