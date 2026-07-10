//! Concurrent deposit while force_settle after mark_start: money conserved.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_force_settle_after_mark_start_conserves() {
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut ib = inbox.lock().unwrap();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "seed", "a", 600_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 150_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let inbox_d = inbox.clone();
    let led_d = led.clone();
    let deposit = thread::spawn(move || {
        let mut ib = inbox_d.lock().unwrap();
        let mut g = led_d.lock().unwrap();
        apply_stripe_deposit(&mut ib, &mut g, "stripe", "evt_fs_ms", "a", 90_000, 30_000)
            .map(|a| a)
            .unwrap_or(false)
    });

    let led_f = led.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 40_000, "force-dep-ms")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });

    let deposited = deposit.join().unwrap();
    let forced = force.join().unwrap();
    assert!(deposited);
    assert!(forced);

    let g = led.lock().unwrap();
    // Seed 600k + deposit 90k = 690k. Charged 40k → free = 650k
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.balance("a").0, 650_000);
    assert_eq!(g.job_disposition("j"), Some("force_settled"));
}
