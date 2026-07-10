//! CLI adopt/clear/cutover demos (DECISIONS #66/#75/#76/#80/#94).

use darkbloom_coordinator::cli::{run_recovery, RecoveryOpts};

fn opts(
    adopt_recover: Option<&str>,
    adopt_force: Option<&str>,
    clear_orphans: bool,
    cutover_drain: bool,
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
        demo_clear_orphans: clear_orphans,
        demo_cutover_drain: cutover_drain,
        demo_deposit_event: None,
        demo_account: "pilot-account".into(),
    }
}

#[test]
fn demo_adopt_recover_job_releases_after_rebind() {
    run_recovery(opts(Some("adopt-demo"), None, false, false, true))
        .expect("adopt-recover demo");
}

#[test]
fn demo_adopt_recover_requires_confirm() {
    let err = run_recovery(opts(Some("adopt-demo"), None, false, false, false)).unwrap_err();
    assert!(err.contains("confirm-same-release"));
}

#[test]
fn demo_adopt_force_settle_job_clears_hold_after_rebind() {
    run_recovery(opts(None, Some("adopt-fs-demo"), false, false, true))
        .expect("adopt-force-settle demo");
}

#[test]
fn demo_clear_orphans_clears_mixed_reserved_and_held() {
    run_recovery(opts(None, None, true, false, true)).expect("clear-orphans demo");
}

#[test]
fn demo_cutover_drain_clears_and_drains_outbox() {
    run_recovery(opts(None, None, false, true, true)).expect("cutover-drain demo");
}
