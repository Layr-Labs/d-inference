//! Ephemeral PostgreSQL harness for the ledger/recovery integration tests.
//!
//! Each test spins a REAL throwaway cluster with `initdb`/`pg_ctl` (on
//! PATH), listening on a unix socket in a short-lived directory — no TCP —
//! applies `fixtures/sql/legacy_baseline.sql` plus the real migrations, and
//! exercises the real pool. The [`TestDb`] guard stops the cluster
//! (`pg_ctl stop -m immediate`) and removes the directory on drop, panics
//! included. Tests skip with a clear message when `initdb` is absent.
//!
//! Included by several test crates (ledger, recovery, full-stack e2e), each
//! of which uses a subset of the helpers — hence the dead-code allowance.
#![allow(dead_code)]

use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::PgPool;

use darkbloom_server::ledger::Ledger;

static CLUSTER_SEQ: AtomicU64 = AtomicU64::new(0);

/// A running throwaway cluster plus a connected pool.
pub struct TestDb {
    pub pool: PgPool,
    /// sqlx-parsable URL over the unix socket (for `OwnershipGuard`).
    /// Unused by the ledger test crate, used by the recovery test crate.
    #[allow(dead_code)]
    pub url: String,
    cluster: Option<Cluster>,
}

struct Cluster {
    dir: PathBuf,
    data: PathBuf,
}

impl Drop for TestDb {
    fn drop(&mut self) {
        if let Some(cluster) = self.cluster.take() {
            // `-m immediate` force-disconnects the pool's connections;
            // panics included, the guard leaves nothing behind.
            let _ = Command::new("pg_ctl")
                .args(["-D"])
                .arg(&cluster.data)
                .args(["-m", "immediate", "-w", "stop"])
                .output();
            let _ = std::fs::remove_dir_all(&cluster.dir);
        }
    }
}

/// True when the PostgreSQL binaries are available. Callers skip (with a
/// message) when false.
pub fn pg_available() -> bool {
    Command::new("initdb")
        .arg("--version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

/// Prints the standard skip message. Usage:
/// `if !support::pg_available() { support::skip(); return; }`
pub fn skip() {
    eprintln!(
        "SKIPPED: initdb/pg_ctl not found on PATH — install PostgreSQL \
         (e.g. `brew install postgresql@16`) to run the ledger/recovery \
         integration tests"
    );
}

/// Boots a fresh cluster, applies the legacy baseline fixture and all
/// `rust_coord` migrations, and returns the connected harness.
pub async fn boot() -> TestDb {
    let seq = CLUSTER_SEQ.fetch_add(1, Ordering::Relaxed);
    // Short path: unix socket paths are limited to ~104 bytes on macOS.
    let dir = PathBuf::from(format!("/tmp/dbrs{}x{}", std::process::id(), seq));
    let data = dir.join("data");
    std::fs::create_dir_all(&data).expect("create cluster dir");

    let initdb = Command::new("initdb")
        .arg("-D")
        .arg(&data)
        .args(["-U", "postgres", "-A", "trust", "--no-sync", "-E", "UTF8"])
        .output()
        .expect("run initdb");
    assert!(
        initdb.status.success(),
        "initdb failed: {}",
        String::from_utf8_lossy(&initdb.stderr)
    );

    let socket_dir = dir.to_string_lossy().to_string();
    let start = Command::new("pg_ctl")
        .arg("-D")
        .arg(&data)
        .arg("-o")
        .arg(format!(
            "-c listen_addresses='' -c unix_socket_directories={socket_dir} \
             -c fsync=off -c synchronous_commit=off -c full_page_writes=off"
        ))
        .arg("-l")
        .arg(dir.join("pg.log"))
        .args(["-w", "start"])
        .output()
        .expect("run pg_ctl start");
    assert!(
        start.status.success(),
        "pg_ctl start failed: {}",
        String::from_utf8_lossy(&start.stderr)
    );

    let cluster = Cluster {
        dir: dir.clone(),
        data,
    };

    let options = PgConnectOptions::new()
        .host(&socket_dir)
        .username("postgres")
        .database("postgres");
    let pool = PgPoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await
        .expect("connect to ephemeral postgres");

    // Legacy Go tables first (test-only baseline), then the additive
    // rust_coord migrations — the production apply order.
    let baseline = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/sql/legacy_baseline.sql"),
    )
    .expect("read legacy_baseline.sql");
    sqlx::raw_sql(&baseline)
        .execute(&pool)
        .await
        .expect("apply legacy baseline");
    darkbloom_server::db::run_migrations(&pool)
        .await
        .expect("apply rust_coord migrations");

    let url = format!("postgres://postgres@localhost/postgres?host={socket_dir}");
    TestDb {
        pool,
        url,
        cluster: Some(cluster),
    }
}

/// Simulates ownership acquisition the smoke-test way: stamps the fencing
/// epoch directly (the `OwnershipGuard` path has its own dedicated test).
pub async fn set_epoch(pool: &PgPool, epoch: i64) {
    sqlx::query(
        "UPDATE rust_coord.coordinator_ownership \
         SET fencing_epoch = $1, holder = 'test', acquired_at = NOW(), renewed_at = NOW() \
         WHERE id = 1",
    )
    .bind(epoch)
    .execute(pool)
    .await
    .expect("stamp fencing epoch");
}

/// A ledger fencing on the given epoch.
pub fn ledger_at_epoch(pool: &PgPool, epoch: u64) -> Arc<Ledger> {
    Arc::new(Ledger::new(
        pool.clone(),
        "platform".to_owned(),
        Arc::new(AtomicU64::new(epoch)),
    ))
}

/// Seeds a consumer with smoke-shaped funds: `total - withdrawable` from a
/// deposit (total only) and `withdrawable` from an admin reward, with
/// matching ledger entries so `balance == SUM(ledger)` holds.
pub async fn seed_consumer(pool: &PgPool, account: &str, total: i64, withdrawable: i64) {
    assert!(withdrawable <= total);
    sqlx::query("INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ($1, $2, $3)")
        .bind(account)
        .bind(total)
        .bind(withdrawable)
        .execute(pool)
        .await
        .expect("seed balance");
    let deposit = total - withdrawable;
    if deposit > 0 {
        sqlx::query(
            "INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference) \
             VALUES ($1, 'deposit', $2, $2, 'seed_deposit')",
        )
        .bind(account)
        .bind(deposit)
        .execute(pool)
        .await
        .expect("seed deposit ledger");
    }
    if withdrawable > 0 {
        sqlx::query(
            "INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference) \
             VALUES ($1, 'admin_reward', $2, $3, 'seed_reward')",
        )
        .bind(account)
        .bind(withdrawable)
        .bind(total)
        .execute(pool)
        .await
        .expect("seed reward ledger");
    }
}

pub async fn balance_of(pool: &PgPool, account: &str) -> (i64, i64) {
    let row: Option<(i64, i64)> = sqlx::query_as(
        "SELECT balance_micro_usd, withdrawable_micro_usd FROM balances WHERE account_id = $1",
    )
    .bind(account)
    .fetch_optional(pool)
    .await
    .expect("read balance");
    row.unwrap_or((0, 0))
}

pub async fn job_state(pool: &PgPool, job: uuid::Uuid) -> String {
    let (state,): (String,) =
        sqlx::query_as("SELECT state FROM rust_coord.inference_jobs WHERE job_id = $1")
            .bind(job)
            .fetch_one(pool)
            .await
            .expect("read job state");
    state
}

pub async fn count(pool: &PgPool, sql: &str) -> i64 {
    let (n,): (i64,) = sqlx::query_as(sql)
        .fetch_one(pool)
        .await
        .expect("count query");
    n
}

/// The Go coordinator's own consistency invariant: every balance equals the
/// sum of its ledger entries.
pub async fn assert_ledger_consistent(pool: &PgPool) {
    let bad = count(
        pool,
        "SELECT COUNT(*) FROM balances b \
         WHERE b.balance_micro_usd <> COALESCE(( \
             SELECT SUM(l.amount_micro_usd) FROM ledger_entries l \
             WHERE l.account_id = b.account_id), 0)",
    )
    .await;
    assert_eq!(
        bad, 0,
        "balance != SUM(ledger_entries) for {bad} account(s)"
    );
}

// ---------------------------------------------------------------------------
// Shared money-flow builders (smoke_money_flow.sql shapes)
// ---------------------------------------------------------------------------

pub mod flows {
    use std::time::{SystemTime, UNIX_EPOCH};

    use darkbloom_core::ids::{
        AttemptId, CoordinatorEpoch, JobId, LeaseId, ProviderId, SessionEpoch,
    };
    use darkbloom_core::money::{MicroUsd, Tokens};
    use darkbloom_core::settlement::{
        FrozenReferral, FrozenTerms, MicroUsdPerMTokens, Ppm, PricingVersion, RoundingVersion,
    };
    use darkbloom_server::contracts::{
        LedgerFacade, ReserveParams, ResizeFreezeParams, SettleParams,
    };
    use darkbloom_server::ledger::Ledger;
    use uuid::Uuid;

    pub const CONSUMER: &str = "acct_consumer";
    pub const PROVIDER_BENEFICIARY: &str = "acct_provider";
    pub const REFERRER: &str = "acct_referrer";

    pub fn now_ms() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }

    /// Smoke-shaped frozen terms: 1200 billable input tokens at 1000 µUSD
    /// each + up to 1000 output tokens at 3500 µUSD each, so the full
    /// funded-bound charge (4,700,000) fits inside the 5,000,000 resize
    /// hold. At 800 completion tokens the charge is exactly 4,000,000 µUSD;
    /// the 850000-ppm payout rate makes the payout 3,400,000 and the
    /// 200000-ppm referral share carves 120,000 out of the 600,000 gross
    /// fee.
    pub fn terms(ledger: &Ledger) -> FrozenTerms {
        FrozenTerms {
            consumer_account: ledger.accounts().register(CONSUMER),
            api_key: darkbloom_core::ids::ApiKeyId::new("key_test1"),
            model: darkbloom_core::ids::ModelId::new("qwen3-30b-a3b-4bit"),
            public_model: darkbloom_core::ids::ModelId::new("qwen3-30b"),
            pricing_version: PricingVersion(1),
            rounding_version: RoundingVersion::CeilV1,
            billable_input_tokens: Tokens::new(1200),
            max_output_tokens: Tokens::new(1000),
            input_rate: MicroUsdPerMTokens::new(1_000_000_000).expect("rate"),
            output_rate: MicroUsdPerMTokens::new(3_500_000_000).expect("rate"),
            provider: ProviderId::new(Uuid::from_u128(0x70726f76)),
            provider_beneficiary: ledger.accounts().register(PROVIDER_BENEFICIARY),
            provider_payout_rate: Ppm::new(850_000).expect("ppm"),
            referral: Some(FrozenReferral {
                beneficiary: ledger.accounts().register(REFERRER),
                share: Ppm::new(200_000).expect("ppm"),
            }),
        }
    }

    pub fn reserve_params(ledger: &Ledger, job: JobId, hold: i64, tag: &str) -> ReserveParams {
        ReserveParams {
            operation_key: format!("op.reserve.{tag}"),
            job,
            account: ledger.accounts().register(CONSUMER),
            api_key: Some(darkbloom_core::ids::ApiKeyId::new("key_test1")),
            public_model: "qwen3-30b".to_owned(),
            concrete_model: "qwen3-30b-a3b-4bit".to_owned(),
            hold: MicroUsd::new(hold),
            spend_cap: None,
            first_content_deadline_ms: now_ms() + 30_000,
            request_deadline_ms: now_ms() + 120_000,
            coordinator_epoch: CoordinatorEpoch::new(1),
        }
    }

    pub fn resize_params(
        ledger: &Ledger,
        job: JobId,
        attempt: AttemptId,
        new_hold: i64,
        tag: &str,
    ) -> ResizeFreezeParams {
        let frozen = terms(ledger);
        ResizeFreezeParams {
            operation_key: format!("op.resize.{tag}"),
            job,
            attempt,
            new_hold: MicroUsd::new(new_hold),
            lease: LeaseId::new(Uuid::from_u128(0xe0e0)),
            provider: frozen.provider,
            frozen,
            session_epoch: SessionEpoch::new(1),
            dispatch_nonce: [0xD0; 16],
            request_digest: [0xD1; 32],
            coordinator_epoch: CoordinatorEpoch::new(1),
        }
    }

    pub fn settle_params(
        job: JobId,
        attempt: AttemptId,
        digest_seed: u8,
        completion_claimed: u64,
        accepted: u64,
        tag: &str,
    ) -> SettleParams {
        SettleParams {
            operation_key: format!("op.settle.{tag}"),
            job,
            attempt,
            terminal_digest: [digest_seed; 32],
            terminal_json: serde_json::json!({
                "outcome": "completed",
                "prompt_tokens": 1200,
                "completion_tokens": completion_claimed,
                "response_hash": "ab5e0001",
            }),
            prompt_tokens: 1200,
            completion_tokens_claimed: completion_claimed,
            accepted_sequence: 42,
            accepted_cumulative_tokens: accepted,
            origin_session_epoch: SessionEpoch::new(1),
            coordinator_epoch: CoordinatorEpoch::new(1),
        }
    }

    /// Drives reserve(7M) → resize+freeze(5M) → running for a smoke-shaped
    /// job. Returns the (job, attempt) identity.
    pub async fn funded_running_job(ledger: &Ledger, tag: &str) -> (JobId, AttemptId) {
        let job = JobId::new(Uuid::new_v4());
        let attempt = AttemptId::new(Uuid::new_v4());
        ledger
            .reserve(reserve_params(ledger, job, 7_000_000, tag))
            .await
            .expect("reserve");
        ledger
            .resize_freeze(resize_params(ledger, job, attempt, 5_000_000, tag))
            .await
            .expect("resize_freeze");
        ledger.mark_running(job).await.expect("mark_running");
        (job, attempt)
    }
}
