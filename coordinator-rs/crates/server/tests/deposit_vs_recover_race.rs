//! Concurrent deposit while recover_undispatched: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_recover_undispatched_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 500_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rec", "a", 80_000, 20_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_r = led.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_r, "j", "a")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let released = recover.join().unwrap();
    assert!(deposited);
    assert!(released);

    let g = led.lock().unwrap();
    // Seed 500k + deposit 80k = 580k; reservation released → bal=580k
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 580_000);
}
