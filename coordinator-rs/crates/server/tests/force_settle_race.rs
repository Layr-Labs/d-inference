//! Concurrent force_settle_held: exactly one winner.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_held_exactly_one_wins() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }
    let mut handles = Vec::new();
    for i in 0..16 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(
                &led,
                "j",
                "a",
                400_000,
                &format!("force-d-{i}"),
            )
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
        }));
    }
    let wins: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
    assert_eq!(g.balance("a").0, 9_600_000);
}
