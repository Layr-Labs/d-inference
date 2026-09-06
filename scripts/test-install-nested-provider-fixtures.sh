# Shared nested-provider fixtures. Sourced by the signed atomic suite and by
# the shell-only harness (which explicitly stubs codesign, without a compiler).

make_nested_provider_artifact() {
    local output=$1
    local base=$2
    local stage="$ROOT/nested-stage-$RANDOM"
    local app="$stage/Darkbloom.app"
    local helper="$app/Contents/Helpers/DarkbloomProvider.app"
    mkdir -p "$stage"
    tar xzf "$base" -C "$stage"
    mkdir -p "$helper/Contents" "$app/Contents/Resources"
    cp -pR "$app/Contents/MacOS" "$helper/Contents/MacOS"
    mkdir -p "$helper/Contents/Resources/darkbloom-runtime-capabilities"
    shopt -s nullglob
    local resource
    for resource in "$app/Contents/Resources"/*.bundle; do
        cp -pR "$resource" "$helper/Contents/Resources/"
    done
    cp -p "$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1" \
        "$helper/Contents/Resources/darkbloom-runtime-capabilities/"
    cp "$app/Contents/Info.plist" "$helper/Contents/Info.plist"
    printf 'fixture provisioning profile, sealed by the app signature\n' \
        > "$app/Contents/embedded.provisionprofile"
    cp "$app/Contents/embedded.provisionprofile" "$helper/Contents/embedded.provisionprofile"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable DarkbloomApp' "$app/Contents/Info.plist"
    install -m 0755 "$ROOT/legacy" "$app/Contents/MacOS/DarkbloomApp"
    rm "$app/Contents/MacOS/darkbloom"
    ln -s ../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom \
        "$app/Contents/MacOS/darkbloom"

    codesign --force --sign - "$helper/Contents/MacOS/mlx.metallib"
    codesign --force --sign - "$helper/Contents/MacOS/darkbloom-enclave"
    codesign --force --sign - "$helper/Contents/MacOS/darkbloom"
    codesign --force --sign - "$helper"
    # Match the release signing order: carry signed code and metallib xattrs
    # out of the sealed helper, then seal the GUI. Only the CLI is an alias.
    /usr/bin/ditto "$helper/Contents/MacOS/mlx.metallib" "$app/Contents/MacOS/mlx.metallib"
    /usr/bin/ditto "$helper/Contents/MacOS/darkbloom-enclave" "$app/Contents/MacOS/darkbloom-enclave"
    codesign --force --sign - "$app"
    codesign --verify --deep --strict "$app"
    install -m 0755 "$helper/Contents/MacOS/darkbloom" "$stage/bin/darkbloom"
    install -m 0755 "$helper/Contents/MacOS/darkbloom-enclave" "$stage/bin/darkbloom-enclave"
    /usr/bin/ditto "$helper/Contents/MacOS/mlx.metallib" "$stage/bin/mlx.metallib"
    test ! -L "$stage/bin/darkbloom"
    cmp "$stage/bin/darkbloom" "$helper/Contents/MacOS/darkbloom"
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

make_nested_provider_variant() {
    local output=$1
    local base=$2
    local variant=$3
    local stage="$ROOT/nested-variant-$RANDOM"
    local app="$stage/Darkbloom.app"
    local helper="$app/Contents/Helpers/DarkbloomProvider.app"
    local bin="$helper/Contents/MacOS"
    mkdir -p "$stage"
    tar xzf "$base" -C "$stage"
    case "$variant" in
        helper-id) /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.other' "$helper/Contents/Info.plist" ;;
        helper-executable) /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable other' "$helper/Contents/Info.plist" ;;
        helper-package) /usr/libexec/PlistBuddy -c 'Set :CFBundlePackageType BNDL' "$helper/Contents/Info.plist" ;;
        helper-version)
            /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.0.0' "$helper/Contents/Info.plist"
            /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9.0.0' "$helper/Contents/Info.plist" ;;
        helper-build) /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9.0.0' "$helper/Contents/Info.plist" ;;
        helper-invalid-version)
            /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 02.0.0' "$helper/Contents/Info.plist"
            /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 02.0.0' "$helper/Contents/Info.plist" ;;
        helper-plist) rm "$helper/Contents/Info.plist" ;;
        helper-plist-link)
            rm "$helper/Contents/Info.plist"
            ln -s ../../../Info.plist "$helper/Contents/Info.plist" ;;
        helper-profile) rm "$helper/Contents/embedded.provisionprofile" ;;
        helper-empty-profile) : > "$helper/Contents/embedded.provisionprofile" ;;
        helper-profile-mismatch) printf 'different\n' > "$helper/Contents/embedded.provisionprofile" ;;
        helper-profile-link)
            rm "$helper/Contents/embedded.provisionprofile"
            ln -s ../../../embedded.provisionprofile "$helper/Contents/embedded.provisionprofile" ;;
        outer-profile) rm "$app/Contents/embedded.provisionprofile" ;;
        outer-id) /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.other' "$app/Contents/Info.plist" ;;
        outer-executable) /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable darkbloom' "$app/Contents/Info.plist" ;;
        gui-mode) chmod 0644 "$app/Contents/MacOS/DarkbloomApp" ;;
        missing-gui) rm "$app/Contents/MacOS/DarkbloomApp" ;;
        nested-cli-hash) printf '\ntampered\n' >> "$bin/darkbloom" ;;
        flat-cli-hash) printf '\ntampered\n' >> "$stage/bin/darkbloom" ;;
        nested-metal-hash) printf '\ntampered\n' >> "$bin/mlx.metallib" ;;
        outer-metal-hash) printf '\ntampered\n' >> "$app/Contents/MacOS/mlx.metallib" ;;
        flat-metal-hash) printf '\ntampered\n' >> "$stage/bin/mlx.metallib" ;;
        nested-enclave-hash) printf '\ntampered\n' >> "$bin/darkbloom-enclave" ;;
        outer-enclave-hash) printf '\ntampered\n' >> "$app/Contents/MacOS/darkbloom-enclave" ;;
        flat-enclave-hash) printf '\ntampered\n' >> "$stage/bin/darkbloom-enclave" ;;
        nested-cli-mode) chmod 0644 "$bin/darkbloom" ;;
        nested-metal-mode) chmod 0755 "$bin/mlx.metallib" ;;
        nested-enclave-mode) chmod 0644 "$bin/darkbloom-enclave" ;;
        missing-metal) rm "$bin/mlx.metallib" ;;
        missing-enclave) rm "$bin/darkbloom-enclave" ;;
        missing-resources) rm -rf "$helper/Contents/Resources" ;;
        resource-parity) printf 'different\n' >> "$helper/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal" ;;
        missing-bundle) rm -rf "$helper/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle" ;;
        extra-bundle) mkdir "$helper/Contents/Resources/unexpected.bundle" ;;
        missing-nested-marker) rm "$helper/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1" ;;
        missing-outer-marker) rm "$app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1" ;;
        outer-cli-regular)
            rm "$app/Contents/MacOS/darkbloom"
            cp -p "$bin/darkbloom" "$app/Contents/MacOS/darkbloom" ;;
        flat-cli-link)
            rm "$stage/bin/darkbloom"
            ln -s ../Darkbloom.app/Contents/MacOS/darkbloom "$stage/bin/darkbloom" ;;
        alias-target)
            rm "$app/Contents/MacOS/darkbloom"
            ln -s ../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom-enclave "$app/Contents/MacOS/darkbloom" ;;
        *) echo "unknown nested fixture $variant" >&2; return 1 ;;
    esac
    tar czf "$output" -C "$stage" .
    rm -rf "$stage"
}

assert_nested_provider_installed() {
    local install_dir=$1
    local app="$install_dir/Darkbloom.app"
    local helper="$app/Contents/Helpers/DarkbloomProvider.app"
    test -L "$install_dir/bin/darkbloom"
    test "$(readlink "$install_dir/bin/darkbloom")" = '../Darkbloom.app/Contents/MacOS/darkbloom'
    test -L "$app/Contents/MacOS/darkbloom"
    test "$(readlink "$app/Contents/MacOS/darkbloom")" = '../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom'
    test -f "$helper/Contents/MacOS/darkbloom"
    test ! -L "$helper/Contents/MacOS/darkbloom"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" = DarkbloomApp
    local file
    for file in mlx.metallib darkbloom-enclave; do
        test ! -L "$helper/Contents/MacOS/$file"
        test ! -L "$app/Contents/MacOS/$file"
        cmp "$helper/Contents/MacOS/$file" "$app/Contents/MacOS/$file"
    done
    cmp "$app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal" \
        "$helper/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal"
    test ! -e "$helper/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1"
    # Resolve the installed two-link chain and exercise the fixture's physical
    # bundle resource lookup, never a real provider or a user's install.
    DARKBLOOM_NO_UPDATE_CHECK=1 DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18 \
        MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1 MLX_GATHER_QMM_EXPERT_SLICES=1 \
        "$install_dir/bin/darkbloom" runtime-smoke
    installer_recovery_assert_no_transaction_debris "$install_dir" "nested install"
}

run_nested_provider_tests() {
    local nested="$ROOT/nested-provider.tar.gz"
    make_nested_provider_artifact "$nested" "$VALID"
    local label
    local installer
    local install_dir
    local variant
    local archive
    for label in source embedded; do
        if [ "$label" = source ]; then installer="$REPO_ROOT/scripts/install.sh"
        else installer="$REPO_ROOT/coordinator/api/install.sh"; fi
        install_dir="$ROOT/nested-upgrade-$label"
        run_install_with "$installer" "$FLAT_LEGACY" "$install_dir"
        run_install_with "$installer" "$nested" "$install_dir"
        assert_nested_provider_installed "$install_dir"
        # Generic nofollow mode validation must still refuse the outer alias.
        if bash "$installer" --verify-release-payload-modes-test \
            "$install_dir/Darkbloom.app/Contents/MacOS" "outer alias" >/dev/null 2>&1; then
            installer_recovery_fail 'generic payload check followed the CLI alias'; return 1
        fi
        # Equal-version repair between both layouts remains allowed. The
        # installed version transition policy is exercised unchanged.
        run_install_with "$installer" "$VALID" "$install_dir"
        test ! -L "$install_dir/Darkbloom.app/Contents/MacOS/darkbloom"
        run_install_with "$installer" "$nested" "$install_dir"
        assert_nested_provider_installed "$install_dir"
        local before
        before=$(shasum -a 256 "$install_dir/bin/darkbloom")
        for variant in \
            helper-id helper-executable helper-package helper-version helper-build \
            helper-invalid-version helper-plist helper-plist-link helper-profile \
            helper-empty-profile helper-profile-mismatch helper-profile-link \
            outer-profile outer-id outer-executable gui-mode missing-gui \
            nested-cli-hash flat-cli-hash nested-metal-hash outer-metal-hash flat-metal-hash \
            nested-enclave-hash outer-enclave-hash flat-enclave-hash nested-cli-mode \
            nested-metal-mode nested-enclave-mode missing-metal missing-enclave \
            missing-resources resource-parity missing-bundle extra-bundle missing-nested-marker \
            missing-outer-marker outer-cli-regular flat-cli-link alias-target
        do
            archive="$ROOT/nested-$variant.tar.gz"
            [ -f "$archive" ] || make_nested_provider_variant "$archive" "$nested" "$variant"
            if run_install_with "$installer" "$archive" "$install_dir" \
                >"$ROOT/nested-rejection.log" 2>&1; then
                installer_recovery_fail "$label accepted nested variant $variant"; return 1
            fi
            # Check the actual gate: neither an invalid signature nor an
            # unrelated shell failure may make a validation fixture pass.
            local expected_error
            case "$variant" in
                helper-id|outer-id) expected_error='CFBundleIdentifier must be io.darkbloom.provider' ;;
                helper-executable) expected_error='CFBundleExecutable must be darkbloom' ;;
                helper-package) expected_error='CFBundlePackageType must be APPL' ;;
                helper-version|helper-build|helper-invalid-version) expected_error='matching canonical bundle versions' ;;
                helper-plist) expected_error='regular nonempty Info.plist' ;;
                helper-profile|helper-empty-profile|outer-profile) expected_error='regular nonempty embedded.provisionprofile' ;;
                helper-profile-mismatch) expected_error='profile must match the GUI' ;;
                helper-plist-link|helper-profile-link|flat-cli-link) expected_error='unsupported node type' ;;
                outer-executable) expected_error='CFBundleExecutable must be DarkbloomApp' ;;
                gui-mode|nested-cli-mode|nested-enclave-mode) expected_error='expected 0755' ;;
                nested-metal-mode) expected_error='expected 0644' ;;
                missing-gui|missing-metal|missing-enclave) expected_error='must be a regular non-symlink file' ;;
                nested-enclave-hash|outer-enclave-hash|flat-enclave-hash) expected_error='enclave must match the outer and flat copies' ;;
                *-hash) expected_error='hash mismatch' ;;
                missing-resources) expected_error='ancestor must be a real directory' ;;
                resource-parity) expected_error='SwiftPM resources must match' ;;
                missing-bundle|extra-bundle) expected_error='duplicate every outer SwiftPM resource bundle' ;;
                missing-nested-marker|missing-outer-marker) expected_error='paged marker must match' ;;
                outer-cli-regular) expected_error='exact CLI compatibility alias' ;;
                alias-target) expected_error='unexpected target' ;;
                *) installer_recovery_fail "missing expected error for $variant"; return 1 ;;
            esac
            if ! grep -F "$expected_error" "$ROOT/nested-rejection.log" >/dev/null; then
                cat "$ROOT/nested-rejection.log" >&2
                installer_recovery_fail "$variant did not fail at its intended gate"; return 1
            fi
            test "$(shasum -a 256 "$install_dir/bin/darkbloom")" = "$before"
            assert_nested_provider_installed "$install_dir"
        done

        local direction
        local checkpoint
        local previous
        local candidate
        for direction in to-nested from-nested flat-to-nested; do
            case "$direction" in
                to-nested) previous=$VALID; candidate=$nested ;;
                from-nested) previous=$nested; candidate=$VALID ;;
                flat-to-nested) previous=$FLAT_LEGACY; candidate=$nested ;;
            esac
            for checkpoint in transaction-prepared previous-app-moved previous-bin-moved staged-app-moved managed-links-installed app-transaction-committed; do
                # A flat predecessor has no app to move at this checkpoint.
                if [ "$previous" = "$FLAT_LEGACY" ] && [ "$checkpoint" = previous-app-moved ]; then continue; fi
                local recovery_dir="$ROOT/nested-recovery-$label-$direction-$checkpoint"
                run_install_with "$installer" "$previous" "$recovery_dir"
                installer_recovery_expect_install_crash "$installer" "$candidate" "$recovery_dir" "$checkpoint"
                bash "$installer" --recover-install-transactions-test "$recovery_dir"
                bash "$installer" --recover-install-transactions-test "$recovery_dir"
                local expected=$previous
                [ "$checkpoint" != app-transaction-committed ] || expected=$candidate
                artifact_hashes "$expected"
                test "$(hash_file "$recovery_dir/bin/darkbloom")" = "$BINARY_HASH"
                if [ "$expected" = "$nested" ]; then assert_nested_provider_installed "$recovery_dir"
                elif [ "$expected" = "$FLAT_LEGACY" ]; then
                    test ! -e "$recovery_dir/Darkbloom.app"
                    test ! -L "$recovery_dir/bin/darkbloom"
                else test ! -L "$recovery_dir/Darkbloom.app/Contents/MacOS/darkbloom"; fi
                installer_recovery_assert_no_transaction_debris "$recovery_dir" "nested recovery"
            done
        done
        # A post-commit alias or helper mutation must fail the existing tree
        # fingerprint gate, preserve the mutated tree, and restore the old app.
        for variant in alias executable; do
            local recovery_dir="$ROOT/nested-mutated-$label-$variant"
            run_install_with "$installer" "$VALID" "$recovery_dir"
            installer_recovery_expect_install_crash "$installer" "$nested" "$recovery_dir" app-transaction-committed
            local mutated="$recovery_dir/Darkbloom.app"
            if [ "$variant" = alias ]; then
                rm "$mutated/Contents/MacOS/darkbloom"
                ln -s ../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom-enclave "$mutated/Contents/MacOS/darkbloom"
            else
                printf '\nmodified nested executable\n' >> "$mutated/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom"
            fi
            bash "$installer" --recover-install-transactions-test "$recovery_dir"
            bash "$installer" --recover-install-transactions-test "$recovery_dir"
            artifact_hashes "$VALID"
            test "$(hash_file "$recovery_dir/bin/darkbloom")" = "$BINARY_HASH"
            test ! -L "$recovery_dir/Darkbloom.app/Contents/MacOS/darkbloom"
            local preserved=("$recovery_dir"/Darkbloom.app.interrupted-*)
            test "${#preserved[@]}" -eq 1
            if [ "$variant" = alias ]; then
                test "$(readlink "${preserved[0]}/Contents/MacOS/darkbloom")" = '../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom-enclave'
            else
                grep -aF 'modified nested executable' "${preserved[0]}/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom" >/dev/null
            fi
            installer_recovery_assert_no_transaction_debris "$recovery_dir" 'mutated nested recovery'
        done
    done
    echo 'nested provider installer success, rejection, and recovery fixtures passed'
}
