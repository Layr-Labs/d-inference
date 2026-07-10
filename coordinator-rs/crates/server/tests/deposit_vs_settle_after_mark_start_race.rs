//! Concurrent deposit while settle after mark_start: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_settle_after_mark_start_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 800_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 200_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_st", "a", 100_000, 25_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_s = led.clone();
    let settle = thread::spawn(move || {
        let mut g = led_s.lock().unwrap();
        g.settle(
            OperationKey("settle:j".into()),
            "j",
            "a",
            80_000,
            "d-dep-st",
        )
        .map(|applied| applied)
        .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let settled = settle.join().unwrap();
    assert!(deposited);
    assert!(settled);

    let g = led.lock().unwrap();
    // Seed 800k + deposit 100k = 900k. Charged 80k of 200k → free = 900k - 80k = 820k
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 820_000);
}
