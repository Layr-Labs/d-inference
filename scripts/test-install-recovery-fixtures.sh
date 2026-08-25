# Recovery-only coverage sourced by test-install-atomic.sh after its signed
# app and flat release fixtures have been built. Keeping these compatibility
# fixtures separate makes each historical journal shape auditable without
# duplicating the expensive artifact setup.

installer_recovery_fail() {
    echo "$*" >&2
    return 1
}

installer_recovery_only_backup() {
    local install_dir=$1
    local backups=()
    local candidate
    for candidate in "$install_dir"/.install-backup-*; do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            backups+=("$candidate")
        fi
    done
    [ "${#backups[@]}" -eq 1 ] || {
        installer_recovery_fail \
            "expected one transaction backup in $install_dir, found ${#backups[@]}"
        return 1
    }
    printf '%s\n' "${backups[0]}"
}

installer_recovery_assert_manifest_phase() {
    local backup=$1
    local phase=$2
    [ -f "$backup/.transaction" ] \
        && grep -Fqx "phase=$phase" "$backup/.transaction" \
        || installer_recovery_fail \
            "transaction $backup did not durably record phase=$phase"
}

installer_recovery_assert_no_transaction_debris() {
    local install_dir=$1
    local context=$2
    local debris
    for debris in \
        "$install_dir"/.install-backup-* \
        "$install_dir"/.install-staging-* \
        "$install_dir"/.install-garbage-* \
        "$install_dir"/.install-restore-* \
        "$install_dir"/.install-legacy-*
    do
        if [ -e "$debris" ] || [ -L "$debris" ]; then
            installer_recovery_fail \
                "$context left installer transaction debris: $debris"
            return 1
        fi
    done
}

installer_recovery_expect_install_crash() {
    local installer=$1
    local archive=$2
    local install_dir=$3
    local checkpoint=$4
    artifact_hashes "$archive"
    if DARKBLOOM_INSTALL_TEST_CRASH_POINT="$checkpoint" \
        PATH="$CLT_SHIMS:$PATH" \
        bash "$installer" --install-bundle-test \
            "$archive" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH" \
            "$FAN_HELPER_REQUIREMENT"
    then
        installer_recovery_fail \
            "$installer survived injected install crash $checkpoint"
        return 1
    fi
}

installer_recovery_expect_recovery_crash() {
    local installer=$1
    local install_dir=$2
    local checkpoint=$3
    if DARKBLOOM_INSTALL_TEST_CRASH_POINT="$checkpoint" \
        bash "$installer" --recover-install-transactions-test "$install_dir"
    then
        installer_recovery_fail \
            "$installer survived injected recovery crash $checkpoint"
        return 1
    fi
}

installer_recovery_seed_previous_app() {
    local install_dir=$1
    local destination="$install_dir/Darkbloom.app"
    local bin_dir="$install_dir/bin"
    write_existing_bundle "$destination" com.example.recovery-previous
    printf 'previous app payload\n' > "$destination/previous-only"
    mkdir -p "$bin_dir"
    printf 'previous darkbloom\n' > "$bin_dir/darkbloom"
    printf 'previous metallib\n' > "$bin_dir/mlx.metallib"
    ln -s ../previous-enclave "$bin_dir/darkbloom-enclave"
    ln -s previous-legacy-enclave "$bin_dir/eigeninference-enclave"
}

installer_recovery_assert_previous_app() {
    local install_dir=$1
    local destination="$install_dir/Darkbloom.app"
    local bin_dir="$install_dir/bin"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$destination/Contents/Info.plist")" = \
        "com.example.recovery-previous"
    test "$(cat "$destination/previous-only")" = "previous app payload"
    test "$(cat "$bin_dir/darkbloom")" = "previous darkbloom"
    test "$(cat "$bin_dir/mlx.metallib")" = "previous metallib"
    test -L "$bin_dir/darkbloom-enclave"
    test "$(readlink "$bin_dir/darkbloom-enclave")" = "../previous-enclave"
    test -L "$bin_dir/eigeninference-enclave"
    test "$(readlink "$bin_dir/eigeninference-enclave")" = \
        "previous-legacy-enclave"
}

installer_recovery_seed_previous_flat() {
    local installer=$1
    local install_dir=$2
    run_install_with "$installer" "$FLAT_LEGACY" "$install_dir"
    printf 'previous-only\n' > "$install_dir/bin/previous-only"
}

installer_recovery_assert_previous_flat() {
    local install_dir=$1
    test -x "$install_dir/bin/darkbloom"
    test -L "$install_dir/bin/eigeninference-enclave"
    test "$(readlink "$install_dir/bin/eigeninference-enclave")" = \
        "darkbloom-enclave"
    test "$(cat "$install_dir/bin/previous-only")" = "previous-only"
}

test_app_chmod_rollback_checkpoint() {
    local installer=$1
    local label=$2
    assert_foreign_restored_after_failure \
        "$installer" "$label-app-chmod" app-chmod
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

installer_recovery_write_flat_layout() {
    local bin_dir=$1
    local prefix=$2
    rm -rf "$bin_dir"
    mkdir -p "$bin_dir"
    printf '%s-darkbloom\n' "$prefix" > "$bin_dir/darkbloom"
    printf '%s-enclave\n' "$prefix" > "$bin_dir/darkbloom-enclave"
    printf '%s-metallib\n' "$prefix" > "$bin_dir/mlx.metallib"
    chmod +x "$bin_dir/darkbloom" "$bin_dir/darkbloom-enclave"
    ln -s darkbloom-enclave "$bin_dir/eigeninference-enclave"
}

installer_recovery_write_managed_app_layout() {
    local install_dir=$1
    local prefix=$2
    local app="$install_dir/Darkbloom.app"
    local app_bin="$app/Contents/MacOS"
    local bin_dir="$install_dir/bin"
    rm -rf "$app" "$bin_dir"
    mkdir -p "$app_bin" "$bin_dir"
    printf '%s-darkbloom\n' "$prefix" > "$app_bin/darkbloom"
    printf '%s-enclave\n' "$prefix" > "$app_bin/darkbloom-enclave"
    printf '%s-metallib\n' "$prefix" > "$app_bin/mlx.metallib"
    chmod +x "$app_bin/darkbloom" "$app_bin/darkbloom-enclave"
    ln -s ../Darkbloom.app/Contents/MacOS/darkbloom \
        "$bin_dir/darkbloom"
    ln -s ../Darkbloom.app/Contents/MacOS/darkbloom-enclave \
        "$bin_dir/darkbloom-enclave"
    ln -s ../Darkbloom.app/Contents/MacOS/mlx.metallib \
        "$bin_dir/mlx.metallib"
    ln -s darkbloom-enclave "$bin_dir/eigeninference-enclave"
}

installer_recovery_write_v1_metadata() {
    local backup=$1
    local kind=$2
    local phase=$3
    local previous_was_foreign=${4:-0}
    printf '1\n' > "$backup/.transaction-version"
    printf '%s\n' "$kind" > "$backup/.transaction-kind"
    printf '%s\n' "$phase" > "$backup/.transaction-phase"
    printf '1\n' > "$backup/.had-previous"
    printf '%s\n' "$previous_was_foreign" \
        > "$backup/.previous-was-foreign"
    printf '.install-staging-321-654\n' > "$backup/.staging-name"
}

test_legacy_link_snapshot_recovery() {
    local installer=$1
    local label=$2
    local install_dir="$ROOT/legacy-links-snapshot-$label"
    local backup="$install_dir/.install-backup-123-456"
    local live_app="$install_dir/Darkbloom.app"
    local live_bin="$install_dir/bin"

    write_existing_bundle "$live_app" com.example.interrupted-candidate
    mkdir -p "$live_bin"
    printf 'candidate darkbloom\n' > "$live_bin/darkbloom"
    printf 'candidate enclave\n' > "$live_bin/darkbloom-enclave"
    printf 'candidate metallib\n' > "$live_bin/mlx.metallib"
    ln -s candidate-enclave "$live_bin/eigeninference-enclave"
    printf 'user-owned\n' > "$live_bin/unmanaged-tool"

    write_existing_bundle "$backup/Darkbloom.app" com.example.legacy-previous
    mkdir -p "$backup/bin"
    printf 'legacy darkbloom\n' > "$backup/bin/darkbloom"
    printf 'legacy enclave\n' > "$backup/bin/darkbloom-enclave"
    printf 'legacy metallib\n' > "$backup/bin/mlx.metallib"
    ln -s legacy-enclave "$backup/bin/eigeninference-enclave"
    : > "$backup/.links-snapshotted"

    bash "$installer" --recover-install-transactions-test "$install_dir"

    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$live_app/Contents/Info.plist")" = "com.example.legacy-previous"
    test "$(cat "$live_bin/darkbloom")" = "legacy darkbloom"
    test "$(cat "$live_bin/darkbloom-enclave")" = "legacy enclave"
    test "$(cat "$live_bin/mlx.metallib")" = "legacy metallib"
    test -L "$live_bin/eigeninference-enclave"
    test "$(readlink "$live_bin/eigeninference-enclave")" = \
        "legacy-enclave"
    test "$(cat "$live_bin/unmanaged-tool")" = "user-owned"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$install_dir/Darkbloom.app.interrupted-123-456/Contents/Info.plist")" \
        = "com.example.interrupted-candidate"
    test ! -e "$backup"
}

test_v1_prepared_journal_recovery() {
    local installer=$1
    local label=$2
    local kind=$3
    local install_dir="$ROOT/v1-prepared-$kind-$label"
    local backup="$install_dir/.install-backup-321-654"
    local staging="$install_dir/.install-staging-321-654"
    mkdir -p "$backup" "$staging"
    printf 'staging\n' > "$staging/sentinel"

    if [ "$kind" = app ]; then
        write_existing_bundle \
            "$install_dir/Darkbloom.app" com.example.v1-candidate
        installer_recovery_write_flat_layout \
            "$install_dir/bin" candidate
        write_existing_bundle \
            "$backup/Darkbloom.app" com.example.v1-previous
        installer_recovery_write_flat_layout "$backup/bin" previous
    else
        installer_recovery_write_flat_layout \
            "$install_dir/bin" candidate
        installer_recovery_write_flat_layout "$backup/bin" previous
    fi
    installer_recovery_write_v1_metadata "$backup" "$kind" prepared

    bash "$installer" --recover-install-transactions-test "$install_dir"

    if [ "$kind" = app ]; then
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$install_dir/Darkbloom.app/Contents/Info.plist")" = \
            "com.example.v1-previous"
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$install_dir/Darkbloom.app.interrupted-321-654/Contents/Info.plist")" \
            = "com.example.v1-candidate"
    fi
    test "$(cat "$install_dir/bin/darkbloom")" = "previous-darkbloom"
    test "$(cat "$install_dir/bin.interrupted-321-654/darkbloom")" = \
        "candidate-darkbloom"
    test ! -e "$backup"
    test ! -e "$staging"
}

test_v1_committed_journal_recovery() {
    local installer=$1
    local label=$2
    local kind=$3
    local install_dir="$ROOT/v1-committed-$kind-$label"
    local backup="$install_dir/.install-backup-321-654"
    local staging="$install_dir/.install-staging-321-654"
    mkdir -p "$backup" "$staging"
    printf 'staging\n' > "$staging/sentinel"

    if [ "$kind" = app ]; then
        installer_recovery_write_managed_app_layout \
            "$install_dir" committed-candidate
        write_existing_bundle \
            "$backup/Darkbloom.app" com.example.v1-foreign
        installer_recovery_write_v1_metadata "$backup" app committed 1
    else
        installer_recovery_write_flat_layout \
            "$install_dir/bin" committed-candidate
        installer_recovery_write_flat_layout \
            "$backup/bin" previous
        installer_recovery_write_v1_metadata "$backup" flat committed
    fi

    bash "$installer" --recover-install-transactions-test "$install_dir"

    if [ "$kind" = app ]; then
        test "$(cat \
            "$install_dir/Darkbloom.app/Contents/MacOS/darkbloom")" = \
            "committed-candidate-darkbloom"
        local preserved=()
        local candidate
        for candidate in "$install_dir"/Darkbloom.app.foreign-*; do
            if [ -e "$candidate" ] || [ -L "$candidate" ]; then
                preserved+=("$candidate")
            fi
        done
        test "${#preserved[@]}" -eq 1
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "${preserved[0]}/Contents/Info.plist")" = \
            "com.example.v1-foreign"
    else
        test "$(cat "$install_dir/bin/darkbloom")" = \
            "committed-candidate-darkbloom"
    fi
    test ! -e "$backup"
    test ! -e "$staging"
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

for compatibility_label in source embedded; do
    if [ "$compatibility_label" = source ]; then
        compatibility_installer="$REPO_ROOT/scripts/install.sh"
    else
        compatibility_installer="$REPO_ROOT/coordinator/api/install.sh"
    fi
    test_legacy_link_snapshot_recovery \
        "$compatibility_installer" "$compatibility_label"
    for compatibility_kind in app flat; do
        test_v1_prepared_journal_recovery \
            "$compatibility_installer" \
            "$compatibility_label" \
            "$compatibility_kind"
        test_v1_committed_journal_recovery \
            "$compatibility_installer" \
            "$compatibility_label" \
            "$compatibility_kind"
    done
done
