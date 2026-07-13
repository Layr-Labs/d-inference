use super::*;

#[test]
fn replay_and_terminal_fsync_faults_are_atomic_across_restart() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let root = temp_path("durable-faults");
    fs::create_dir_all(&root).expect("create durable fault directory");

    let terminal_path = root.join("terminals.json");
    let record = terminal_record();
    let terminal_store =
        TerminalDispositionStore::open(&terminal_path, 4).expect("open terminal store");
    let terminal_fault =
        arm(FaultPoint::TerminalCacheFsync, FaultAction::Fail).expect("arm terminal fsync");
    assert!(matches!(
        terminal_store.finalize(record.clone()),
        Err(TerminalStoreError::InjectedFault("terminal_cache_fsync"))
    ));
    assert!(terminal_store.is_empty());
    drop(terminal_store);
    let terminal_store =
        TerminalDispositionStore::open(&terminal_path, 4).expect("restart terminal store");
    assert_eq!(
        terminal_store.resolve_historical(record.key, record.terminal_digest),
        TerminalResolution::Idempotent(TerminalDisposition::Settled)
    );
    record_receipt(
        "terminal_cache_fsync_is_atomic_across_restart",
        &[&terminal_fault],
        &["historical_ack", "exactly_one_disposition"],
    );
    drop(terminal_fault);

    let signer_path = root.join("replay-signer.json");
    let replay_path = root.join("replay.json");
    let signer = ReplayProofSigner::open(&signer_path).expect("open replay signer");
    let proof = signer.sign(
        ProviderId::new([8; 16]),
        ProviderProcessGenerationId::new([9; 16]),
        SessionEpoch(3),
        2,
    );
    let limits = ReplayStoreLimits {
        maximum_providers: 2,
        maximum_generations_per_provider: 2,
        maximum_proofs_per_generation: 2,
    };
    let replay_store = ReplayProofStore::open(&replay_path, limits).expect("open replay store");
    let replay_fault =
        arm(FaultPoint::ReplayProofFsync, FaultAction::Fail).expect("arm replay fsync");
    assert!(matches!(
        replay_store.enqueue(proof.clone()),
        Err(ReplayStoreError::InjectedFault("replay_proof_fsync"))
    ));
    assert_eq!(
        replay_store.pending_for_provider(proof.provider_id),
        0,
        "post-fsync fault published unconfirmed in-memory state"
    );
    drop(replay_store);
    let replay_store = ReplayProofStore::open(&replay_path, limits).expect("restart replay store");
    assert_eq!(replay_store.pending_for_provider(proof.provider_id), 1);
    replay_store
        .enqueue(proof.clone())
        .expect("replay proof is idempotent after recovery");
    drop(replay_store);
    let replay_store =
        ReplayProofStore::open(&replay_path, limits).expect("restart persisted replay store");
    assert_eq!(replay_store.pending_for_provider(proof.provider_id), 1);
    record_receipt(
        "replay_proof_fsync_is_atomic_across_restart",
        &[&replay_fault],
        &["historical_ack", "exactly_one_disposition"],
    );
    drop(replay_fault);

    fs::remove_dir_all(root).expect("remove durable fault directory");
}
