# Crash-boundary coverage. Shared filesystem/assertion helpers are loaded by
# test-install-atomic.sh before this module.

test_app_chmod_rollback_checkpoint() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/recovery-gap-app-chmod-$label"
    installer_recovery_seed_previous_app "$install_dir"
    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" app-chmod

    local backup
    backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$backup" prepared

    bash "$installer" --recover-install-transactions-test "$install_dir"
    installer_recovery_assert_previous_app "$install_dir"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "$label app-chmod recovery"
}

test_app_recovery_bin_checkpoint_restarts() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/recovery-gap-app-bin-$label"
    installer_recovery_seed_previous_app "$install_dir"
    installer_recovery_expect_install_crash \
        "$installer" "$VALID" "$install_dir" staged-app-moved

    local backup
    backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$backup" prepared
    local attempt
    for attempt in 1 2; do
        installer_recovery_expect_recovery_crash \
            "$installer" "$install_dir" recovery-bin-restored
        test -d "$backup"
        installer_recovery_assert_manifest_phase "$backup" prepared
        installer_recovery_assert_previous_app "$install_dir"
    done

    bash "$installer" --recover-install-transactions-test "$install_dir"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    installer_recovery_assert_previous_app "$install_dir"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "repeated app recovery-bin-restored recovery"
}

test_flat_recovery_bin_checkpoint_restarts() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/recovery-gap-flat-bin-$label"
    installer_recovery_seed_previous_flat "$installer" "$install_dir"
    installer_recovery_expect_install_crash \
        "$installer" "$FLAT_LEGACY" "$install_dir" flat-layout-moved

    local backup
    backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$backup" prepared
    local attempt
    for attempt in 1 2; do
        installer_recovery_expect_recovery_crash \
            "$installer" "$install_dir" recovery-bin-restored
        test -d "$backup"
        installer_recovery_assert_manifest_phase "$backup" prepared
        installer_recovery_assert_previous_flat "$install_dir"
    done

    bash "$installer" --recover-install-transactions-test "$install_dir"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    installer_recovery_assert_previous_flat "$install_dir"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "repeated flat recovery-bin-restored recovery"
}

test_rolled_back_journal_is_retired() {
    local installer=$1
    local label=$2
    local kind=$3
    local install_dir="$ROOT/recovery-gap-rolled-back-$kind-$label"
    local crash_point
    local setup_point
    local archive

    if [ "$kind" = app ]; then
        installer_recovery_seed_previous_app "$install_dir"
        archive=$VALID
        setup_point=staged-app-moved
        crash_point=app-transaction-rolled-back
    else
        installer_recovery_seed_previous_flat "$installer" "$install_dir"
        archive=$FLAT_LEGACY
        setup_point=flat-layout-moved
        crash_point=flat-transaction-rolled-back
    fi
    installer_recovery_expect_install_crash \
        "$installer" "$archive" "$install_dir" "$setup_point"
    installer_recovery_expect_recovery_crash \
        "$installer" "$install_dir" "$crash_point"

    local backup
    backup=$(installer_recovery_only_backup "$install_dir")
    installer_recovery_assert_manifest_phase "$backup" rolled_back
    if [ "$kind" = app ]; then
        installer_recovery_assert_previous_app "$install_dir"
    else
        installer_recovery_assert_previous_flat "$install_dir"
    fi

    # A new process must recognize the durable rolled_back phase, retire it
    # without replaying component restoration, and remain a no-op thereafter.
    bash "$installer" --recover-install-transactions-test "$install_dir"
    bash "$installer" --recover-install-transactions-test "$install_dir"
    test ! -e "$backup"
    installer_recovery_assert_no_transaction_debris \
        "$install_dir" "$kind rolled_back journal retirement"
}

# The app-chmod rollback checkpoint exists after the candidate app and bin have
# both become live, so it must restore every previous component in both public
# installer copies.
test_app_chmod_rollback_checkpoint \
    "$REPO_ROOT/scripts/install.sh" source
test_app_chmod_rollback_checkpoint \
    "$REPO_ROOT/coordinator/api/install.sh" embedded

# Re-fire recovery-bin-restored twice to model two consecutive process deaths.
# Split app/flat coverage across the byte-identical public copies.
test_app_recovery_bin_checkpoint_restarts \
    "$REPO_ROOT/scripts/install.sh" source
test_flat_recovery_bin_checkpoint_restarts \
    "$REPO_ROOT/coordinator/api/install.sh" embedded

# Prove the durable rolled_back phase is sufficient for a fresh process to
# retire the journal without replaying restoration.
test_rolled_back_journal_is_retired \
    "$REPO_ROOT/scripts/install.sh" source app
test_rolled_back_journal_is_retired \
    "$REPO_ROOT/coordinator/api/install.sh" embedded flat
