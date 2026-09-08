//! Concurrency regression tests for the reserve transaction's spend-cap
//! fence (plan §12.5): N simultaneous reserves against one per-key cap must
//! never over-admit. Without the advisory-lock leg in
//! `ledger::reserve` this admits more than the cap (write skew: every
//! statement's cap aggregate reads a snapshot that predates the concurrent
//! commits). Skips cleanly when `initdb` is not on PATH.

use std::sync::Arc;

use uuid::Uuid;

use darkbloom_core::ids::{ApiKeyId, JobId};
use darkbloom_core::money::MicroUsd;
use darkbloom_server::contracts::{LedgerError, LedgerFacade};

use crate::support::pg;
use crate::support::pg::flows;

/// Eight concurrent reserves per round against a cap that admits exactly
/// four: the admitted count must be exactly four in EVERY round, and the
/// durable job rows must agree.
#[tokio::test]
async fn concurrent_reserves_never_exceed_spend_cap() {
    if !pg::pg_available() {
        pg::skip();
        return;
    }
    let db = pg::boot().await;
    pg::set_epoch(&db.pool, 1).await;
    // Deep funds so ONLY the cap can reject.
    pg::seed_consumer(&db.pool, flows::CONSUMER, 1_000_000_000, 0).await;
    let ledger = pg::ledger_at_epoch(&db.pool, 1);

    const ROUNDS: usize = 3;
    const CONCURRENCY: usize = 8;
    const HOLD: i64 = 1_000_000;
    // Cap admits exactly 4 holds: pass requires cap >= hold + active-sum,
    // so admissions 1..=4 see active sums 0..=3 * HOLD and the 5th fails.
    const CAP: i64 = 4 * HOLD;

    for round in 0..ROUNDS {
        // A distinct key per round keeps rounds independent.
        let key = format!("key_cap_round_{round}");
        let mut tasks = tokio::task::JoinSet::new();
        for i in 0..CONCURRENCY {
            let ledger = Arc::clone(&ledger);
            let key = key.clone();
            let tag = format!("cap.r{round}.{i}");
            tasks.spawn(async move {
                let mut params =
                    flows::reserve_params(&ledger, JobId::new(Uuid::new_v4()), HOLD, &tag);
                params.spend_cap = Some(MicroUsd::new(CAP));
                params.api_key = Some(ApiKeyId::new(key));
                ledger.reserve(params).await
            });
        }

        let (mut admitted, mut capped) = (0usize, 0usize);
        while let Some(result) = tasks.join_next().await {
            match result.expect("reserve task join") {
                Ok(_) => admitted += 1,
                Err(LedgerError::SpendCapExceeded) => capped += 1,
                Err(other) => panic!("round {round}: unexpected reserve error: {other}"),
            }
        }
        assert_eq!(
            admitted, 4,
            "round {round}: the cap admits exactly 4 concurrent reserves"
        );
        assert_eq!(
            capped,
            CONCURRENCY - 4,
            "round {round}: the rest are capped"
        );

        // The database agrees: exactly 4 active reservations on this key,
        // whose holds sum to exactly the cap.
        let jobs = pg::count(
            &db.pool,
            &format!("SELECT COUNT(*) FROM rust_coord.inference_jobs WHERE api_key_id = '{key}'"),
        )
        .await;
        assert_eq!(jobs, 4, "round {round}: durable job rows match admissions");
        let reserved = pg::count(
            &db.pool,
            &format!(
                "SELECT COALESCE(SUM(reserved_total_micro_usd), 0)::BIGINT \
                 FROM rust_coord.inference_jobs WHERE api_key_id = '{key}'"
            ),
        )
        .await;
        assert_eq!(
            reserved, CAP,
            "round {round}: reserved sum never exceeds the cap"
        );
    }

    pg::assert_ledger_consistent(&db.pool).await;
}
