//! Concurrent apply_stripe_deposit with distinct event ids: credits stack.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_distinct_deposits_stack_credits() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    let mut handles = Vec::new();
    for i in 0..16 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, ledger) = &mut *g;
            apply_stripe_deposit(
                inbox,
                ledger,
                "stripe",
                &format!("evt-{i}"),
                "a",
                1_000,
                100,
            )
            .unwrap()
        }));
    }
    let applied: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|a| *a)
        .count();
    assert_eq!(applied, 16);
    let g = state.lock().unwrap();
    assert_eq!(g.0.len(), 16);
    assert_eq!(g.1.balance("a"), (16_000, 1_600));
}
