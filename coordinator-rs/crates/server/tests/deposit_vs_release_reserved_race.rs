//! Concurrent deposit while release on reserved job: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_release_reserved_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 300_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 80_000)
            .unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_rel", "a", 50_000, 10_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_r = led.clone();
    let release = thread::spawn(move || {
        let mut g = led_r.lock().unwrap();
        g.release(OperationKey("rel:j".into()), "j", "a")
            .map(|applied| applied)
            .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let released = release.join().unwrap();
    assert!(deposited);
    assert!(released);

    let g = led.lock().unwrap();
    // Seed 300k + deposit 50k = 350k; reservation released → bal=350k
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 350_000);
}
