//! Concurrent mark_start_authorized: exactly one winner.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mark_start_authorized_exactly_one_wins() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }
    let mut handles = Vec::new();
    for _ in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.mark_start_authorized("j", "a").is_ok()
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1);
    assert!(led.lock().unwrap().job_funded_start("j"));
}
