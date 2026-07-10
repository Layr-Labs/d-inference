//! Concurrent MemoryLedger.CLI force_settle demo path under race.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_cli_style_force_settle_demo() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("pilot-account", 1_000_000, 0).unwrap();
        g.reserve(OperationKey("reserve:demo".into()), "demo-job", "pilot-account", 100_000)
            .unwrap();
        g.mark_start_authorized("demo-job", "pilot-account").unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            force_settle_held(&led, "demo-job", "pilot-account", 40_000, "force-demo-d")
                .map(|a| a == RecoveryAction::Released)
                .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 1);
    assert_eq!(led.lock().unwrap().balance("pilot-account").0, 960_000);
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
