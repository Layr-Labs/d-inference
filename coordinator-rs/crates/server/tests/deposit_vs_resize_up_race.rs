//! Concurrent deposit while resize_and_authorize upsizes: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_resize_up_conserves_money() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        let (inbox, led) = &mut *g;
        apply_stripe_deposit(inbox, led, "stripe", "seed", "a", 200_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 50_000)
            .unwrap();
        // Remaining bal = 150k
    }

    let state_d = state.clone();
    let deposit = thread::spawn(move || {
        let mut g = state_d.lock().unwrap();
        let (inbox, led) = &mut *g;
        apply_stripe_deposit(inbox, led, "stripe", "evt_up", "a", 100_000, 40_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let state_r = state.clone();
    let resize = thread::spawn(move || {
        let mut g = state_r.lock().unwrap();
        g.1.resize_and_authorize(OperationKey("ra".into()), "j", "a", 120_000)
            .map(|r| r.applied)
            .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let resized = resize.join().unwrap();
    assert!(deposited, "deposit must apply");
    assert!(resized, "resize up must apply");

    let g = state.lock().unwrap();
    // Start 200k; reserve 50k → 150k free; deposit +100k → 250k free before/during resize;
    // resize to 120k needs +70k from free → free ends at 250k-70k=180k if deposit before resize,
    // or 150k-70k=80k then +100k=180k if resize before deposit. Either order → bal=180k.
    // Job holds 120k. Total money = bal + reserved = 180k + 120k = 300k = 200k seed + 100k deposit.
    assert_eq!(g.1.balance("a").0 + g.1.job_reserved_total("j").unwrap().0, 300_000);
    assert!(g.1.job_funded_start("j"));
    assert_eq!(g.1.job_reserved_total("j").unwrap().0, 120_000);
}
