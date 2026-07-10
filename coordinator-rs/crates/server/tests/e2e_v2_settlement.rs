//! Full-stack e2e (real Postgres + real bootstrap app, fake provider):
//! a v2 provider runs prepare/prepared/start/started/binary chunks/
//! terminal/ack and settles exactly, then a second job whose terminal
//! over-claims parks in review with no money moved.
//!
//! Skipped (with a message) when `initdb`/`pg_ctl` are not on PATH.

#[path = "e2e_support/mod.rs"]
mod support;

use bytes::Bytes;

use darkbloom_protocol::binary::{self, BinaryFrameHeader, FrameKind};
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::json_v2::{
    ExecutionFacts, FrameV2, PreparedFrame, RequestScope, ResourceFacts, RollingHashCheckpoint,
    TerminalFrame, TerminalOutcome, TerminalUsage,
};

use support::pg;
use support::session::FakeProvider;
use support::*;

// -----------------------------------------------------------------------
// (b) v2 provider: prepare/prepared/start/started/binary chunks/terminal/
//     ack — then a second job whose terminal over-claims and parks review
// -----------------------------------------------------------------------

struct V2Turn {
    scope: RequestScope,
    /// SHA-256 of the sealed prepare body (the wire request digest).
    request_digest: [u8; 32],
}

/// Drives one full v2 provider turn up to `started`, streaming
/// `chunk_count` content chunks of one token each.
async fn v2_serve_turn(
    provider: &mut FakeProvider,
    coordinator_pub: &nacl_box::PublicKey,
    chunk_count: u64,
) -> V2Turn {
    // prepare arrives as JSON control + binary body on one socket.
    let prepare_json = provider.next_text().await;
    let prepare = match FrameV2::decode(prepare_json.as_bytes()).expect("decode prepare") {
        FrameV2::Prepare(p) => p,
        other => panic!("expected prepare, got {}", other.type_str()),
    };
    assert_eq!(prepare.model_id, CONCRETE_MODEL);
    let body_frame = provider.next_binary().await;
    let (body_header, ciphertext) =
        binary::decode(&Bytes::from(body_frame), 32 * 1024 * 1024).expect("decode body");
    assert_eq!(body_header.kind, FrameKind::PrepareBody);
    let plain = nacl_box::open_bytes(&ciphertext, coordinator_pub, &provider.x25519_secret)
        .expect("decrypt prepare body");
    let body: serde_json::Value = serde_json::from_slice(&plain).expect("body json");
    assert_eq!(body["model"], CONCRETE_MODEL);
    let request_digest = prepare.scope.request_digest.0;

    // prepared: exact billable input of 6 tokens, honest fast ETA.
    let lease = darkbloom_protocol::json_v2::LeaseId([0xAB; 16]);
    let scope = RequestScope {
        lease_id: Some(lease),
        ..prepare.scope
    };
    let prepared = FrameV2::Prepared(PreparedFrame {
        scope,
        ttl_ms: 30_000,
        billable_input_tokens: 6,
        resource: ResourceFacts::default(),
        execution: ExecutionFacts {
            engine_queue_depth: 0,
            prefill_can_start: true,
            predicted_first_content_ms: Some(30),
        },
    });
    provider
        .send_json(&serde_json::from_slice(&prepared.encode().expect("encode")).expect("json"))
        .await;

    // start → started.
    let start_json = provider.next_text().await;
    match FrameV2::decode(start_json.as_bytes()).expect("decode start") {
        FrameV2::Start(start) => assert_eq!(start.scope.lease_id, Some(lease)),
        other => panic!("expected start, got {}", other.type_str()),
    }
    provider
        .send_json(
            &serde_json::from_slice(
                &FrameV2::Started(darkbloom_protocol::json_v2::StartedFrame { scope })
                    .encode()
                    .expect("encode"),
            )
            .expect("json"),
        )
        .await;

    // Binary content chunks sealed to the coordinator identity key.
    for i in 1..=chunk_count {
        let plaintext = content_chunk(&format!("tok{i}"));
        let mut nonce = [0u8; nacl_box::NONCE_LEN];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
        let sealed = nacl_box::seal_bytes(
            plaintext.as_bytes(),
            &nonce,
            coordinator_pub,
            &provider.x25519_secret,
        )
        .expect("seal chunk");
        let header = BinaryFrameHeader {
            kind: FrameKind::ResponseChunk,
            job_id: scope.job_id,
            attempt_id: scope.attempt_id,
            lease_id: scope.lease_id,
            session_epoch: scope.session_epoch,
            coordinator_epoch: scope.coordinator_epoch,
            dispatch_nonce: scope.dispatch_nonce,
            request_digest: scope.request_digest,
            sequence: i,
            cumulative_completion_tokens: i,
        };
        provider
            .send_binary(
                binary::encode(&header, &sealed)
                    .expect("encode chunk")
                    .to_vec(),
            )
            .await;
    }
    V2Turn {
        scope,
        request_digest,
    }
}

async fn v2_send_terminal(provider: &mut FakeProvider, turn: &V2Turn, claimed_completion: u64) {
    // Signed with the provider's SE key — the session verifies terminals
    // against the attested key before intake (plan §12.6 step 3).
    let terminal = FrameV2::Terminal(provider.sign_terminal(TerminalFrame {
        scope: turn.scope,
        provider_id: "e2e-v2".to_owned(),
        model_id: CONCRETE_MODEL.to_owned(),
        origin_session_epoch: turn.scope.session_epoch,
        outcome: TerminalOutcome::Completed,
        error_class: None,
        usage: TerminalUsage {
            prompt_tokens: 6,
            completion_tokens: claimed_completion,
            reasoning_tokens: 0,
        },
        generated_tokens: claimed_completion,
        response_hash: darkbloom_protocol::json_v2::ResponseHash([0x0E; 32]),
        checkpoint: RollingHashCheckpoint {
            sequence: claimed_completion,
            cumulative_completion_tokens: claimed_completion,
            rolling_hash: darkbloom_protocol::json_v2::ResponseHash([0x0F; 32]),
        },
        se_signature: String::new(),
    }));
    provider
        .send_json(&serde_json::from_slice(&terminal.encode().expect("encode")).expect("json"))
        .await;
}

#[tokio::test]
async fn v2_full_stack_settles_then_overclaim_parks_review() {
    if !pg::pg_available() {
        pg::skip();
        return;
    }
    let stack = Stack::boot().await;

    // The coordinator's real identity key, from the public endpoint.
    let key_info: serde_json::Value = reqwest::get(stack.url("/v1/encryption-key"))
        .await
        .expect("encryption-key")
        .json()
        .await
        .expect("key json");
    let coordinator_pub =
        nacl_box::parse_public_key(key_info["public_key"].as_str().expect("public_key"))
            .expect("coordinator key");

    let mut provider = connect_provider(&stack, "E2E-V2", true).await;
    stack.wait_warm(CONCRETE_MODEL, 1).await;

    // --- (b1) honest terminal: exact settlement --------------------------
    let script = tokio::spawn(async move {
        let turn = v2_serve_turn(&mut provider, &coordinator_pub, 2).await;
        v2_send_terminal(&mut provider, &turn, 2).await;
        // ACK arrives only after the durable settle (plan §12.8).
        let ack_json = provider.next_text().await;
        match FrameV2::decode(ack_json.as_bytes()).expect("decode ack") {
            FrameV2::TerminalAck(ack) => {
                assert_eq!(
                    ack.disposition,
                    darkbloom_protocol::json_v2::AckDisposition::Recorded
                );
            }
            other => panic!("expected terminal_ack, got {}", other.type_str()),
        }
        (provider, coordinator_pub, turn.request_digest)
    });

    let response = send_chat(&stack, CONSUMER_KEY, PUBLIC_MODEL, true).await;
    assert_eq!(response.status(), 200);
    let job1 = job_id_of(&response);
    let body = read_full_body(response).await;
    assert!(body.contains("tok1") && body.contains("tok2"));
    assert!(body.ends_with("data: [DONE]\n\n"));

    let (mut provider, coordinator_pub, request_digest) = script.await.expect("v2 script");

    // charge = ceil(6*2) + ceil(2*5) = 22; payout 17; fee 5; hold was
    // resized to 6*2 + 64*5 = 332.
    wait_job_state(stack.pool(), job1, "settled").await;
    assert_settled_money(stack.pool(), job1, 22, 332, 17, 5).await;
    let balance_after_b1 = CONSUMER_SEED - 22;
    assert_eq!(
        pg::balance_of(stack.pool(), CONSUMER_ACCOUNT).await,
        (balance_after_b1, 0)
    );

    // Real fencing identity on the durable rows (no placeholders): the
    // attempt row carries session epoch 1 and the wire request digest; the
    // receipt row carries the origin session epoch.
    let (attempt_epoch, stored_digest): (i64, Vec<u8>) = sqlx::query_as(
        "SELECT session_epoch, request_digest FROM rust_coord.inference_attempts \
         WHERE job_id = $1",
    )
    .bind(job1)
    .fetch_one(stack.pool())
    .await
    .expect("attempt row");
    assert_eq!(
        attempt_epoch, 1,
        "real session epoch, not the 0 placeholder"
    );
    assert_eq!(
        stored_digest,
        request_digest.to_vec(),
        "wire request digest"
    );
    let (origin_epoch, disposition): (i64, String) = sqlx::query_as(
        "SELECT t.origin_session_epoch, t.disposition FROM rust_coord.provider_terminals t \
         JOIN rust_coord.inference_attempts a ON a.attempt_id = t.attempt_id \
         WHERE a.job_id = $1",
    )
    .bind(job1)
    .fetch_one(stack.pool())
    .await
    .expect("receipt row");
    assert_eq!(origin_epoch, 1);
    assert_eq!(disposition, "settled");

    // --- (b2) over-claiming terminal: capped at the checkpoint → review --
    let script = tokio::spawn(async move {
        let turn = v2_serve_turn(&mut provider, &coordinator_pub, 2).await;
        // Claims 50 completion tokens; only 2 chunks were accepted.
        v2_send_terminal(&mut provider, &turn, 50).await;
        let ack_json = provider.next_text().await;
        match FrameV2::decode(ack_json.as_bytes()).expect("decode ack") {
            FrameV2::TerminalAck(_) => {}
            other => panic!("expected terminal_ack, got {}", other.type_str()),
        }
        provider
    });

    let response = send_chat(&stack, CONSUMER_KEY, PUBLIC_MODEL, true).await;
    assert_eq!(response.status(), 200);
    let job2 = job_id_of(&response);
    let _ = read_full_body(response).await;
    let _provider = script.await.expect("v2 overclaim script");

    // Plan §13.6/§9.3.8: the claim exceeds the accepted checkpoint — the
    // job parks in review_pending, NO money moves, the reservation stays
    // debited, and the receipt records the review disposition.
    wait_job_state(stack.pool(), job2, "review_pending").await;
    let (error_class,): (Option<String>,) =
        sqlx::query_as("SELECT error_class FROM rust_coord.inference_jobs WHERE job_id = $1")
            .bind(job2)
            .fetch_one(stack.pool())
            .await
            .expect("job row");
    assert!(
        error_class
            .as_deref()
            .is_some_and(|c| c.contains("CompletionExceedsAcceptedCheckpoint")),
        "review reason records the checkpoint cap: {error_class:?}"
    );
    assert_eq!(
        pg::balance_of(stack.pool(), CONSUMER_ACCOUNT).await,
        (balance_after_b1 - 332, 0),
        "reservation retained pending review"
    );
    let settle_ops = pg::count(
        stack.pool(),
        &format!(
            "SELECT COUNT(*) FROM rust_coord.financial_operations \
             WHERE job_id = '{job2}' AND kind = 'settle'"
        ),
    )
    .await;
    assert_eq!(settle_ops, 0, "no settle operation recorded");
    let (disposition,): (String,) = sqlx::query_as(
        "SELECT t.disposition FROM rust_coord.provider_terminals t \
         JOIN rust_coord.inference_attempts a ON a.attempt_id = t.attempt_id \
         WHERE a.job_id = $1",
    )
    .bind(job2)
    .fetch_one(stack.pool())
    .await
    .expect("receipt row");
    assert_eq!(disposition, "review_pending");

    stack.assert_quiescent(&[job2]).await;
    stack.shutdown().await;
}
