//! Concurrent force_settle_held vs apply_stripe_deposit: money conservation.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_force_settle_and_deposit_conserves_money() {
    let ledger = Arc::new(Mutex::new(MemoryLedger::default()));
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    {
        let mut g = ledger.lock().unwrap();
        g.credit("a", 10_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j", "a").unwrap();
    }

    let led_f = ledger.clone();
    let force = thread::spawn(move || {
        force_settle_held(&led_f, "j", "a", 400_000, "force-d")
            .map(|a| a == RecoveryAction::Released)
            .unwrap_or(false)
    });
    let led_d = ledger.clone();
    let inbox_d = inbox.clone();
    let deposit = thread::spawn(move || {
        // Take both locks in a fixed order to avoid deadlock with force_settle.
        let mut inbox = inbox_d.lock().unwrap();
        let mut led = led_d.lock().unwrap();
        apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            "evt_fs",
            "a",
            3_000_000,
            1_000_000,
        )
        .unwrap()
    });

    let forced = force.join().unwrap();
    let deposited = deposit.join().unwrap();
    assert!(forced, "force_settle must clear the hold");
    assert!(deposited, "deposit must apply once");
    let g = ledger.lock().unwrap();
    // Start 10M - 1M reserve + 0.6M refund (charge 0.4M) + 3M deposit = 12.6M
    assert_eq!(g.balance("a").0, 12_600_000);
    assert_eq!(g.active_job_count(), 0);
    assert_eq!(g.held_start_authorized_count(), 0);
}
