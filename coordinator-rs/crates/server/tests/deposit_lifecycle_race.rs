//! Concurrent MemoryLedger.deposit apply then lifecycle on funded account.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_lifecycle_on_funded_account() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        g.1.credit("a", 1_000_000, 0).unwrap();
    }

    let state_d = state.clone();
    let deposit = thread::spawn(move || {
        let mut g = state_d.lock().unwrap();
        let (inbox, ledger) = &mut *g;
        apply_stripe_deposit(inbox, ledger, "stripe", "boost", "a", 5_000_000, 0).unwrap()
    });

    let state_l = state.clone();
    let lifecycle = thread::spawn(move || {
        // Wait briefly by spinning on lock after deposit likely done —
        // actually just take lock; order is serialized by mutex.
        let mut g = state_l.lock().unwrap();
        let bal = g.1.balance("a").0;
        if bal < 1_000_000 {
            return false;
        }
        // Use whatever balance is available after possible deposit
        let amount = 500_000.min(bal);
        g.1.reserve(OperationKey("r".into()), "j", "a", amount)
            .unwrap();
        g.1.mark_start_authorized("j").unwrap();
        g.1.settle(OperationKey("s".into()), "j", "a", 100_000, "d")
            .unwrap()
    });

    let deposited = deposit.join().unwrap();
    let settled = lifecycle.join().unwrap();
    assert!(deposited);
    assert!(settled);
    let g = state.lock().unwrap();
    assert_eq!(g.1.active_job_count(), 0);
    // Start 1M + deposit 5M - 500k + 400k refund = 5.9M
    // (if lifecycle ran before deposit: 1M - 500k + 400k + 5M = 5.9M same)
    assert_eq!(g.1.balance("a").0, 5_900_000);
}
