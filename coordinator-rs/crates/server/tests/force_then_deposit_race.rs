//! Concurrent MemoryLedger.force_settle then deposit on same account.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use darkbloom_coordinator::recovery::{force_settle_held, RecoveryAction};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn force_settle_then_concurrent_deposits_stack() {
    let ledger = Arc::new(Mutex::new(MemoryLedger::default()));
    let inbox = Arc::new(Mutex::new(ExternalEventInbox::new()));
    {
        let mut g = ledger.lock().unwrap();
        g.credit("a", 5_000_000, 0).unwrap();
        g.reserve(OperationKey("r".into()), "j", "a", 1_000_000)
            .unwrap();
        g.mark_start_authorized("j").unwrap();
    }
    assert_eq!(
        force_settle_held(&ledger, "j", "a", 100_000, "fd").unwrap(),
        RecoveryAction::Released
    );
    // bal = 5M - 1M + 900k = 4.9M

    let mut handles = Vec::new();
    for i in 0..4 {
        let ledger = ledger.clone();
        let inbox = inbox.clone();
        handles.push(thread::spawn(move || {
            let mut inbox = inbox.lock().unwrap();
            let mut led = ledger.lock().unwrap();
            apply_stripe_deposit(
                &mut inbox,
                &mut led,
                "stripe",
                &format!("e{i}"),
                "a",
                100_000,
                10_000,
            )
            .unwrap()
        }));
    }

    assert_eq!(
        handles
            .into_iter()
            .filter_map(|h| h.join().ok())
            .filter(|a| *a)
            .count(),
        4
    );
    let (bal, wdr) = ledger.lock().unwrap().balance("a");
    assert_eq!(bal, 4_900_000 + 400_000);
    assert_eq!(wdr, 40_000);
}
