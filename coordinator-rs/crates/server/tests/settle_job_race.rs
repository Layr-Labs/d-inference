//! Concurrent settle of the same job: exactly one winner.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_same_job_exactly_one_wins() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }
    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Distinct op keys; same job + same digest → first wins, rest conflict/idempotent.
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                400_000,
                "shared-digest",
            )
            .map(|applied| applied)
            .unwrap_or(false)
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1, "exactly one settle must apply");
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // reserved 1M, charged 400k → refund 600k → bal = 10M-1M+600k = 9.6M
    assert_eq!(g.balance("a").0, 9_600_000);
}

#[test]
fn concurrent_settle_distinct_digests_second_is_noop() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }
    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            // Distinct digests; job disposition after first settle makes the rest noops.
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                400_000,
                &format!("digest-{i}"),
            )
            .map(|applied| applied)
            .unwrap_or(false)
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1, "disposition gate allows only one settle");
    assert_eq!(led.lock().unwrap().balance("a").0, 9_600_000);
}
