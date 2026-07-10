//! Concurrent deposit with settle XOR settle_capped after resize: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_with_settle_or_capped_after_resize_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 1_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
        g.resize_and_authorize(OperationKey("ra".into()), "j", "a", 400_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rz_s_sc", "a", 150_000, 60_000)
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
            75_000,
            "d-s-rz",
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
            75_000,
            "d-c-rz",
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
    // Seed 1M + deposit 150k = 1.15M. Charged 75k → free = 1.075M
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 1_075_000);
    assert_eq!(g.job_disposition("j"), Some("settled"));
}
