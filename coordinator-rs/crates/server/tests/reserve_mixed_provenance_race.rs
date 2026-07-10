//! Concurrent MemoryLedger.reserve with mixed withdrawable/non-wdr accounts.

use darkbloom_coordinator::ledger::{MemoryLedger, OperationKey};
use std::sync::{Arc, Mutex};
use std::thread;

#[test]
fn concurrent_reserve_mixed_provenance_accounts() {
    let led = Arc::new(Mutex::new(MemoryLedger::default()));
    {
        let mut g = led.lock().unwrap();
        // Account a: mostly non-wdr
        g.credit("a", 5_000_000, 500_000).unwrap();
        // Account b: all wdr
        g.credit("b", 5_000_000, 5_000_000).unwrap();
    }

    let led_a = led.clone();
    let ra = thread::spawn(move || {
        let mut g = led_a.lock().unwrap();
        let r = g
            .reserve(OperationKey("ra".into()), "ja", "a", 1_000_000)
            .unwrap();
        r.provenance.withdrawable.0
    });
    let led_b = led.clone();
    let rb = thread::spawn(move || {
        let mut g = led_b.lock().unwrap();
        let r = g
            .reserve(OperationKey("rb".into()), "jb", "b", 1_000_000)
            .unwrap();
        r.provenance.withdrawable.0
    });

    let wdr_a = ra.join().unwrap();
    let wdr_b = rb.join().unwrap();
    // a: non_wdr=4.5M, reserve 1M → reserved_wdr=0
    assert_eq!(wdr_a, 0);
    // b: all wdr → reserved_wdr=1M
    assert_eq!(wdr_b, 1_000_000);

    let g = led.lock().unwrap();
    assert_eq!(g.balance("a"), (4_000_000, 500_000));
    assert_eq!(g.balance("b"), (4_000_000, 4_000_000));
    assert_eq!(g.active_job_count(), 2);
}
