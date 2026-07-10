//! Concurrent deposit while mark_start: money conserved, job authorized.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_mark_start_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 400_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 100_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_ms", "a", 60_000, 15_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_m = led.clone();
    let mark = thread::spawn(move || {
        let mut g = led_m.lock().unwrap();
        g.mark_start_authorized("j").is_ok()
    });

    let deposited = deposit.join().unwrap();
    let marked = mark.join().unwrap();
    assert!(deposited);
    assert!(marked);

    let g = led.lock().unwrap();
    assert!(g.job_funded_start("j"));
    assert_eq!(g.active_job_count(), 1);
    // Seed 400k + deposit 60k - reserved 100k = 360k free
    assert_eq!(g.balance("a").0, 360_000);
    assert_eq!(g.job_reserved_total("j").unwrap().0, 100_000);
}
