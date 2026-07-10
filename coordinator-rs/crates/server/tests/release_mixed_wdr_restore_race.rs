//! Release after mixed-provenance reserve restores withdrawable exactly.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{LedgerError, MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_release_restores_mixed_withdrawable_exactly() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut inbox = ExternalEventInbox::new();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut inbox, &mut g, "stripe", "e1", "a", 50_000, 0).unwrap();
        apply_stripe_deposit(&mut inbox, &mut g, "stripe", "e2", "a", 50_000, 50_000).unwrap();
        let res = g
            .reserve(OperationKey("r".into()), "j", "a", 80_000)
            .unwrap();
        // non_wdr=50k, so reserved_wdr = 30k
        assert_eq!(res.provenance.withdrawable.0, 30_000);
        assert_eq!(g.balance("a"), (20_000, 20_000));
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            match g.release(OperationKey(format!("rel-{i}")), "j", "a") {
                Ok(applied) => applied,
                Err(LedgerError::Conflict(_)) => false,
                Err(e) => panic!("unexpected: {e}"),
            }
        }));
    }

    let mut wins = 0usize;
    for h in handles {
        if h.join().unwrap() {
            wins += 1;
        }
    }
    assert_eq!(wins, 1);
    let g = led.lock().unwrap();
    assert_eq!(g.active_job_count(), 0);
    // Full restore: 20k leftover + 80k release = 100k; wdr 20k + 30k = 50k
    assert_eq!(g.balance("a"), (100_000, 50_000));
}
