//! Admin paths share CutoverStatus snapshots (DECISIONS #131).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn force_settle_and_held_review_share_cutover_status_shape() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("rita", 180_000, 0).unwrap();
        led.credit("sam", 180_000, 0).unwrap();
        for (id, acct) in [("cs-r1", "rita"), ("cs-s1", "sam")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                35_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }

    let app = router(state.clone());

    let review = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/held-review")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "cs-r1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(review.status(), StatusCode::OK);
    let rv = body_json(review).await;
    assert_eq!(rv["needs_adopt_count"], 0);
    assert_eq!(rv["held_start_authorized"], 2);
    let mut accounts = rv["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["rita".to_string(), "sam".to_string()]);

    let settle = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_id": "cs-r1", "actual_micro_usd": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(settle.status(), StatusCode::OK);
    let sv = body_json(settle).await;
    assert_eq!(sv["accounts_needing_cutover"], json!(["sam"]));
    assert_eq!(sv["needs_adopt_count"], 0);
    assert_eq!(sv["held_start_authorized"], 1);

    let batch = app
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
    let bv = body_json(batch).await;
    assert_eq!(bv["accounts_needing_cutover"], json!(["sam"]));
    assert_eq!(bv["held_start_authorized"], 1);
    assert_eq!(bv["needs_adopt_count"], 0);
}

#[tokio::test]
async fn cancel_and_outbox_drain_report_consistent_remaining() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("tess", 100_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cs-t".into()),
            "cs-t1",
            "tess",
            20_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "cs-t1", "tess")
            .unwrap();
    }
    {
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_critical("inference.settled", r#"{"job":"cs-t1"}"#);
    }

    let app = router(state.clone());
    let cancel = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-attempt")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "cs-t1",
                        "attempt_id": "a1",
                        "lease_id": "l1",
                        "provider_id": "p1",
                        "dispatch_nonce": "n1",
                        "request_digest": "sha256:x"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let cv = body_json(cancel).await;
    assert_eq!(cv["accounts_needing_cutover"], json!(["tess"]));
    assert_eq!(cv["held_start_authorized"], 1);

    let drain = app
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
    let dv = body_json(drain).await;
    assert_eq!(dv["ready"], false);
    assert_eq!(dv["accounts_needing_cutover"], json!(["tess"]));
    assert_eq!(dv["needs_adopt_count"], 0);
    assert_eq!(dv["active_jobs"], 1);
}
