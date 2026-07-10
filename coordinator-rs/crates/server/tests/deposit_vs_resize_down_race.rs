//! Concurrent deposit while resize_and_authorize downsizes: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_resize_down_conserves_money() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        let (inbox, led) = &mut *g;
        apply_stripe_deposit(inbox, led, "stripe", "seed", "a", 200_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        // Remaining bal = 100k
    }

    let state_d = state.clone();
    let deposit = thread::spawn(move || {
        let mut g = state_d.lock().unwrap();
        let (inbox, led) = &mut *g;
        apply_stripe_deposit(inbox, led, "stripe", "evt_dn", "a", 50_000, 10_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let state_r = state.clone();
    let resize = thread::spawn(move || {
        let mut g = state_r.lock().unwrap();
        g.1.resize_and_authorize(OperationKey("ra".into()), "j", "a", 40_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let resized = resize.join().unwrap();
    assert!(deposited);
    assert!(resized);

    let g = state.lock().unwrap();
    // Seed 200k + deposit 50k = 250k total. Job holds 40k → free bal = 210k.
    assert_eq!(g.1.job_reserved_total("j").unwrap().0, 40_000);
    assert_eq!(g.1.balance("a").0 + 40_000, 250_000);
    assert!(g.1.job_funded_start("j"));
}
