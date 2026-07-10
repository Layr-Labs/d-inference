//! Reserve mixed provenance then settle: unused withdrawable restored.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_settle_restores_unused_withdrawable_after_mixed_reserve() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut inbox = ExternalEventInbox::new();
        let mut g = led.lock().unwrap();
        apply_stripe_deposit(&mut inbox, &mut g, "stripe", "e1", "a", 60_000, 0).unwrap();
        apply_stripe_deposit(&mut inbox, &mut g, "stripe", "e2", "a", 40_000, 40_000).unwrap();
        // Reserve 80k: consumes 60k non-wdr + 20k wdr → reserved_wdr=20k
        let res = g
            .reserve(OperationKey("r".into()), "j", "a", 80_000)
            .unwrap();
        assert_eq!(res.provenance.withdrawable.0, 20_000);
        assert_eq!(g.balance("a"), (20_000, 20_000)); // leftover all wdr
        g.mark_start_authorized("j").unwrap();
    }

    let mut handles = Vec::new();
    for i in 0..8 {
        let led = led.clone();
        handles.push(thread::spawn(move || {
            let mut g = led.lock().unwrap();
            g.settle(
                OperationKey(format!("s-{i}")),
                "j",
                "a",
                50_000, // charge 50k of 80k → refund 30k of which some is wdr
                "d-mix",
            )
            .map(|applied| applied)
            .unwrap_or(false)
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
    // After settle: bal was 20k leftover + 30k refund = 50k
    // Provenance: non_wdr reserved=60k, wdr reserved=20k; charge 50k consumes all 60k? 
    // non_wdr_reserved = 80k-20k = 60k; charge 50k < 60k → consumed_wdr=0, refund_wdr=20k
    // bal = 20k + 30k = 50k; wdr = 20k + 20k = 40k
    assert_eq!(g.balance("a"), (50_000, 40_000));
}
