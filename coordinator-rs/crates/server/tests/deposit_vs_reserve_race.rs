//! Concurrent apply_stripe_deposit vs reserve: deposit must not corrupt reservation.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_reserve_conserves_money() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        g.1.credit("a", 5_000_000, 0).unwrap();
    }

    let state_d = state.clone();
    let deposit = thread::spawn(move || {
        let mut g = state_d.lock().unwrap();
        let (inbox, ledger) = &mut *g;
        apply_stripe_deposit(inbox, ledger, "stripe", "evt_d", "a", 2_000_000, 1_000_000)
            .unwrap()
    });
    let state_r = state.clone();
    let reserve = thread::spawn(move || {
        let mut g = state_r.lock().unwrap();
        g.1.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let reserved = reserve.join().unwrap();
    assert!(deposited);
    assert!(reserved);
    let g = state.lock().unwrap();
    // Start 5M + deposit 2M - reserve 1M = 6M
    assert_eq!(g.1.balance("a").0, 6_000_000);
    assert_eq!(g.1.active_job_count(), 1);
    assert_eq!(g.1.job_reserved_total("j").unwrap().0, 1_000_000);
}
