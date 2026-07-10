//! Concurrent mixed withdrawable deposits: totals and wdr both stack.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mixed_wdr_deposits_stack_provenance() {
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
            // Even i: pure non-wdr; odd i: half withdrawable.
            let (total, wdr) = if i % 2 == 0 {
                (20_000, 0)
            } else {
                (20_000, 10_000)
            };
            apply_stripe_deposit(
                inbox,
                led,
                "stripe",
                &format!("evt_mix_{i}"),
                "a",
                total,
                wdr,
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
    // 8 * 20k = 160k total; 4 odds * 10k = 40k wdr
    assert_eq!(g.1.balance("a"), (160_000, 40_000));
    assert_eq!(g.0.len(), 8);
}
