//! Concurrent MemoryLedger.settle then force_settle on different jobs.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_and_force_on_distinct_jobs() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r0".into()), "j0", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j0").unwrap();
        g.reserve(OperationKey("r1".into()), "j1", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j1").unwrap();
    }

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle(OperationKey("s0".into()), "j0", "a", 300_000, "d0")
            .unwrap()
    });
    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j1", "a", 200_000, "d1")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    assert!(settle.join().unwrap());
    assert!(force.join().unwrap());
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
    // 10M - 2M + (1M-300k) + (1M-200k) = 10M - 2M + 700k + 800k = 9.5M
    assert_eq!(g.balance("a").0, 9_500_000);
}
