//! Concurrent MemoryLedger.deposit apply then force_settle on held job.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_deposit_and_force_settle_distinct_concerns() {
    let ledger = Arc::new(Mutex::new(MemoryLedger::default()));
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    {
        let mut g = ledger.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }

    let led_f = ledger.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 250_000, "fd")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });
    let led_d = ledger.clone();
    let inbox_d = inbox.clone();
    let deposit = thread::spawn(move || {
        let mut inbox = inbox_d.lock().unwrap();
        let mut led = led_d.lock().unwrap();
        apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            "evt_x",
            "a",
            1_000_000,
            200_000,
        )
        .unwrap()
    });

    assert!(force.join().unwrap());
    assert!(deposit.join().unwrap());
    let g = ledger.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // 5M - 1M + 750k refund + 1M deposit = 5.75M
    assert_eq!(g.balance("a").0, 5_750_000);
    assert_eq!(g.balance("a").1, 200_000);
}
