//! Deposit then concurrent reserve: non-withdrawable consumed first.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn deposit_then_concurrent_reserve_consumes_non_wdr_first() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        let (inbox, led) = &mut *g;
        // 70k non-wdr + 30k wdr
        apply_stripe_deposit(inbox, led, "stripe", "evt_d1", "a", 70_000, 0).unwrap();
        apply_stripe_deposit(inbox, led, "stripe", "evt_d2", "a", 30_000, 30_000).unwrap();
        assert_eq!(led.balance("a"), (100_000, 30_000));
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            match g.1.reserve(
                OperationKey(format!("r-{i}")),
                &format!("job-{i}"),
                "a",
                25_000,
            ) {
                Ok(res) => Some(res.provenance.withdrawable.0),
                Err(LedgerError::InsufficientBalance) => None,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }

    let mut reserved_wdr = Vec::new();
    for h in handles {
        if let Some(w) = h.join().unwrap() {
            reserved_wdr.push(w);
        }
    }
    // 100k / 25k = 4 successful reserves
    assert_eq!(reserved_wdr.len(), 4);
    // First reserves should prefer non-wdr (reserved_wdr == 0) until non-wdr exhausted.
    let zero_wdr = reserved_wdr.iter().filter(|&&w| w == 0).count();
    let positive_wdr = reserved_wdr.iter().filter(|&&w| w > 0).count();
    assert!(zero_wdr >= 2, "non-wdr consumed first: {reserved_wdr:?}");
    assert!(positive_wdr >= 1, "later reserves touch wdr: {reserved_wdr:?}");
    let g = state.lock().unwrap();
    assert_eq!(g.1.balance("a").0, 0);
    assert_eq!(g.1.active_job_count(), 4);
}
