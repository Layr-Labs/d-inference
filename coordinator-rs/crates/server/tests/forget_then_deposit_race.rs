//! Concurrent forget after observe before credit: retry can still apply.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_manual_forget_then_deposit_retry_applies_once() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));

    // Simulate crash between observe and credit: observe then forget.
    {
        let mut g = state.lock().unwrap();
        assert!(g.0.observe("stripe", "evt_crash").unwrap());
        assert!(g.0.forget("stripe", "evt_crash"));
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, led) = &mut *g;
            apply_stripe_deposit(inbox, led, "stripe", "evt_crash", "a", 100_000, 20_000)
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
    assert_eq!(applied, 1);
    let g = state.lock().unwrap();
    assert_eq!(g.1.balance("a"), (100_000, 20_000));
    assert!(g.0.contains("stripe", "evt_crash"));
}
