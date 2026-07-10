//! Concurrent MemoryLedger.CLI undispatched recover demo path under race.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_cli_style_undispatched_recover_demo() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        g.credit("pilot-account", 1_000_000, 0).unwrap();
        g.reserve(
            OperationKey("reserve:undisp".into()),
            "undisp-job",
            "pilot-account",
            100_000,
        )
        .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_undispatched(&led, "undisp-job", "pilot-account").unwrap()
        }));
    }

    let mut released = 0usize;
    let mut already = 0usize;
    for h in handles {
        match h.join().unwrap() {
            RecoveryAction::Released => released += 1,
            RecoveryAction::AlreadyTerminal => already += 1,
            other => panic!("unexpected {other:?}"),
        }
    }
    assert_eq!(released, 1);
    assert_eq!(already, 7);
    assert_eq!(led.lock().unwrap().balance("pilot-account").0, 1_000_000);
    assert_eq!(led.lock().unwrap().active_job_count(), 0);
}
