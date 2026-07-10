//! Concurrent deposit while force_settle on resized hold: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_force_settle_after_resize_conserves() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        let (inbox, led) = &mut *g;
        apply_stripe_deposit(inbox, led, "stripe", "seed", "a", 1_000_000, 0).unwrap();
        led.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        led.resize_and_authorize(OperationKey("ra".into()), "j", "a", 300_000)
            .unwrap();
    }

    let state_d = state.clone();
    let deposit = thread::spawn(move || {
        let mut g = state_d.lock().unwrap();
        let (inbox, led) = &mut *g;
        apply_stripe_deposit(inbox, led, "stripe", "evt_fs", "a", 200_000, 50_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let state_f = state.clone();
    let force = thread::spawn(move || {
        let mut g = state_f.lock().unwrap();
        g.1.settle_capped_as(
            OperationKey("force_settle:j".into()),
            "j",
            "a",
            100_000,
            300_000,
            "force-dep-d",
            "force_settled",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let forced = force.join().unwrap();
    assert!(deposited);
    assert!(forced);

    let g = state.lock().unwrap();
    // Seed 1M + deposit 200k = 1.2M. Charged 100k → free bal = 1.1M.
    assert_eq!(g.1.active_job_count(), 0);
    assert_eq!(g.1.balance("a").0, 1_100_000);
    assert_eq!(g.1.job_disposition("j"), Some("force_settled"));
}
