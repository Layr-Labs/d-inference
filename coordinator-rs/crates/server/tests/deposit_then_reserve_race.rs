//! Concurrent apply_stripe_deposit then reserve: deposit funds enable reserve.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn deposit_then_concurrent_reserve_uses_new_funds() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    // Empty account — deposit first, then race reserves.
    {
        let mut g = state.lock().unwrap();
        let (inbox, ledger) = &mut *g;
        assert!(apply_stripe_deposit(
            inbox, ledger, "stripe", "fund", "a", 2_000_000, 0
        )
        .unwrap());
    }

    let mut handles = Vec::new();
    for i in 0..4 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            g.1.reserve(
                OperationKey(format!("r-{i}")),
                &format!("j-{i}"),
                "a",
                700_000,
            )
            .map(|r| r.applied)
            .unwrap_or(false)
        }));
    }

    let wins: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|w| *w)
        .count();
    // 2M / 700k = 2
    assert_eq!(wins, 2);
    let g = state.lock().unwrap();
    assert_eq!(g.1.active_job_count(), 2);
    assert_eq!(g.1.balance("a").0, 600_000);
}
