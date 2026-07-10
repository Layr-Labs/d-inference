//! Concurrent credit zero-withdrawable deposits stack totals only.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_zero_wdr_deposits_stack_totals() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));

    let mut handles = Vec::new();
    for i in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, led) = &mut *g;
            apply_stripe_deposit(
                inbox,
                led,
                "stripe",
                &format!("evt_zw_{i}"),
                "a",
                10_000,
                0,
            )
            .map(|applied| applied)
            .unwrap_or(false)
        }));
    }

    let mut applied = 0usize;
    for h in handles {
        if h.join().unwrap() {
            applied += 1;
        }
    }
    assert_eq!(applied, 8);
    let g = state.lock().unwrap();
    assert_eq!(g.1.balance("a"), (80_000, 0));
    assert_eq!(g.0.len(), 8);
}
