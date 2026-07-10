//! Concurrent MemoryLedger.CLI-style deposit demo path under race.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_cli_style_deposit_demo_idempotent() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, ledger) = &mut *g;
            // Mirror CLI demo: apply then replay
            let first = apply_stripe_deposit(
                inbox,
                ledger,
                "stripe",
                "cli-demo-evt",
                "pilot-account",
                250_000,
                50_000,
            )
            .unwrap();
            let second = apply_stripe_deposit(
                inbox,
                ledger,
                "stripe",
                "cli-demo-evt",
                "pilot-account",
                250_000,
                50_000,
            )
            .unwrap();
            (first, second)
        }));
    }

    let mut first_wins = 0usize;
    for h in handles {
        let (first, second) = h.join().unwrap();
        assert!(!second, "replay must never apply");
        if first {
            first_wins += 1;
        }
    }
    assert_eq!(first_wins, 1);
    let g = state.lock().unwrap();
    assert_eq!(g.1.balance("pilot-account"), (250_000, 50_000));
    assert_eq!(g.0.len(), 1);
}
