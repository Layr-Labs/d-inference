# Shared recovery fixtures sourced by test-install-atomic.sh after its signed
# app and flat release artifacts have been built. Checkpoint and historical
# compatibility scenarios live in focused sibling modules.

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
        "$install_dir"/.install-legacy-* \
        "$install_dir"/*.interrupted-*
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
    local status=0
    DARKBLOOM_INSTALL_TEST_CRASH_POINT="$checkpoint" \
        PATH="$CLT_SHIMS:$PATH" \
        bash "$installer" --install-bundle-test \
            "$archive" "$install_dir" "$BINARY_HASH" "$METALLIB_HASH" \
            "$FAN_HELPER_REQUIREMENT" \
        || status=$?
    if [ "$status" -eq 0 ]; then
        installer_recovery_fail \
            "$installer survived injected install crash $checkpoint"
        return 1
    fi
    [ "$status" -eq 137 ] || {
        installer_recovery_fail \
            "$installer failed before injected install crash $checkpoint (status $status)"
        return 1
    }
}

installer_recovery_expect_recovery_crash() {
    local installer=$1
    local install_dir=$2
    local checkpoint=$3
    local status=0
    DARKBLOOM_INSTALL_TEST_CRASH_POINT="$checkpoint" \
        bash "$installer" --recover-install-transactions-test "$install_dir" \
        || status=$?
    if [ "$status" -eq 0 ]; then
        installer_recovery_fail \
            "$installer survived injected recovery crash $checkpoint"
        return 1
    fi
    [ "$status" -eq 137 ] || {
        installer_recovery_fail \
            "$installer failed before injected recovery crash $checkpoint (status $status)"
        return 1
    }
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
