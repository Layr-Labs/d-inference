import Foundation
import SandboxRuntime

struct BaseGuestInstallationReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let guestSHA256: String
    let bootstrapSHA256: String
    let launchdSHA256: String
    let installerSHA256: String
    let guestOperatingSystemVersion: String
    let guestArchitecture: String
    let bootstrapRetired: Bool

    func validate(release: BaseGuestRelease) throws {
        guard schemaVersion == 1, bootstrapRetired, guestArchitecture == "arm64",
              !guestOperatingSystemVersion.isEmpty, guestOperatingSystemVersion.utf8.count < 64,
              guestSHA256 == release.hashes["darkbloom-sandbox-guest"],
              bootstrapSHA256 == release.hashes["darkbloom-sandbox-bootstrap.sh"],
              launchdSHA256 == release.hashes["io.darkbloom.sandbox.guest.plist"],
              installerSHA256 == release.hashes["install-sandbox-guest.sh"] else {
            throw BaseGuestPreparationError.invalidReceipt
        }
    }
}

enum BaseGuestInstallation {
    static func request(staging: BaseGuestStaging, release: BaseGuestRelease) throws -> SandboxGuestCommandRequest {
        guard staging.directory.lastPathComponent.hasPrefix("bootstrap-"),
              UUID(uuidString: String(staging.directory.lastPathComponent.dropFirst(10))) != nil,
              staging.hashes == release.hashes else { throw BaseGuestPreparationError.invalidRelease }
        return try SandboxGuestCommandRequest(idempotencyKey: UUID(), executable: "/bin/zsh",
            arguments: ["-f", "-c", rootInvocation, "darkbloom-bootstrap-auth",
                script, "darkbloom-base-install",
                staging.directory.lastPathComponent,
                release.hashes["darkbloom-sandbox-guest"]!,
                release.hashes["darkbloom-sandbox-bootstrap.sh"]!,
                release.hashes["io.darkbloom.sandbox.guest.plist"]!,
                release.hashes["install-sandbox-guest.sh"]!],
            workingDirectory: "/Users/lume", timeoutSeconds: 300)
    }

    // The pinned unattended preset uses this public, temporary credential.
    // It is used only after checking the known VM bootstrap identity, sent on
    // stdin to sudo, and retired by the fixed installation script before any
    // tenant is admitted. This never requests a physical host's credentials.
    static let rootInvocation = #"""
    set -euo pipefail
    [[ $(/usr/sbin/sysctl -n kern.hv_vmm_present) == 1 ]] || exit 70
    [[ $(/usr/bin/id -u) == 501 && $(/usr/bin/id -un) == lume ]] || exit 70
    /usr/bin/printf '%s\n' 'lume' | /usr/bin/sudo -S -p '' /bin/zsh -f -c "$@"
    """#

    // This is fixed operator-owned provisioning code. Values are individual
    // argv entries, never interpolated into executable shell source.
    static let script = #"""
    set -euo pipefail
    umask 077
    [[ $EUID == 0 && $# == 5 ]] || exit 70
    [[ $(/usr/sbin/sysctl -n kern.hv_vmm_present) == 1 ]] || exit 70
    shared="/Volumes/My Shared Files/$1"
    for attempt in {1..60}; do
      [[ -f "$shared/install-sandbox-guest.sh" ]] && break
      /bin/sleep 1
    done
    [[ -d "$shared" && ! -L "$shared" ]] || exit 70
    hash_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
    [[ $(hash_file "$shared/darkbloom-sandbox-guest") == "$2" ]] || exit 70
    [[ $(hash_file "$shared/darkbloom-sandbox-bootstrap.sh") == "$3" ]] || exit 70
    [[ $(hash_file "$shared/io.darkbloom.sandbox.guest.plist") == "$4" ]] || exit 70
    [[ $(hash_file "$shared/install-sandbox-guest.sh") == "$5" ]] || exit 70
    /bin/zsh -f "$shared/install-sandbox-guest.sh" --install --retire-lume-bootstrap >/dev/null
    requirement='anchor apple generic and identifier "io.darkbloom.sandbox.guest" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
    /usr/bin/codesign --verify --strict "-R=$requirement" /usr/local/libexec/darkbloom-sandbox-guest
    [[ $(hash_file /usr/local/libexec/darkbloom-sandbox-guest) == "$2" ]] || exit 70
    [[ $(hash_file /usr/local/libexec/darkbloom-sandbox-bootstrap.sh) == "$3" ]] || exit 70
    [[ $(hash_file /Library/LaunchDaemons/io.darkbloom.sandbox.guest.plist) == "$4" ]] || exit 70
    users=$(/usr/bin/dscl . -list /Users)
    if print -r -- "$users" | /usr/bin/grep -qx lume; then exit 70; fi
    [[ $(/usr/bin/id -u darkbloomtenant) == 2001 ]] || exit 70
    [[ $(/usr/bin/id -g darkbloomtenant) == 2001 ]] || exit 70
    for group in admin wheel operator; do
      membership=$(/usr/bin/dsmemberutil checkmembership -U darkbloomtenant -G "$group")
      [[ $membership == *'is not a member'* ]] || exit 70
    done
    for destination in /usr/local/libexec/darkbloom-sandbox-guest /usr/local/libexec/darkbloom-sandbox-bootstrap.sh /Library/LaunchDaemons/io.darkbloom.sandbox.guest.plist; do
      [[ ! -L $destination && $(/usr/bin/stat -f %u "$destination") == 0 ]] || exit 70
      mode=$(/usr/bin/stat -f %Lp "$destination")
      (( (8#$mode & 8#022) == 0 )) || exit 70
    done
    receipt=/var/db/darkbloom-sandbox/base-installation.json
    [[ ! -e $receipt && ! -L $receipt ]] || exit 70
    /usr/bin/plutil -create json "$receipt"
    /usr/bin/plutil -insert schemaVersion -integer 1 "$receipt"
    /usr/bin/plutil -insert guestSHA256 -string "$2" "$receipt"
    /usr/bin/plutil -insert bootstrapSHA256 -string "$3" "$receipt"
    /usr/bin/plutil -insert launchdSHA256 -string "$4" "$receipt"
    /usr/bin/plutil -insert installerSHA256 -string "$5" "$receipt"
    /usr/bin/plutil -insert guestOperatingSystemVersion -string "$(/usr/bin/sw_vers -productVersion)" "$receipt"
    /usr/bin/plutil -insert guestArchitecture -string "$(/usr/bin/uname -m)" "$receipt"
    /usr/bin/plutil -insert bootstrapRetired -bool true "$receipt"
    /bin/chmod 0600 "$receipt"
    /bin/sync
    /bin/cat "$receipt"
    """#
}
