//! Concurrent apply_stripe_deposit empty event_id: InvalidKey.

use darkbloom_coordinator::deposits::{apply_stripe_deposit, DepositError};
use darkbloom_coordinator::external_events::{ExternalEventError, ExternalEventInbox};
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_empty_event_id_all_invalid_key() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, ledger) = &mut *g;
            matches!(
                apply_stripe_deposit(inbox, ledger, "stripe", "", "a", 100, 0),
                Err(DepositError::External(ExternalEventError::InvalidKey))
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
