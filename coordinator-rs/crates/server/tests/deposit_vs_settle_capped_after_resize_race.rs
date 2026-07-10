//! Concurrent deposit while settle_capped after resize: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_settle_capped_after_resize_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 700_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 280_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rz_sc", "a", 110_000, 40_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            150_000,
            55_000,
            "d-rz-sc",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(deposited);
    assert!(capped_ok);

    let g = led.lock().unwrap();
    // Seed 700k + deposit 110k = 810k. Charged 55k → free = 755k
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 755_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
