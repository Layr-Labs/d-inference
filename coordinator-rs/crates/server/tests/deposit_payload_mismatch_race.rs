//! Concurrent deposit with same event_id but different amounts: conflict, no double credit.

use darkbloom_coordinator::deposits::{apply_stripe_deposit, DepositError};
use darkbloom_coordinator::external_events::{ExternalEventError, ExternalEventInbox};
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_mismatched_deposit_params_conflict() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));

    let mut handles = Vec::new();
    for i in 0..8 {
        let state = state.clone();
        handles.push(thread::spawn(move || {
            let mut g = state.lock().unwrap();
            let (inbox, led) = &mut *g;
            let amount = if i % 2 == 0 { 100_000 } else { 200_000 };
            match apply_stripe_deposit(inbox, led, "stripe", "evt_mm", "a", amount, 0) {
                Ok(true) => "applied",
                Ok(false) => "replay",
                Err(DepositError::External(ExternalEventError::Conflict(_))) => "conflict",
                Err(_) => "other_err",
            }
            .to_string()
        }));
    }

    let mut applied = 0usize;
    let mut conflict = 0usize;
    let mut replay = 0usize;
    for h in handles {
        match h.join().unwrap().as_str() {
            "applied" => applied += 1,
            "conflict" => conflict += 1,
            "replay" => replay += 1,
            other => panic!("unexpected {other}"),
        }
    }
    assert_eq!(applied, 1);
    assert_eq!(conflict + replay, 7);
    assert!(conflict >= 1, "at least one mismatched amount must conflict");
    let g = state.lock().unwrap();
    let bal = g.1.balance("a").0;
    assert!(bal == 100_000 || bal == 200_000, "bal={bal}");
}
