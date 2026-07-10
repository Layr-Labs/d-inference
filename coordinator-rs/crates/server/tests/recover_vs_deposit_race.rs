//! Concurrent recover_undispatched vs apply_stripe_deposit: money conservation.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{recover_undispatched, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_recover_undispatched_and_deposit_conserves_money() {
    let ledger = Arc::new(Mutex::new(MemoryLedger::default()));
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    {
        let mut g = ledger.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        // Not start_authorized — recover_undispatched may release.
    }

    let led_r = ledger.clone();
    let recover = thread::spawn(move || {
        recover_undispatched(&led_r, "j", "a").unwrap()
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
            "evt_rec",
            "a",
            2_000_000,
            500_000,
        )
        .unwrap()
    });

    let recovered = recover.join().unwrap();
    let deposited = deposit.join().unwrap();
    assert!(deposited);
    assert!(matches!(
        recovered,
        RecoveryAction::Released | RecoveryAction::AlreadyTerminal
    ));
    // If recover won first: 5M - 1M + 1M refund + 2M deposit = 7M
    // If deposit interleaved after release: same 7M
    // If deposit before release: 5M - 1M + 2M + 1M refund = 7M
    let g = ledger.lock().unwrap();
    assert_eq!(g.balance("a").0, 7_000_000);
    assert_eq!(g.active_job_count(), 0);
}
