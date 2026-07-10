//! Concurrent deposit while recover_undispatched after mark_start: deposit applies, recover Skips.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_recover_after_mark_start_deposit_only() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 500_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 150_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
        // bal = 350k, reserved = 150k, funded_start
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rec_ms", "a", 75_000, 20_000)
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
    // Seed 500k + deposit 75k - reserved 150k = 425k free
    assert_eq!(g.balance("a").0, 425_000);
    assert_eq!(g.job_reserved_total("j").unwrap().0, 150_000);
}
