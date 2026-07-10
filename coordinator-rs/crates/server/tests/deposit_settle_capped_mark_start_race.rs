//! Concurrent deposit while settle vs settle_capped race after mark_start.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_with_settle_or_capped_after_mark_start_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 900_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 300_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_s_sc", "a", 120_000, 50_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        match g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            60_000,
            "d-s",
        ) {
            Ok(applied) => applied,
            Err(LedgerError::Conflict(_)) => false,
            Err(e) => panic!("unexpected: {e}"),
        }
    });

    let led_c = led.clone();
    let capped = thread::spawn(move || {
        let mut g = led_c.lock().unwrap();
        g.settle_capped(
            OperationKey("sc:j".into()),
            "j",
            "a",
            200_000,
            60_000,
            "d-c",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let settled = settle.join().unwrap();
    let capped_ok = capped.join().unwrap();
    assert!(deposited);
    assert!(settled ^ capped_ok, "exactly one settle path");

    let g = led.lock().unwrap();
    // Seed 900k + deposit 120k = 1.02M. Charged 60k → free = 960k
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 960_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
