//! Concurrent apply_stripe_deposit with negative withdrawable: InvalidAmount.

use darkbloom_coordinator::deposits::{apply_stripe_deposit, DepositError};
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_negative_wdr_all_invalid() {
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
                    &format!("nw{i}"),
                    "a",
                    100,
                    -1,
                ),
                Err(DepositError::Ledger(LedgerError::InvalidAmount))
            )
        }));
    }

    let invalids: usize = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|v| *v)
        .count();
    assert_eq!(invalids, 8);
    assert_eq!(state.lock().unwrap().0.len(), 0);
}
