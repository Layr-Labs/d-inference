//! CLI --demo-remaining-accounts (DECISIONS #132).

use darkbloom_coordinator::cli::{run_recovery, RecoveryOpts};

#[test]
fn demo_remaining_accounts_clears_after_adopt() {
    let opts = RecoveryOpts {
        enabled: true,
        confirm: true,
        demo_job: None,
        demo_held_job: None,
        demo_force_settle_job: None,
        demo_adopt_recover_job: None,
        demo_adopt_force_settle_job: None,
        demo_clear_orphans: false,
        demo_cutover_drain: false,
        demo_cutover_drain_all: false,
        demo_remaining_accounts: true,
        demo_deposit_event: None,
        demo_account: "pilot-account".into(),
    };
    run_recovery(opts).expect("remaining-accounts demo");
}
