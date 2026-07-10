//! Full-stack e2e (real Postgres + real bootstrap app, fake provider):
//! a v1 provider serves a full paid streaming round trip and the database
//! settles exactly — money trail, terminal receipt, quiescence.
//!
//! Skipped (with a message) when `initdb`/`pg_ctl` are not on PATH.

#[path = "e2e_support/mod.rs"]
mod support;

use support::pg;
use support::*;

// -----------------------------------------------------------------------
// (a) v1 provider: full paid streaming round trip settles exactly
// -----------------------------------------------------------------------

#[tokio::test]
async fn v1_full_stack_streaming_settles_exactly() {
    if !pg::pg_available() {
        pg::skip();
        return;
    }
    let stack = Stack::boot().await;
    let mut provider = connect_provider(&stack, "E2E-V1", false).await;
    stack.wait_warm(CONCRETE_MODEL, 1).await;

    let script = tokio::spawn(async move {
        let frame = provider.next_json().await;
        let (request_id, session_pub, plain) = open_v1_request(&provider, &frame);
        let body: serde_json::Value = serde_json::from_slice(&plain).expect("body json");
        assert_eq!(
            body["model"], CONCRETE_MODEL,
            "provider sees concrete build"
        );
        assert_eq!(body["max_tokens"], 64, "bound injection");

        provider
            .send_json(&serde_json::json!({
                "type": "inference_accepted", "request_id": request_id,
            }))
            .await;
        for text in ["Hello", " world"] {
            send_v1_chunk(&mut provider, &request_id, &session_pub, text).await;
        }
        // Claims MORE completion tokens than chunks: the intact stream
        // promotes the checkpoint (Go parity), so 7 is billable.
        provider
            .send_json(&serde_json::json!({
                "type": "inference_complete",
                "request_id": request_id,
                "usage": {"prompt_tokens": 12, "completion_tokens": 7},
                "se_signature": "sig-e2e",
                "response_hash": "hash-e2e",
            }))
            .await;
        provider
    });

    let response = send_chat(&stack, CONSUMER_KEY, PUBLIC_MODEL, true).await;
    assert_eq!(response.status(), 200);
    let job = job_id_of(&response);
    let body = read_full_body(response).await;
    assert!(body.contains("Hello"), "first chunk relayed");
    assert!(
        body.contains(&format!("\"model\":\"{PUBLIC_MODEL}\"")),
        "model rewritten to the public alias"
    );
    assert!(body.contains("\"completion_tokens\":7"), "usage chunk");
    assert!(body.ends_with("data: [DONE]\n\n"), "single DONE terminator");

    let _provider = script.await.expect("provider script");

    // THE DATABASE: settled with the exact money trail.
    // charge = 5 (frozen estimate) * 2 + 7 * 5 = 45; payout = 36; fee = 9.
    wait_job_state(stack.pool(), job, "settled").await;
    let (outcome, billed_prompt, billed_completion, accepted): (String, i64, i64, i64) =
        sqlx::query_as(
            "SELECT outcome, usage_prompt_tokens, usage_completion_tokens, \
                    accepted_cumulative_tokens \
             FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(job)
        .fetch_one(stack.pool())
        .await
        .expect("job row");
    assert_eq!(outcome, "completed");
    assert_eq!(billed_prompt, 5, "v1 bills the frozen estimate");
    assert_eq!(billed_completion, 7, "checkpoint promoted to the claim");
    assert_eq!(accepted, 7);

    assert_settled_money(stack.pool(), job, 45, RESERVE_HOLD, 36, 9).await;
    assert_eq!(
        pg::balance_of(stack.pool(), CONSUMER_ACCOUNT).await,
        (CONSUMER_SEED - 45, 0),
        "consumer debited exactly the charge"
    );
    assert_eq!(
        pg::balance_of(stack.pool(), PROVIDER_ACCOUNT).await,
        (36, 36),
        "provider earning credited, withdrawable"
    );
    let (receipt_disposition,): (String,) = sqlx::query_as(
        "SELECT t.disposition FROM rust_coord.provider_terminals t \
         JOIN rust_coord.inference_attempts a ON a.attempt_id = t.attempt_id \
         WHERE a.job_id = $1",
    )
    .bind(job)
    .fetch_one(stack.pool())
    .await
    .expect("terminal receipt");
    assert_eq!(receipt_disposition, "settled");

    stack.assert_quiescent(&[]).await;
    stack.shutdown().await;
}
