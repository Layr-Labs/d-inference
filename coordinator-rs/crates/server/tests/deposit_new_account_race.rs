//! Concurrent deposit on missing account: credit creates balance (UPSERT semantics).

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_creates_account_exactly_once_per_event() {
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
                "evt_new_acct",
                "brand-new",
                500_000,
                100_000,
            )
            .map(|applied| (i, applied))
            .unwrap_or((i, false))
        }));
    }

    let mut applied = 0usize;
    for h in handles {
        if h.join().unwrap().1 {
            applied += 1;
        }
    }
    assert_eq!(applied, 1);
    let g = state.lock().unwrap();
    assert_eq!(g.1.balance("brand-new"), (500_000, 100_000));
    assert_eq!(g.0.len(), 1);
}
