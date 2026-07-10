//! Concurrent MemoryLedger.balance withdrawable readers during deposit.

use darkbloom_coordinator::deposits::apply_stripe_deposit;
use darkbloom_coordinator::external_events::ExternalEventInbox;
use darkbloom_coordinator::ledger::MemoryLedger;
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_wdr_readers_during_deposit() {
    let state = Arc::new(Mutex::new((
        ExternalEventInbox::new(),
        MemoryLedger::default(),
    )));
    {
        let mut g = state.lock().unwrap();
        g.1.credit("a", 1_000_000, 500_000).unwrap();
    }

    let state_r = state.clone();
    let readers: Vec<_> = (0..8)
        .map(|_| {
            let state = state_r.clone();
            thread::spawn(move || {
                let g = state.lock().unwrap();
                g.1.balance("a").1
            })
        })
        .collect();

    let state_d = state.clone();
    let deposit = thread::spawn(move || {
        let mut g = state_d.lock().unwrap();
        let (inbox, ledger) = &mut *g;
        apply_stripe_deposit(inbox, ledger, "stripe", "wdr-boost", "a", 200_000, 200_000)
            .unwrap()
    });

    assert!(deposit.join().unwrap());
    for h in readers {
        let w = h.join().unwrap();
        assert!(w == 500_000 || w == 700_000, "wdr={w}");
    }
    assert_eq!(state.lock().unwrap().1.balance("a"), (1_200_000, 700_000));
}
