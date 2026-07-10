//! Concurrent MemoryLedger.settle with digest conflict across jobs.

use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_digest_conflict_across_jobs() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r0".into()), "j0", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j0", "a").unwrap();
        g.reserve(OperationKey("r1".into()), "j1", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j1", "a").unwrap();
    }

    let led0 = led.clone();
    let t0 = thread::spawn(move || {
        let mut g = led0.lock().unwrap();
        match g.settle(OperationKey("s0".into()), "j0", "a", 100_000, "shared-d") {
            Ok(true) => "applied",
            Ok(false) => "noop",
            Err(LedgerError::Conflict(_)) => "conflict",
            Err(e) => panic!("unexpected {e}"),
        }
    });
    let led1 = led.clone();
    let t1 = thread::spawn(move || {
        let mut g = led1.lock().unwrap();
        match g.settle(OperationKey("s1".into()), "j1", "a", 100_000, "shared-d") {
            Ok(true) => "applied",
            Ok(false) => "noop",
            Err(LedgerError::Conflict(_)) => "conflict",
            Err(e) => panic!("unexpected {e}"),
        }
    });

    let a0 = t0.join().unwrap();
    let a1 = t1.join().unwrap();
    let applied0 = a0 == "applied";
    let applied1 = a1 == "applied";
    assert!(
        applied0 ^ applied1,
        "exactly one shared digest apply; a0={a0} a1={a1}"
    );
    let g = led.lock().unwrap();
    // Winner settled; loser still held
    assert_eq!(g.active_job_count(), 1);
    assert_eq!(g.held_start_authorized_count(), 1);
    // 10M - 2M + 900k refund = 8.9M
    assert_eq!(g.balance("a").0, 8_900_000);
}
