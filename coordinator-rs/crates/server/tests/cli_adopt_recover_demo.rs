//! CLI --demo-adopt-recover-job / --demo-adopt-force-settle-job dry-runs
//! (DECISIONS #66/#75/#76).

use darkbloom_coordinator::cli::{run_recovery, RecoveryOpts};

fn opts(
    adopt_recover: Option<&str>,
    adopt_force: Option<&str>,
    confirm: bool,
) -> RecoveryOpts {
    RecoveryOpts {
        enabled: true,
        confirm,
        demo_job: None,
        demo_held_job: None,
        demo_force_settle_job: None,
        demo_adopt_recover_job: adopt_recover.map(str::to_string),
        demo_adopt_force_settle_job: adopt_force.map(str::to_string),
        demo_deposit_event: None,
        demo_account: "pilot-account".into(),
    }
}

#[test]
fn demo_adopt_recover_job_releases_after_rebind() {
    run_recovery(opts(Some("adopt-demo"), None, true)).expect("adopt-recover demo");
}

#[test]
fn demo_adopt_recover_requires_confirm() {
    let err = run_recovery(opts(Some("adopt-demo"), None, false)).unwrap_err();
    assert!(err.contains("confirm-same-release"));
}

#[test]
fn demo_adopt_force_settle_job_clears_hold_after_rebind() {
    run_recovery(opts(None, Some("adopt-fs-demo"), true)).expect("adopt-force-settle demo");
}
