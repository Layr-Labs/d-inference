//! Deposit + terminal-ingest return remaining cutover accounts (DECISIONS #129).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn deposit_returns_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("jade", 80_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dep1".into()),
            "dep-j1",
            "jade",
            20_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "dep-j1", "jade")
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
                        "event_id": "evt-dep-rem-1",
                        "account": "jade",
                        "amount_micro_usd": 15_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["applied"], true);
    assert_eq!(v["balance_micro_usd"], 75_000); // 80k-20k reserved +15k
    assert_eq!(v["accounts_needing_cutover"], json!(["jade"]));
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(v["outbox_retryable"], 1); // deposit outbox entry
}

#[tokio::test]
async fn deposit_then_cutover_using_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("kyle", 90_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dep2".into()),
            "dep-k1",
            "kyle",
            30_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "dep-k1", "kyle")
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
                        "event_id": "evt-dep-rem-2",
                        "account": "kyle",
                        "amount_micro_usd": 10_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let accounts = body_json(res).await["accounts_needing_cutover"].clone();
    assert_eq!(accounts, json!(["kyle"]));

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
    // Start 90k, reserve 30k → 60k, deposit +10k → 70k, force-settle refund 30k → 100k.
    assert_eq!(state.ledger.lock().await.balance("kyle").0, 100_000);
}

#[tokio::test]
async fn terminal_ingest_returns_remaining_accounts() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("lena", 110_000, 0).unwrap();
        led.credit("mark", 110_000, 0).unwrap();
        for (id, acct) in [("ti-l1", "lena"), ("ti-m1", "mark")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                25_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }
    // Force-settle lena so ingest can ACK the disposition.
    {
        let mut led = state.ledger.lock().await;
        darkbloom_coordinator::force_settle_held_on(
            &mut led,
            epoch,
            "ti-l1",
            "lena",
            0,
            "force-settle:ti-l1",
        )
        .unwrap();
    }
    {
        let mut terms = state.terminals.lock().await;
        let ack = json!({
            "type": "terminal_ack",
            "job_id": "ti-l1",
            "attempt_id": "force-settle",
            "lease_id": "",
            "terminal_digest": "force-settle:ti-l1",
            "disposition": "force_settled",
        });
        terms.record_bound(
            "ti-l1",
            "force-settle",
            "force-settle:ti-l1",
            "force_settled",
            Some(ack),
            "",
            "",
        );
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/terminal-ingest")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "ti-l1",
                        "attempt_id": "force-settle",
                        "terminal_digest": "force-settle:ti-l1",
                        "lease_id": "",
                        "se_signature": "",
                        "outcome": "completed"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["disposition"], "force_settled");
    assert_eq!(v["accounts_needing_cutover"], json!(["mark"]));
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["held_start_authorized"], 1);
}
