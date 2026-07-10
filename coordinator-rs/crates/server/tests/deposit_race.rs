//! Concurrent apply_stripe_deposit: exactly one credit for the same event.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_same_event_credits_exactly_once() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    let mut handles = Vec::new();
    for _ in 0..16 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, ledger) = &mut *g;
            apply_stripe_deposit(
                inbox,
                ledger,
                "stripe",
                "evt_same",
                "a",
                1_000_000,
                500_000,
            )
            .unwrap()
        }));
    }
    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    assert_eq!(wins, 1);
    let g = state.lock().unwrap();
    assert_eq!(g.1.balance("a"), (1_000_000, 500_000));
}
