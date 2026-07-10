//! Concurrent MemoryLedger.held_start_authorized_count readers during force.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_held_count_readers_during_force_settle() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
        assert_eq!(g.held_start_authorized_count(), 1);
    }

    let led_r = led.clone();
    let readers: Vec<_> = (0..8)
        .map(|_| {
            let led = led_r.clone();
            thread::spawn(move || {
                let g = led.lock().unwrap();
                g.held_start_authorized_count()
            })
        })
        .collect();

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 100_000, "hc-d")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    assert!(force.join().unwrap());
    for h in readers {
        let c = h.join().unwrap();
        assert!(c == 0 || c == 1, "count={c}");
    }
    assert_eq!(led.lock().unwrap().held_start_authorized_count(), 0);
}
