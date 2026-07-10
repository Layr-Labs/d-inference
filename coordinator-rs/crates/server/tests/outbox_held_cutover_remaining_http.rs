//! outbox-drain / held-review / cutover-drain return remaining accounts (DECISIONS #126).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_outbox_drain_hook_tests, router, set_outbox_drain_entry_hook, Epoch,
};
use serde_json::json;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tower::ServiceExt;

#[tokio::test]
async fn outbox_drain_success_lists_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("opal", 120_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-od1".into()),
            "od-1",
            "opal",
            40_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "od-1", "opal")
            .unwrap();
    }
    {
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_critical("inference.settled", r#"{"job_id":"od-1"}"#);
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "outbox_drained");
    assert_eq!(v["acked_count"], 1);
    assert_eq!(v["ready"], false); // held job remains
    assert_eq!(v["accounts_needing_cutover"], json!(["opal"]));
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["active_jobs"], 1);
}

#[tokio::test]
async fn outbox_drain_abort_lists_remaining_accounts() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("paul", 100_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-oda".into()),
            "oda-1",
            "paul",
            30_000,
            epoch,
        )
        .unwrap();
    }
    {
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_critical("inference.released", r#"{"a":1}"#);
        let _ = box_.enqueue_critical("inference.released", r#"{"a":2}"#);
    }

    let seen = Arc::new(AtomicUsize::new(0));
    let gate = ownership.clone();
    let seen_h = seen.clone();
    set_outbox_drain_entry_hook(Some(Arc::new(move |_kind| {
        if seen_h.fetch_add(1, Ordering::SeqCst) == 0 {
            gate.release();
        }
    })));

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    set_outbox_drain_entry_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    let action = v.get("action").cloned().unwrap_or(json!(null));
    let code = v
        .pointer("/error/code")
        .cloned()
        .unwrap_or(json!(null));
    assert!(
        action == json!("outbox_drain_aborted") || code == json!("ownership_lost"),
        "expected abort, got action={action} code={code} body={v}"
    );
    assert!(
        v.get("accounts_needing_cutover").is_some() || v.get("acked_count").is_some(),
        "abort should list remaining cutover fields: {v}"
    );
    if let Some(acked) = v.get("acked_count") {
        assert_eq!(acked, 1);
    }
    if let Some(accts) = v.get("accounts_needing_cutover") {
        assert_eq!(accts, &json!(["paul"]));
    }
    assert_eq!(v.get("ready").unwrap_or(&json!(false)), false);
}

#[tokio::test]
async fn held_review_batch_lists_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("quinn", 110_000, 0).unwrap();
        led.credit("rita", 110_000, 0).unwrap();
        for (id, acct) in [("hr-q1", "quinn"), ("hr-r1", "rita")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                35_000,
                old,
            )
            .unwrap();
            led.mark_start_authorized_fenced(old, id, acct).unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 5)).unwrap();

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review-batch")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["held_for_review_count"], 2);
    assert_eq!(v["needs_adopt_count"], 2);
    let mut accounts = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["quinn".to_string(), "rita".to_string()]);
}

#[tokio::test]
async fn cutover_drain_success_includes_needs_adopt() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("sam", 90_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cd1".into()),
            "cd-1",
            "sam",
            20_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "cd-1", "sam")
            .unwrap();
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "account": "sam" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drained");
    assert_eq!(v["ready"], true);
    assert_eq!(v["accounts_needing_cutover"], json!([]));
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(state.ledger.lock().await.balance("sam").0, 90_000);
}
