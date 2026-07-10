//! Shared harness for the full-stack `e2e_*` suites: an ephemeral
//! PostgreSQL cluster + the REAL bootstrap application on an ephemeral
//! port (re-exporting the `ledger_pg_support` and `session_support`
//! machinery), plus the seed data, HTTP/provider drivers, and DB money
//! assertions every scenario shares.
//!
//! Included by several test crates, each of which uses a subset of the
//! helpers — hence the dead-code allowance.

#![allow(dead_code)]

#[path = "../ledger_pg_support/mod.rs"]
pub mod pg;
#[path = "../session_support/mod.rs"]
pub mod session;

use std::net::SocketAddr;
use std::time::Duration;

use sqlx::PgPool;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::json_v1::EncryptedPayload;
use darkbloom_protocol::json_v2::FrameV2;
use darkbloom_server::bootstrap;
use darkbloom_server::config::Config;
use darkbloom_server::contracts::{FleetCommand, FleetHandle, FleetSnapshot};
use darkbloom_server::ledger::hash_key;

use session::FakeProvider;

pub const CONSUMER_ACCOUNT: &str = "acct_consumer";
pub const PROVIDER_ACCOUNT: &str = "acct_provider";
pub const POOR_ACCOUNT: &str = "acct_poor";
pub const CONSUMER_KEY: &str = "sk-e2e-consumer";
pub const POOR_KEY: &str = "sk-e2e-poor";
pub const PROVIDER_KEY: &str = "sk-e2e-provider";
pub const PUBLIC_MODEL: &str = "gemma-4";
pub const CONCRETE_MODEL: &str = "gemma-4-26b-4bit";
/// In the catalog but never served by any provider (capacity scenario).
pub const COLD_MODEL: &str = "cold-model";
pub const CONSUMER_SEED: i64 = 10_000_000;

/// "say hello to the world" = 22 content bytes → 22/4 = 5 estimated prompt
/// tokens; explicit max_tokens 64. At 2/5 µUSD per token the reserve hold
/// is 5*2 + 64*5 = 330 µUSD.
pub const PROMPT_TEXT: &str = "say hello to the world";
pub const RESERVE_HOLD: i64 = 330;

pub const RECV: Duration = Duration::from_secs(10);

// -----------------------------------------------------------------------
// Stack: ephemeral Postgres + the real bootstrap application
// -----------------------------------------------------------------------

pub struct Stack {
    pub db: pg::TestDb,
    pub addr: SocketAddr,
    pub fleet: FleetHandle,
    pub stop: CancellationToken,
    pub served: tokio::task::JoinHandle<anyhow::Result<()>>,
}

impl Stack {
    pub async fn boot() -> Stack {
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

    pub fn pool(&self) -> &PgPool {
        &self.db.pool
    }

    pub fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    pub async fn snapshot(&self) -> FleetSnapshot {
        let (tx, rx) = oneshot::channel();
        self.fleet
            .commands
            .send(FleetCommand::Snapshot { reply: tx })
            .await
            .expect("fleet alive");
        rx.await.expect("snapshot reply")
    }

    /// Waits until the model is warm on `n` routable providers.
    pub async fn wait_warm(&self, model: &str, n: usize) {
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
    pub async fn assert_quiescent(&self, allowed_review: &[Uuid]) {
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

    pub async fn shutdown(self) {
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
pub async fn seed(pool: &PgPool) {
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

pub fn chat_body(model: &str, stream: bool) -> serde_json::Value {
    serde_json::json!({
        "model": model,
        "messages": [{"role": "user", "content": PROMPT_TEXT}],
        "stream": stream,
        "max_tokens": 64,
    })
}

pub async fn send_chat(stack: &Stack, key: &str, model: &str, stream: bool) -> reqwest::Response {
    reqwest::Client::new()
        .post(stack.url("/v1/chat/completions"))
        .bearer_auth(key)
        .json(&chat_body(model, stream))
        .send()
        .await
        .expect("http send")
}

pub fn job_id_of(response: &reqwest::Response) -> Uuid {
    response
        .headers()
        .get("x-inference-job-id")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| Uuid::parse_str(v).ok())
        .expect("x-inference-job-id header")
}

pub async fn read_full_body(mut response: reqwest::Response) -> String {
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
pub fn content_chunk(text: &str) -> String {
    format!(
        r#"{{"id":"chatcmpl-e2e","object":"chat.completion.chunk","model":"{CONCRETE_MODEL}","choices":[{{"delta":{{"content":"{text}"}},"finish_reason":null}}]}}"#
    )
}

/// Connects, registers (v1/v2 + auth token), and warms the model.
pub async fn connect_provider(stack: &Stack, serial: &str, v2: bool) -> FakeProvider {
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
pub fn open_v1_request(
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

pub async fn send_v1_chunk(
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

pub async fn wait_job_state(pool: &PgPool, job: Uuid, want: &str) {
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

pub struct SettleFacts {
    pub charged: i64,
    pub refunded: i64,
    pub provider_payout: i64,
}

pub async fn settle_facts(pool: &PgPool, job: Uuid) -> SettleFacts {
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
pub async fn assert_settled_money(
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
