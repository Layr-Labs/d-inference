# Historical legacy and version-one transaction fixtures. Shared filesystem
# helpers are loaded by test-install-atomic.sh before this module.

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
