//! Full-stack end-to-end tests: REAL everything except the provider.
//!
//! Each test boots an ephemeral PostgreSQL cluster (legacy baseline +
//! migrations, via the shared `ledger_pg_support` harness), seeds accounts /
//! API keys / catalog prices, builds the application with the SAME
//! `bootstrap::build` wiring the `coordinator-rs serve` binary uses (axum on
//! an ephemeral port, real ownership, real ledger, real fleet actor, real
//! provider WebSocket sessions), and drives it with:
//!
//! - a real HTTP client (reqwest) authenticating with a database-seeded
//!   API key, and
//! - a fake Swift provider (the shared `session_support` machinery) speaking
//!   genuine v1/v2 JSON + binary frames over a real WebSocket, doing real
//!   NaCl decryption/encryption.
//!
//! Every scenario ends by asserting THE DATABASE (rust_coord + legacy
//! tables): job disposition, exact consumer debit and reservation refund,
//! provider earning, fee allocations, ledger projections — plus no leaked
//! fleet permits and no stuck jobs.
//!
//! Skipped (with a message) when `initdb`/`pg_ctl` are not on PATH.

#[path = "ledger_pg_support/mod.rs"]
mod pg;
#[path = "session_support/mod.rs"]
mod session;

use std::net::SocketAddr;
use std::time::Duration;

use bytes::Bytes;
use sqlx::PgPool;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use darkbloom_protocol::binary::{self, BinaryFrameHeader, FrameKind};
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::json_v1::EncryptedPayload;
use darkbloom_protocol::json_v2::{
    ExecutionFacts, FrameV2, PreparedFrame, RequestScope, ResourceFacts, RollingHashCheckpoint,
    TerminalFrame, TerminalOutcome, TerminalUsage,
};
use darkbloom_server::bootstrap;
use darkbloom_server::config::Config;
use darkbloom_server::contracts::{FleetCommand, FleetHandle, FleetSnapshot};
use darkbloom_server::ledger::hash_key;

use session::FakeProvider;

const CONSUMER_ACCOUNT: &str = "acct_consumer";
const PROVIDER_ACCOUNT: &str = "acct_provider";
const POOR_ACCOUNT: &str = "acct_poor";
const CONSUMER_KEY: &str = "sk-e2e-consumer";
const POOR_KEY: &str = "sk-e2e-poor";
const PROVIDER_KEY: &str = "sk-e2e-provider";
const PUBLIC_MODEL: &str = "gemma-4";
const CONCRETE_MODEL: &str = "gemma-4-26b-4bit";
/// In the catalog but never served by any provider (capacity scenario).
const COLD_MODEL: &str = "cold-model";
const CONSUMER_SEED: i64 = 10_000_000;

/// "say hello to the world" = 22 content bytes → 22/4 = 5 estimated prompt
/// tokens; explicit max_tokens 64. At 2/5 µUSD per token the reserve hold
/// is 5*2 + 64*5 = 330 µUSD.
const PROMPT_TEXT: &str = "say hello to the world";
const RESERVE_HOLD: i64 = 330;

const RECV: Duration = Duration::from_secs(10);

// -----------------------------------------------------------------------
// Stack: ephemeral Postgres + the real bootstrap application
// -----------------------------------------------------------------------

struct Stack {
    db: pg::TestDb,
    addr: SocketAddr,
    fleet: FleetHandle,
    stop: CancellationToken,
    served: tokio::task::JoinHandle<anyhow::Result<()>>,
}

impl Stack {
    async fn boot() -> Stack {
        // Opt-in coordinator logs while debugging: DARKBLOOM_E2E_LOG=debug.
        if let Ok(filter) = std::env::var("DARKBLOOM_E2E_LOG") {
            let _ = tracing_subscriber::fmt()
                .with_env_filter(filter)
                .with_test_writer()
                .try_init();
        }
        let db = pg::boot().await;
        seed(&db.pool).await;
        let app = bootstrap::build(Config::for_tests(&db.url))
            .await
            .expect("bootstrap::build");
        let addr = app.local_addr().expect("bound addr");
        let fleet = app.fleet_handle();
        let stop = CancellationToken::new();
        let signal = {
            let stop = stop.clone();
            async move { stop.cancelled().await }
        };
        let served = tokio::spawn(app.serve(signal));
        Stack {
            db,
            addr,
            fleet,
            stop,
            served,
        }
    }

    fn pool(&self) -> &PgPool {
        &self.db.pool
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    async fn snapshot(&self) -> FleetSnapshot {
        let (tx, rx) = oneshot::channel();
        self.fleet
            .commands
            .send(FleetCommand::Snapshot { reply: tx })
            .await
            .expect("fleet alive");
        rx.await.expect("snapshot reply")
    }

    /// Waits until the model is warm on `n` routable providers.
    async fn wait_warm(&self, model: &str, n: usize) {
        let deadline = tokio::time::Instant::now() + RECV;
        loop {
            let snapshot = self.snapshot().await;
            if snapshot.warm_by_model.get(model).copied().unwrap_or(0) >= n
                && snapshot.routable >= n
            {
                return;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "model {model} never became warm on {n} providers: {snapshot:?}"
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    /// End-of-scenario invariants: no leaked permits, no stuck jobs (every
    /// rust_coord job in a terminal state, `allowed_review` excepted).
    async fn assert_quiescent(&self, allowed_review: &[Uuid]) {
        let deadline = tokio::time::Instant::now() + RECV;
        loop {
            if self.snapshot().await.permits_outstanding == 0 {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "fleet permits leaked: {:?}",
                self.snapshot().await
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        let rows: Vec<(Uuid, String)> =
            sqlx::query_as("SELECT job_id, state FROM rust_coord.inference_jobs")
                .fetch_all(self.pool())
                .await
                .expect("jobs");
        for (job, state) in rows {
            if allowed_review.contains(&job) {
                assert_eq!(state, "review_pending", "flagged job {job}");
                continue;
            }
            assert!(
                matches!(
                    state.as_str(),
                    "settled" | "settled_reviewed" | "released" | "released_reviewed"
                ),
                "job {job} stuck in nonterminal state '{state}'"
            );
        }
        pg::assert_ledger_consistent(self.pool()).await;
    }

    async fn shutdown(self) {
        self.stop.cancel();
        self.served
            .await
            .expect("serve task")
            .expect("clean serve exit");
        drop(self.db);
    }
}

/// Legacy-table seed: consumer balances, API keys (consumer auth + the
/// provider's registration auth token), and catalog models/prices.
async fn seed(pool: &PgPool) {
    pg::seed_consumer(pool, CONSUMER_ACCOUNT, CONSUMER_SEED, 0).await;
    pg::seed_consumer(pool, POOR_ACCOUNT, 5, 0).await;

    for (key, owner, id) in [
        (CONSUMER_KEY, CONSUMER_ACCOUNT, "key-e2e-consumer"),
        (POOR_KEY, POOR_ACCOUNT, "key-e2e-poor"),
        (PROVIDER_KEY, PROVIDER_ACCOUNT, "key-e2e-provider"),
    ] {
        sqlx::query(
            "INSERT INTO api_keys (key_hash, raw_prefix, owner_account_id, active, id) \
             VALUES ($1, 'sk-e2e', $2, TRUE, $3)",
        )
        .bind(hash_key(key))
        .bind(owner)
        .bind(id)
        .execute(pool)
        .await
        .expect("seed api key");
    }

    for model in [CONCRETE_MODEL, COLD_MODEL] {
        sqlx::query("INSERT INTO model_registry (id, display_name) VALUES ($1, $1)")
            .bind(model)
            .execute(pool)
            .await
            .expect("seed model");
    }
    sqlx::query(
        "INSERT INTO model_aliases (alias_id, display_name, active, desired_build) \
         VALUES ($1, $1, TRUE, $2)",
    )
    .bind(PUBLIC_MODEL)
    .bind(CONCRETE_MODEL)
    .execute(pool)
    .await
    .expect("seed alias");
    // 2 µUSD per prompt token / 5 µUSD per completion token, per-MTok.
    for model in [CONCRETE_MODEL, COLD_MODEL] {
        sqlx::query(
            "INSERT INTO model_prices (account_id, model, input_price, output_price) \
             VALUES ('platform', $1, 2000000, 5000000)",
        )
        .bind(model)
        .execute(pool)
        .await
        .expect("seed price");
    }
}

// -----------------------------------------------------------------------
// HTTP + provider helpers
// -----------------------------------------------------------------------

fn chat_body(model: &str, stream: bool) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": PROMPT_TEXT}],
        "stream": stream,
        "max_tokens": 64,
    })
}

async fn send_chat(stack: &Stack, key: &str, model: &str, stream: bool) -> reqwest::Response {
    reqwest::Client::new()
        .post(stack.url("/v1/chat/completions"))
        .bearer_auth(key)
        .json(&chat_body(model, stream))
        .send()
        .await
        .expect("http send")
}

fn job_id_of(response: &reqwest::Response) -> Uuid {
    response
        .headers()
        .get("x-inference-job-id")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| Uuid::parse_str(v).ok())
        .expect("x-inference-job-id header")
}

async fn read_full_body(mut response: reqwest::Response) -> String {
    let mut buf = Vec::new();
    loop {
        match tokio::time::timeout(RECV, response.chunk()).await {
            Ok(Ok(Some(chunk))) => buf.extend_from_slice(&chunk),
            Ok(Ok(None)) => break,
            Ok(Err(err)) => panic!("body read error: {err}"),
            Err(_) => panic!("timed out reading response body"),
        }
    }
    String::from_utf8(buf).expect("utf8 body")
}

/// One provider-visible SSE content chunk (concrete model id, as a real
/// provider emits it).
fn content_chunk(text: &str) -> String {
    format!(
        r#"{{"id":"chatcmpl-e2e","object":"chat.completion.chunk","model":"{CONCRETE_MODEL}","choices":[{{"delta":{{"content":"{text}"}},"finish_reason":null}}]}}"#
    )
}

/// Connects, registers (v1/v2 + auth token), and warms the model.
async fn connect_provider(stack: &Stack, serial: &str, v2: bool) -> FakeProvider {
    let mut provider = FakeProvider::connect_addr(stack.addr, serial).await;
    provider.model = CONCRETE_MODEL.to_owned();
    provider.auth_token = PROVIDER_KEY.to_owned();
    provider.establish(v2).await;
    if v2 {
        let ready = FrameV2::ModelReady(darkbloom_protocol::json_v2::ModelReadyFrame {
            model_id: CONCRETE_MODEL.to_owned(),
            state_revision: 1,
        });
        provider
            .send_json(&serde_json::from_slice(&ready.encode().expect("encode")).expect("json"))
            .await;
    } else {
        provider.send_heartbeat(CONCRETE_MODEL, "idle").await;
    }
    provider
}

/// Decrypts a v1 `inference_request` and returns (request_id, session
/// public key b64, plaintext body).
fn open_v1_request(
    provider: &FakeProvider,
    frame: &serde_json::Value,
) -> (String, String, Vec<u8>) {
    assert_eq!(frame["type"], "inference_request");
    let request_id = frame["request_id"].as_str().expect("request_id").to_owned();
    let payload = EncryptedPayload {
        ephemeral_public_key: frame["encrypted_body"]["ephemeral_public_key"]
            .as_str()
            .expect("session key")
            .to_owned(),
        ciphertext: frame["encrypted_body"]["ciphertext"]
            .as_str()
            .expect("ciphertext")
            .to_owned(),
    };
    let plain = nacl_box::open(&payload, &provider.x25519_secret).expect("decrypt request body");
    (request_id, payload.ephemeral_public_key, plain)
}

async fn send_v1_chunk(
    provider: &mut FakeProvider,
    request_id: &str,
    session_pub: &str,
    text: &str,
) {
    let plaintext = format!("data: {}", content_chunk(text));
    let session_key = nacl_box::parse_public_key(session_pub).expect("session pub");
    let sealed = nacl_box::seal(plaintext.as_bytes(), &session_key, &provider.x25519_secret)
        .expect("seal chunk");
    provider
        .send_json(&serde_json::json!({
            "type": "inference_response_chunk",
            "request_id": request_id,
            "encrypted_data": {
                "ephemeral_public_key": sealed.ephemeral_public_key,
                "ciphertext": sealed.ciphertext,
            },
        }))
        .await;
}

// -----------------------------------------------------------------------
// DB assertion helpers
// -----------------------------------------------------------------------

async fn wait_job_state(pool: &PgPool, job: Uuid, want: &str) {
    let deadline = tokio::time::Instant::now() + RECV;
    loop {
        let state = pg::job_state(pool, job).await;
        if state == want {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "job {job} is '{state}', wanted '{want}'"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

struct SettleFacts {
    charged: i64,
    refunded: i64,
    provider_payout: i64,
}

async fn settle_facts(pool: &PgPool, job: Uuid) -> SettleFacts {
    let (result,): (serde_json::Value,) = sqlx::query_as(
        "SELECT result FROM rust_coord.financial_operations \
         WHERE job_id = $1 AND kind = 'settle'",
    )
    .bind(job)
    .fetch_one(pool)
    .await
    .expect("settle operation row");
    let get = |k: &str| {
        result
            .get(k)
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(-1)
    };
    SettleFacts {
        charged: get("charged"),
        refunded: get("refunded"),
        provider_payout: get("provider_payout"),
    }
}

/// Asserts the complete money trail of one settled job: settle-op amounts,
/// fee allocation, provider earning, usage projection, and the refund
/// ledger entry.
async fn assert_settled_money(
    pool: &PgPool,
    job: Uuid,
    charged: i64,
    hold: i64,
    payout: i64,
    fee: i64,
) {
    let facts = settle_facts(pool, job).await;
    assert_eq!(facts.charged, charged, "charged");
    assert_eq!(facts.refunded, hold - charged, "reservation refund exact");
    assert_eq!(facts.provider_payout, payout, "provider payout");

    let (fee_beneficiary, fee_amount): (String, i64) = sqlx::query_as(
        "SELECT beneficiary_account_id, amount_micro_usd \
         FROM rust_coord.fee_allocations WHERE job_id = $1 AND kind = 'platform'",
    )
    .bind(job)
    .fetch_one(pool)
    .await
    .expect("platform fee row");
    assert_eq!(fee_beneficiary, "platform");
    assert_eq!(fee_amount, fee, "platform fee = charge - payout");
    assert_eq!(charged, payout + fee, "split conserves the charge");

    let (earning_account, earning_amount): (String, i64) = sqlx::query_as(
        "SELECT account_id, amount_micro_usd FROM provider_earnings WHERE job_id = $1",
    )
    .bind(job.to_string())
    .fetch_one(pool)
    .await
    .expect("provider earning row");
    assert_eq!(earning_account, PROVIDER_ACCOUNT);
    assert_eq!(earning_amount, payout);

    let (usage_cost,): (i64,) =
        sqlx::query_as("SELECT cost_micro_usd FROM usage WHERE request_id = $1")
            .bind(job.to_string())
            .fetch_one(pool)
            .await
            .expect("usage row");
    assert_eq!(usage_cost, charged);

    let (refund_entries,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM ledger_entries \
         WHERE reference = $1 AND entry_type = 'refund' AND amount_micro_usd = $2",
    )
    .bind(job.to_string())
    .bind(hold - charged)
    .fetch_one(pool)
    .await
    .expect("refund ledger entry");
    assert_eq!(refund_entries, 1, "exactly one exact refund entry");
}

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

// -----------------------------------------------------------------------
// (d) cancellation: client disconnects mid-stream → provider receives the
//     cancel frame → v1 partial settles within the bounded wait
// -----------------------------------------------------------------------

#[tokio::test]
async fn client_disconnect_cancels_provider_and_settles_partial() {
    if !pg::pg_available() {
        pg::skip();
        return;
    }
    let stack = Stack::boot().await;
    let mut provider = connect_provider(&stack, "E2E-CANCEL", false).await;
    stack.wait_warm(CONCRETE_MODEL, 1).await;

    let script = tokio::spawn(async move {
        let frame = provider.next_json().await;
        let (request_id, session_pub, _) = open_v1_request(&provider, &frame);
        send_v1_chunk(&mut provider, &request_id, &session_pub, "partial").await;

        // The client disconnect must surface as a cancel frame.
        let cancel = provider.next_json().await;
        assert_eq!(cancel["type"], "cancel", "provider receives cancel");
        assert_eq!(cancel["request_id"], request_id.as_str());

        // Authenticated partial usage: exactly the one accepted chunk.
        provider
            .send_json(&serde_json::json!({
                "type": "inference_complete",
                "request_id": request_id,
                "usage": {"prompt_tokens": 12, "completion_tokens": 1},
                "response_hash": "partial-hash",
            }))
            .await;
    });

    let mut response = send_chat(&stack, CONSUMER_KEY, PUBLIC_MODEL, true).await;
    assert_eq!(response.status(), 200);
    let job = job_id_of(&response);
    // Read the first streamed chunk, then vanish mid-stream.
    let first = tokio::time::timeout(RECV, response.chunk())
        .await
        .expect("first chunk in time")
        .expect("chunk read")
        .expect("stream open");
    assert!(String::from_utf8_lossy(&first).contains("partial"));
    drop(response);

    script.await.expect("cancel script");

    // Settles partial within the bounded wait: charge = 5*2 + 1*5 = 15.
    wait_job_state(stack.pool(), job, "settled").await;
    let (accepted,): (i64,) = sqlx::query_as(
        "SELECT accepted_cumulative_tokens FROM rust_coord.inference_jobs WHERE job_id = $1",
    )
    .bind(job)
    .fetch_one(stack.pool())
    .await
    .expect("job row");
    assert_eq!(accepted, 1, "cancelled stream caps at the accepted chunk");
    assert_settled_money(stack.pool(), job, 15, RESERVE_HOLD, 12, 3).await;
    assert_eq!(
        pg::balance_of(stack.pool(), CONSUMER_ACCOUNT).await,
        (CONSUMER_SEED - 15, 0)
    );

    stack.assert_quiescent(&[]).await;
    stack.shutdown().await;
}
