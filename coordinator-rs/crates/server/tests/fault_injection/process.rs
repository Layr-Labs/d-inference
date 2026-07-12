use super::*;

const CHILD_MODE: &str = "DARKBLOOM_FAULT_CHILD";
const CHILD_STATE_PATH: &str = "DARKBLOOM_FAULT_CHILD_STATE_PATH";
const CHILD_HIT_PATH: &str = "DARKBLOOM_FAULT_CHILD_HIT_PATH";
const CHILD_RECOVERED: &str = "DARKBLOOM_FAULT_CHILD_RECOVERED";

#[test]
fn crash_action_is_a_supervisor_panic_outside_child_mode() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let cancellation = RequestCancellation::new(CancellationToken::new(), |_| {});
    let (sender, _receiver) = byte_pipe(
        BytePipeLimits {
            maximum_items: 1,
            maximum_bytes: 1,
        },
        cancellation,
        None,
    )
    .expect("byte pipe");
    let guard =
        arm(FaultPoint::BytePipeOverflow, FaultAction::Crash).expect("arm supervisor crash");
    let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = sender.try_send(vec![1]);
    }))
    .expect_err("supervisor crash action returned");
    let crash = panic
        .downcast_ref::<darkbloom_coordinator_server::fault::FaultCrash>()
        .expect("fault crash panic payload");
    assert_eq!(crash.point, FaultPoint::BytePipeOverflow);
    assert_eq!(
        guard.assert_hit().expect("production crash hook").symbol,
        "BytePipeSender::try_send"
    );
    assert_eq!(
        guard
            .assert_execution()
            .expect("supervisor crash execution")
            .outcome,
        FaultOutcome::SupervisorPanicked
    );
    record_receipt(
        "supervisor_crash_preserves_bounded_byte_pipe",
        &[&guard],
        &["bounded_backpressure", "exactly_one_disposition"],
    );
}

#[test]
fn fault_child_fixture() {
    let mode = std::env::var(CHILD_MODE).unwrap_or_default();
    let Some(path) = std::env::var_os(CHILD_STATE_PATH).map(PathBuf::from) else {
        assert!(mode.is_empty(), "fault child state path is missing");
        return;
    };
    if mode == "recover" {
        let store = TerminalDispositionStore::open(&path, 4).expect("reopen killed child state");
        let record = terminal_record();
        assert_eq!(
            store.resolve_historical(record.key, record.terminal_digest),
            TerminalResolution::Idempotent(TerminalDisposition::Settled)
        );
        println!("{CHILD_RECOVERED}");
        return;
    }
    if mode != "crash" {
        return;
    }

    let store = TerminalDispositionStore::open(&path, 4).expect("open child terminal store");
    darkbloom_coordinator_server::fault::enable_child_abort_mode()
        .expect("enable child-only abort mode");
    let _guard =
        arm(FaultPoint::TerminalCacheFsync, FaultAction::Crash).expect("arm child fsync crash");
    let _ = store.finalize(terminal_record());
    panic!("crash action returned from child abort mode");
}

#[test]
fn child_abort_at_durable_fsync_recovers_same_state() {
    let root = temp_path("sigkill-fsync");
    fs::create_dir_all(&root).expect("create child state directory");
    let state_path = root.join("terminals.json");
    let hit_path = root.join("fault-hit");
    let executable = std::env::current_exe().expect("current test executable");
    let mut child = Command::new(executable)
        .args(["--exact", "process::fault_child_fixture", "--nocapture"])
        .env(CHILD_MODE, "crash")
        .env(CHILD_STATE_PATH, &state_path)
        .env("DARKBLOOM_FAULT_CHILD_ABORT", "1")
        .env(CHILD_HIT_PATH, &hit_path)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn fault child");
    let child_pid = child.id();
    let (status_tx, status_rx) = mpsc::sync_channel(1);
    let waiter = std::thread::spawn(move || {
        status_tx
            .send(child.wait().expect("wait for aborting child"))
            .expect("report child status");
    });
    let status = status_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("child did not abort at deterministic barrier");
    assert_eq!(status.signal(), Some(6));
    waiter.join().expect("join child waiter");
    let execution = read_abort_marker(&hit_path).expect("read child hit marker");
    assert_eq!(execution.hook_id, FaultPoint::TerminalCacheFsync.as_str());
    assert_eq!(execution.armed_action, FaultAction::Crash);
    assert_eq!(execution.executed_action, FaultAction::Crash);
    assert_eq!(execution.outcome, FaultOutcome::ProcessAborted);
    assert_eq!(execution.process_id, child_pid);

    let recovery = Command::new(std::env::current_exe().expect("current test executable"))
        .args(["--exact", "process::fault_child_fixture", "--nocapture"])
        .env(CHILD_MODE, "recover")
        .env(CHILD_STATE_PATH, &state_path)
        .output()
        .expect("spawn recovery child");
    assert!(
        recovery.status.success(),
        "recovery child failed: {}",
        String::from_utf8_lossy(&recovery.stderr)
    );
    assert!(
        String::from_utf8_lossy(&recovery.stdout).contains(CHILD_RECOVERED),
        "recovery child did not validate historical state"
    );
    write_test_receipt_from_executions(
        "child_abort_at_terminal_cache_fsync_recovers_same_state",
        &[execution],
        &["historical_ack", "exactly_one_disposition"],
    )
    .expect("write child abort receipt");
    fs::remove_dir_all(root).expect("remove child state directory");
}
