enum AccountlessInstallationReceiptWriter {
    /// Constructs XML with typed plutil operations, converts only after every
    /// field exists, and atomically publishes. Unknown observations are omitted.
    static let shellFunction = #"""
    write_accountless_receipt() (
      set -euo pipefail
      umask 077
      [[ $# == 13 ]] || exit 70
      destination=$1 binding=$2 stage=$3 failure=$4 os=$5 arch=$6 virtual_root=$7
      signed=$8 installer_exit=$9 installed=${10} absent=${11} tenant=${12} shell_exit=${13}
      case $stage in rootJobStarted|verifyingPayload|installing|verifyingInstallation|complete|failed) ;; *) exit 70;; esac
      case $failure in none|contextUnavailable|invalidPayload|installerFailed|installedPayloadInvalid|bootstrapAccountPresent|tenantIdentityInvalid|logCaptureFailed|shutdownFailed|unexpectedFailure) ;; *) exit 70;; esac
      for value in "$virtual_root" "$signed" "$installed" "$absent" "$tenant"; do
        [[ $value == true || $value == false || $value == unknown ]] || exit 70
      done
      for value in "$installer_exit" "$shell_exit"; do
        [[ $value == unknown ]] || { [[ $value =~ '^(0|[1-9][0-9]{0,2})$' ]] && (( value <= 255 )); } || exit 70
      done
      [[ $os == unknown || $os =~ '^[0-9]+(\.[0-9]+){0,3}$' ]] || exit 70
      [[ $arch == unknown || $arch == arm64 || $arch == x86_64 ]] || exit 70
      [[ -f $binding && ! -L $binding && $(/usr/bin/stat -f %z "$binding") -le 16384 ]] || exit 70
      [[ $(/usr/bin/plutil -extract schemaVersion raw -expect integer "$binding") == 1 ]] || exit 70
      [[ $(/usr/bin/plutil -extract source.kind raw -expect string "$binding") == apple_restore ]] || exit 70
      for key in candidateID bootstrapAttemptID source.installationID; do
        value=$(/usr/bin/plutil -extract "$key" raw -expect string "$binding")
        [[ $value =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] || exit 70
      done
      for key in source.ownershipSHA256 payload.releaseManifestSHA256 payload.guestSHA256 payload.bootstrapSHA256 payload.launchdSHA256 payload.installerSHA256; do
        value=$(/usr/bin/plutil -extract "$key" raw -expect string "$binding")
        [[ $value =~ '^[0-9a-f]{64}$' ]] || exit 70
      done
      if [[ $stage == complete ]]; then
        [[ $failure == none && $shell_exit == 0 && $virtual_root == true && $os != unknown && $arch == arm64 &&
           $signed == true && $installer_exit == 0 && $installed == true && $absent == true && $tenant == true ]] || exit 70
      elif [[ $stage == failed ]]; then
        [[ $failure != none && $shell_exit != unknown && $shell_exit != 0 ]] || exit 70
      else
        [[ $failure == none && $shell_exit == unknown ]] || exit 70
      fi
      [[ $destination == /*/receipt.json && -d ${destination:h} && ! -L ${destination:h} &&
         $(/usr/bin/stat -f '%u:%Lp' "${destination:h}") == "$EUID:700" ]] || exit 70
      previous=''
      if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination && $(/usr/bin/stat -f '%u:%l:%Lp' "$destination") == "$EUID:1:600" ]] || exit 70
        previous=$(/usr/bin/stat -f '%d:%i' "$destination")
        for key in schemaVersion candidateID bootstrapAttemptID source.name source.installationID source.kind source.reference source.ownershipSHA256 payload.releaseManifestSHA256 payload.guestSHA256 payload.bootstrapSHA256 payload.launchdSHA256 payload.installerSHA256; do
          [[ $(/usr/bin/plutil -extract "binding.$key" raw "$destination") == $(/usr/bin/plutil -extract "$key" raw "$binding") ]] || exit 70
        done
        prior_stage=$(/usr/bin/plutil -extract stage raw "$destination")
        [[ $prior_stage != failed ]] || exit 70
        [[ $prior_stage != complete || ( $stage == failed && $failure == shutdownFailed ) ]] || exit 70
      fi
      temporary=$(/usr/bin/mktemp "${destination}.XXXXXX")
      trap '[[ -z $temporary ]] || /bin/rm -f "$temporary"' EXIT
      /usr/bin/plutil -create xml1 "$temporary"
      /usr/bin/plutil -insert schemaVersion -integer 1 "$temporary"
      /usr/bin/plutil -insert binding -json "$(/bin/cat "$binding")" "$temporary"
      /usr/bin/plutil -insert stage -string "$stage" "$temporary"
      /usr/bin/plutil -insert error -string "$failure" "$temporary"
      [[ $shell_exit == unknown ]] || /usr/bin/plutil -insert shellExitCode -integer "$shell_exit" "$temporary"
      [[ $os == unknown ]] || /usr/bin/plutil -insert guestOperatingSystemVersion -string "$os" "$temporary"
      [[ $arch == unknown ]] || /usr/bin/plutil -insert guestArchitecture -string "$arch" "$temporary"
      [[ $virtual_root == unknown ]] || /usr/bin/plutil -insert virtualizedRootObserved -bool "$virtual_root" "$temporary"
      if [[ $os != unknown && $arch == arm64 && $virtual_root == true && $signed != unknown ]]; then
        /usr/bin/plutil -insert installation -dictionary "$temporary"
        /usr/bin/plutil -insert installation.schemaVersion -integer 2 "$temporary"
        /usr/bin/plutil -insert installation.source -json "$(/usr/bin/plutil -extract source json -o - "$binding")" "$temporary"
        /usr/bin/plutil -insert installation.payload -json "$(/usr/bin/plutil -extract payload json -o - "$binding")" "$temporary"
        /usr/bin/plutil -insert installation.rootJobID -string "$(/usr/bin/plutil -extract bootstrapAttemptID raw "$binding")" "$temporary"
        /usr/bin/plutil -insert installation.method -string firstBootRootJob "$temporary"
        /usr/bin/plutil -insert installation.bootstrapAccountPolicy -string neverProvisioned "$temporary"
        installation_phase=rootJobStarted
        if [[ ( $stage == complete || $stage == failed ) && $signed == true && $installer_exit == 0 &&
              $installed == true && $absent == true && $tenant == true ]]; then installation_phase=installationComplete; fi
        /usr/bin/plutil -insert installation.phase -string "$installation_phase" "$temporary"
        /usr/bin/plutil -insert installation.guestOperatingSystemVersion -string "$os" "$temporary"
        /usr/bin/plutil -insert installation.guestArchitecture -string "$arch" "$temporary"
        /usr/bin/plutil -insert installation.virtualizedRootObserved -bool true "$temporary"
        /usr/bin/plutil -insert installation.signedInstallerVerified -bool "$signed" "$temporary"
        [[ $installer_exit == unknown ]] || /usr/bin/plutil -insert installation.installerExitCode -integer "$installer_exit" "$temporary"
        [[ $installed == unknown ]] || /usr/bin/plutil -insert installation.installedPayloadVerified -bool "$installed" "$temporary"
        [[ $absent == unknown ]] || /usr/bin/plutil -insert installation.bootstrapAccountAbsent -bool "$absent" "$temporary"
        [[ $tenant == unknown ]] || /usr/bin/plutil -insert installation.tenantIdentityVerified -bool "$tenant" "$temporary"
      fi
      /usr/bin/plutil -convert json "$temporary"
      /bin/chmod 0600 "$temporary"
      if [[ -n $previous ]]; then
        [[ -f $destination && ! -L $destination && $(/usr/bin/stat -f '%d:%i' "$destination") == $previous &&
           $(/usr/bin/stat -f '%u:%l:%Lp' "$destination") == "$EUID:1:600" ]] || exit 70
        /bin/mv -f "$temporary" "$destination"
      else
        /bin/ln -h "$temporary" "$destination"
        /bin/rm -f "$temporary"
      fi
      temporary=''
      /bin/sync
    )
    """#
}
