//! Concurrent recover_undispatched after resize_and_authorize: always Skipped (already covered similarly; deposit concurrent).

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_recover_after_resize_auth_deposit_only() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 600_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 250_000)
            .unwrap();
        // bal = 350k, reserved = 250k, funded_start
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rec_rz", "a", 90_000, 25_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let mut recovers = Vec::new();
    for _ in 0..8 {
        let led = led.clone();
        recovers.push(thread::spawn(move || {
            recover_undispatched(&led, "j", "a").unwrap()
        }));
    }

    let deposited = deposit.join().unwrap();
    assert!(deposited);
    for h in recovers {
        assert_eq!(h.join().unwrap(), RecoveryAction::Skipped);
    }

    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 1);
    assert!(g.job_funded_start("j"));
    // Seed 600k + deposit 90k - reserved 250k = 440k free
    assert_eq!(g.balance("a").0, 440_000);
    assert_eq!(g.job_reserved_total("j").unwrap().0, 250_000);
}
