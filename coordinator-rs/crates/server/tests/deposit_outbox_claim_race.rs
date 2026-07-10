//! Concurrent outbox claim after deposit enqueue: exactly one claimer.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use darkbloom_coordinator::Outbox;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_claim_after_deposit_enqueue_exactly_one() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
        Outbox::new(16),
    )));
    {
        let mut g = state.lock().unwrap();
        let (inbox, led, box_) = &mut *g;
        assert!(apply_stripe_deposit(inbox, led, "stripe", "evt_ob", "a", 100_000, 0).unwrap());
        box_
            .enqueue(
                "billing.deposit_applied",
                r#"{"event_id":"evt_ob"}"#,
            )
            .unwrap();
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            g.2.try_claim().map(|e| e.id)
        }));
    }

    let mut claimed = Vec::new();
    for h in handles {
        if let Some(id) = h.join().unwrap() {
            claimed.push(id);
        }
    }
    assert_eq!(claimed.len(), 1);
    assert_eq!(claimed[0], 1);
    assert!(state.lock().unwrap().2.is_empty());
}
