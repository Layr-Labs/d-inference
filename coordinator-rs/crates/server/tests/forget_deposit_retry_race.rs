//! Concurrent MemoryLedger.forget then observe then deposit apply.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_forget_observe_deposit_retry() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        assert!(g.0.observe("stripe", "retry-evt").unwrap());
        assert!(g.0.forget("stripe", "retry-evt"));
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, ledger) = &mut *g;
            apply_stripe_deposit(
                inbox,
                ledger,
                "stripe",
                "retry-evt",
                "a",
                1_000_000,
                100_000,
            )
            .map(|a| a)
            .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 1);
    let g = state.lock().unwrap();
    assert_eq!(g.0.len(), 1);
    assert_eq!(g.1.balance("a"), (1_000_000, 100_000));
}
