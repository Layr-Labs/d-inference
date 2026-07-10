//! Concurrent invalid deposits must never credit or consume event ids.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_invalid_deposits_leave_inbox_and_balance_clean() {
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
            // Mix of invalid shapes — all must fail without observe.
            let (total, wdr) = match i % 3 {
                0 => (-1, 0),
                1 => (0, 0),
                _ => (100, 200),
            };
            apply_stripe_deposit(
                inbox,
                ledger,
                "stripe",
                &format!("bad-{i}"),
                "a",
                total,
                wdr,
            )
            .is_err()
        }));
    }

    let fails: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|f| *f)
        .count();
    assert_eq!(fails, 16);
    {
        let g = state.lock().unwrap();
        assert_eq!(g.0.len(), 0);
        assert_eq!(g.1.balance("a").0, 0);
    }

    // Valid deposit still works afterward with a previously-failed event id shape.
    {
        let mut g = state.lock().unwrap();
        let (inbox, ledger) = &mut *g;
        assert!(apply_stripe_deposit(inbox, ledger, "stripe", "bad-0", "a", 50, 10).unwrap());
        assert_eq!(ledger.balance("a"), (50, 10));
    }
}
