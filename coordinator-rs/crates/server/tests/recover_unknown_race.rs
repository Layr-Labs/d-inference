//! Concurrent recover_undispatched on unknown job: AlreadyTerminal.

use darkbloom_coordinator::ledger::MemoryLedger;
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_recover_undispatched_unknown_already_terminal() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            recover_undispatched(&led, "missing", "a").unwrap()
        }));
    }

    for h in handles {
        assert_eq!(h.join().unwrap(), RecoveryAction::AlreadyTerminal);
    }
}
