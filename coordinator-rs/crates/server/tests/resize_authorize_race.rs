//! Concurrent resize_and_authorize: exactly one winner funds start.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_resize_and_authorize_exactly_one_wins() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.resize_and_authorize(
                OperationKey(format!("ra-{i}")),
                "j",
                "a",
                1_500_000,
            )
            .map(|r| r.applied)
            .unwrap_or(false)
        }));
    }

    let wins: usize = handles.into_iter().filter_map(|h| h.join().ok()).filter(|w| *w).count();
    assert_eq!(wins, 1, "exactly one resize_and_authorize must apply");
    let g = led.lock().unwrap();
    assert!(g.job_funded_start("j"));
    assert_eq!(g.held_start_authorized_count(), 1);
    assert_eq!(g.job_reserved_total("j").unwrap().0, 1_500_000);
    // 10M - 1M - 0.5M = 8.5M
    assert_eq!(g.balance("a").0, 8_500_000);
}

#[test]
fn concurrent_resize_same_op_key_is_idempotent() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.resize_and_authorize(OperationKey("ra-same".into()), "j", "a", 1_200_000)
                .map(|r| r.applied)
                .unwrap_or(false)
        }));
    }

    let wins: usize = handles.into_iter().filter_map(|h| h.join().ok()).filter(|w| *w).count();
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert_eq!(g.balance("a").0, 8_800_000);
}
