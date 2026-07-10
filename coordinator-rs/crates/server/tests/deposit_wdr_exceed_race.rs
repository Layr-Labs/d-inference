//! Concurrent apply_stripe_deposit with wdr > total: Conflict.

use darkbloom_coordinator::deposits::{apply_stripe_deposit, DepositError};
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_wdr_exceeds_total_all_conflict() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));

    let mut handles = Vec::new();
    for i in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, ledger) = &mut *g;
            matches!(
                apply_stripe_deposit(
                    inbox,
                    ledger,
                    "stripe",
                    &format!("wt{i}"),
                    "a",
                    100,
                    200,
                ),
                Err(DepositError::Ledger(LedgerError::Conflict(_)))
            )
        }));
    }

    let conflicts: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|c| *c)
        .count();
    assert_eq!(conflicts, 8);
    assert_eq!(state.lock().unwrap().0.len(), 0);
}
