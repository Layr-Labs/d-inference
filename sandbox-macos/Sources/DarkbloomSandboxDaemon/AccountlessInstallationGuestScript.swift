enum AccountlessInstallationGuestScript {
    static let shell = #"""
    #!/bin/zsh
    set -euo pipefail
    umask 077
    [[ $# == 2 && $EUID == 0 ]] || exit 70
    # Refuse a physical host before any directory or receipt is created.
    [[ $(/usr/sbin/sysctl -n kern.hv_vmm_present) == 1 ]] || exit 70
    attempt=$1 binding_sha=$2
    [[ $attempt =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' &&
       $binding_sha =~ '^[0-9a-f]{64}$' ]] || exit 70
    stage_root="/Library/Application Support/DarkbloomSandboxBootstrap/$attempt"
    [[ ${0:A} == "$stage_root/first-boot.zsh" ]] || exit 70
    for directory in /Library '/Library/Application Support' '/Library/Application Support/DarkbloomSandboxBootstrap' "$stage_root" "$stage_root/release" "$stage_root/release/guest"; do
      [[ -d $directory && ! -L $directory && $(/usr/bin/stat -f %u "$directory") == 0 ]] || exit 70
      mode=$(/usr/bin/stat -f %Lp "$directory")
      (( (8#$mode & 8#022) == 0 )) || exit 70
    done
    for file in first-boot.zsh receipt-writer.zsh installation-checks.zsh installation-binding.json release/release-manifest.json release/guest/darkbloom-sandbox-guest release/guest/darkbloom-sandbox-bootstrap.sh release/guest/io.darkbloom.sandbox.guest.plist release/guest/install-sandbox-guest.sh; do
      [[ -f "$stage_root/$file" && ! -L "$stage_root/$file" && $(/usr/bin/stat -f '%u:%l' "$stage_root/$file") == 0:1 ]] || exit 70
      mode=$(/usr/bin/stat -f %Lp "$stage_root/$file")
      (( (8#$mode & 8#022) == 0 )) || exit 70
    done
    source "$stage_root/receipt-writer.zsh"
    source "$stage_root/installation-checks.zsh"
    binding="$stage_root/installation-binding.json"
    [[ $(hash_file "$binding") == "$binding_sha" &&
       $(/usr/bin/plutil -extract bootstrapAttemptID raw "$binding" | /usr/bin/tr A-F a-f) == "$attempt" ]] || exit 70
    /bin/mkdir -m 0700 "$stage_root/result" || exit 70
    receipt="$stage_root/result/receipt.json"
    stage=rootJobStarted failure=none os=unknown arch=unknown virtual_root=true signed=unknown
    installer_exit=unknown installed=unknown absent=unknown tenant=unknown
    command_exit=0 capture_exit=0 capture_overflow=false diagnostic_bytes=0
    publish() {
      write_accountless_receipt "$receipt" "$binding" "$stage" "$failure" "$os" "$arch" "$virtual_root" \
        "$signed" "$installer_exit" "$installed" "$absent" "$tenant" "${1:-unknown}"
    }
    publish
    TRAPEXIT() {
      local code=$?
      if (( code != 0 )); then
        stage=failed
        [[ $failure != none ]] || failure=unexpectedFailure
        publish "$code" || true
      fi
    }
    os=$(/usr/bin/sw_vers -productVersion) || { failure=contextUnavailable; exit 70; }
    arch=$(/usr/bin/uname -m) || { failure=contextUnavailable; exit 70; }
    virtual_root=false
    [[ $(/usr/sbin/sysctl -n kern.hv_vmm_present) == 1 ]] && virtual_root=true
    [[ $os =~ '^[0-9]+(\.[0-9]+){0,3}$' && $arch == arm64 && $virtual_root == true ]] || { failure=contextUnavailable; exit 70; }
    guest_sha=$(/usr/bin/plutil -extract payload.guestSHA256 raw "$binding")
    bootstrap_sha=$(/usr/bin/plutil -extract payload.bootstrapSHA256 raw "$binding")
    launchd_sha=$(/usr/bin/plutil -extract payload.launchdSHA256 raw "$binding")
    installer_sha=$(/usr/bin/plutil -extract payload.installerSHA256 raw "$binding")
    manifest_sha=$(/usr/bin/plutil -extract payload.releaseManifestSHA256 raw "$binding")
    guest_requirement='anchor apple generic and identifier "io.darkbloom.sandbox.guest" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
    manifest_requirement='anchor apple generic and identifier "io.darkbloom.sandbox.release-manifest" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
    payload="$stage_root/release/guest"
    stage=verifyingPayload
    publish
    signed=false
    [[ $(hash_file "$payload/darkbloom-sandbox-guest") == "$guest_sha" &&
       $(hash_file "$payload/darkbloom-sandbox-bootstrap.sh") == "$bootstrap_sha" &&
       $(hash_file "$payload/io.darkbloom.sandbox.guest.plist") == "$launchd_sha" &&
       $(hash_file "$payload/install-sandbox-guest.sh") == "$installer_sha" &&
       $(hash_file "$stage_root/release/release-manifest.json") == "$manifest_sha" ]] || { failure=invalidPayload; exit 70; }
    /usr/bin/codesign --verify --strict "-R=$guest_requirement" "$payload/darkbloom-sandbox-guest" >/dev/null 2>&1 || { failure=invalidPayload; exit 70; }
    /usr/bin/codesign --verify --strict "-R=$manifest_requirement" "$stage_root/release/release-manifest.json" >/dev/null 2>&1 || { failure=invalidPayload; exit 70; }
    signed=true
    observe_accounts || { failure=contextUnavailable; exit 70; }
    [[ $human_count == 0 && $lume_count == 0 ]] || { absent=false; failure=bootstrapAccountPresent; exit 70; }
    [[ ! -e /var/db/.AppleSetupDone ]] || { failure=contextUnavailable; exit 70; }
    stage=installing
    publish
    if run_bounded_log "$stage_root/result/installer.log" /bin/zsh -f "$payload/install-sandbox-guest.sh" --install; then
      installer_exit=$command_exit
      [[ $capture_overflow == false && $capture_exit == 0 ]] || { failure=logCaptureFailed; exit 70; }
      [[ $installer_exit == 0 ]] || { failure=installerFailed; exit 70; }
    else failure=logCaptureFailed; exit 70; fi
    stage=verifyingInstallation
    publish
    if verify_installed_payload; then installed=true
    else installed=false; failure=installedPayloadInvalid; exit 70; fi
    observe_accounts || { failure=contextUnavailable; exit 70; }
    if [[ $human_count == 0 && $lume_count == 0 ]]; then absent=true
    else absent=false; failure=bootstrapAccountPresent; exit 70; fi
    [[ ! -e /var/db/.AppleSetupDone ]] || { failure=contextUnavailable; exit 70; }
    if run_bounded_log "$stage_root/result/helper.log" /usr/local/libexec/darkbloom-sandbox-guest validate-tenant-identity; then
      [[ $capture_overflow == false && $capture_exit == 0 ]] || { failure=logCaptureFailed; exit 70; }
      if [[ $command_exit == 0 ]]; then tenant=true
      else tenant=false; failure=tenantIdentityInvalid; exit 70; fi
    else failure=logCaptureFailed; exit 70; fi
    stage=complete
    publish 0
    /sbin/shutdown -h now || { failure=shutdownFailed; exit 70; }
    """#
}
