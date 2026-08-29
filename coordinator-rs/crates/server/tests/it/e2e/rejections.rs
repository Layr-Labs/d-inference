//! Full-stack e2e (real Postgres + real bootstrap app, fake providers):
//! failure paths — 402 before any provider frame, 429 capacity with
//! Retry-After, and pre-content provider errors taking one invisible
//! alternate before releasing the reservation in full.
//!
//! Skipped (with a message) when `initdb`/`pg_ctl` are not on PATH.

use uuid::Uuid;

use crate::support::e2e::*;
use crate::support::pg;
use crate::support::session::FakeProvider;

// -----------------------------------------------------------------------
// (c) failure paths: 402 before any provider frame, 429 capacity,
//     pre-content provider errors with one invisible alternate → released
// -----------------------------------------------------------------------

#[tokio::test]
async fn insufficient_funds_and_capacity_and_precontent_failover() {
    if !pg::pg_available() {
        pg::skip();
        return;
    }
    let stack = Stack::boot().await;
    let provider_a = connect_provider(&stack, "E2E-FAIL-A", false).await;
    let provider_b = connect_provider(&stack, "E2E-FAIL-B", false).await;
    stack.wait_warm(CONCRETE_MODEL, 2).await;

    // (c1) Insufficient funds: 402 BEFORE any provider frame or job row.
    let response = send_chat(&stack, POOR_KEY, PUBLIC_MODEL, true).await;
    assert_eq!(response.status(), 402);
    let jobs = pg::count(
        stack.pool(),
        "SELECT COUNT(*) FROM rust_coord.inference_jobs",
    )
    .await;
    assert_eq!(jobs, 0, "reserve failed → no job row");
    assert_eq!(
        pg::balance_of(stack.pool(), POOR_ACCOUNT).await,
        (5, 0),
        "nothing debited"
    );

    // (c2) Capacity: the cold model has no provider → fast 429 with
    // Retry-After; the reservation is released. (Error responses carry no
    // job-id header, so the job is found by its model.)
    let response = send_chat(&stack, CONSUMER_KEY, COLD_MODEL, true).await;
    assert_eq!(response.status(), 429);
    assert!(
        response.headers().get("retry-after").is_some(),
        "429 carries Retry-After"
    );
    let (cold_job,): (Uuid,) =
        sqlx::query_as("SELECT job_id FROM rust_coord.inference_jobs WHERE public_model = $1")
            .bind(COLD_MODEL)
            .fetch_one(stack.pool())
            .await
            .expect("cold-model job row");
    wait_job_state(stack.pool(), cold_job, "released").await;
    assert_eq!(
        pg::balance_of(stack.pool(), CONSUMER_ACCOUNT).await,
        (CONSUMER_SEED, 0),
        "released reservation restored exactly"
    );

    // (c3) Both providers fail pre-content (5xx): the first failure takes
    // ONE invisible alternate, the second fails the request → 503 and the
    // job releases in full. Routing order between the two near-tie
    // candidates is random, so each provider runs its own script.
    let fail_script = |mut provider: FakeProvider| {
        tokio::spawn(async move {
            let frame = provider.next_json().await;
            assert_eq!(frame["type"], "inference_request");
            let request_id = frame["request_id"].as_str().expect("request_id").to_owned();
            provider
                .send_json(&serde_json::json!({
                    "type": "inference_error",
                    "request_id": request_id,
                    "error": "engine exploded",
                    "status_code": 500,
                }))
                .await;
            request_id
        })
    };
    let script_a = fail_script(provider_a);
    let script_b = fail_script(provider_b);
    let response = send_chat(&stack, CONSUMER_KEY, PUBLIC_MODEL, true).await;
    assert_eq!(
        response.status(),
        503,
        "pre-content failures stay invisible"
    );
    let (failed_job,): (Uuid,) =
        sqlx::query_as("SELECT job_id FROM rust_coord.inference_jobs WHERE public_model = $1")
            .bind(PUBLIC_MODEL)
            .fetch_one(stack.pool())
            .await
            .expect("failed job row");
    let served_a = script_a.await.expect("provider A script");
    let served_b = script_b.await.expect("provider B script");
    assert_ne!(served_a, served_b, "alternate is a distinct attempt");
    wait_job_state(stack.pool(), failed_job, "released").await;
    assert_eq!(
        pg::balance_of(stack.pool(), CONSUMER_ACCOUNT).await,
        (CONSUMER_SEED, 0),
        "full refund on release"
    );

    stack.assert_quiescent(&[]).await;
    stack.shutdown().await;
}
