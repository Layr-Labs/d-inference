//! CLI --demo-adopt-recover-job dry-run (DECISIONS #66/#75).

use darkbloom_coordinator::cli::{run_recovery, RecoveryOpts};

#[test]
fn demo_adopt_recover_job_releases_after_rebind() {
    run_recovery(RecoveryOpts {
        enabled: true,
        confirm: true,
        demo_job: None,
        demo_held_job: None,
        demo_force_settle_job: None,
        demo_adopt_recover_job: Some("adopt-demo".into()),
        demo_deposit_event: None,
        demo_account: "pilot-account".into(),
    })
    .expect("adopt-recover demo");
}

#[test]
fn demo_adopt_recover_requires_confirm() {
    let err = run_recovery(RecoveryOpts {
        enabled: true,
        confirm: false,
        demo_job: None,
        demo_held_job: None,
        demo_force_settle_job: None,
        demo_adopt_recover_job: Some("adopt-demo".into()),
        demo_deposit_event: None,
        demo_account: "pilot-account".into(),
    })
    .unwrap_err();
    assert!(err.contains("confirm-same-release"));
}
