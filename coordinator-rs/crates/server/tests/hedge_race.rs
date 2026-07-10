//! Concurrent hedge race: both prepares succeed; only one start_authorized.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_hedge_only_one_start_authorized() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("acct", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "job-1", "acct", 100_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.mark_start_authorized("job-1").is_ok()
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1, "exactly one start_authorized must win");
    assert!(led.lock().unwrap().job_funded_start("job-1"));
}
