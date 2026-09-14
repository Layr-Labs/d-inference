enum AccountlessInstallationGuestChecks {
    /// Fixed installer checks and bounded diagnostics; sourcing does no work.
    static let shell = #"""
    hash_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
    safe_root_file() {
      local file=$1 mode
      [[ -f $file && ! -L $file && $(/usr/bin/stat -f '%u:%g:%l' "$file") == 0:0:1 ]] || return 1
      mode=$(/usr/bin/stat -f %Lp "$file") || return 1
      (( (8#$mode & 8#022) == 0 ))
    }
    observe_accounts() {
      local summary
      summary=$(/usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '
        NF != 2 || ($2 !~ /^[0-9]+$/ && !($1 == "nobody" && $2 == "-2")) { bad=1; next }
        { records++ }
        $1 == "root" { if ($2 != "0") bad=1; root++ }
        $1 == "lume" { lume++ }
        $2 >= 500 && $1 != "nobody" { human++ }
        END { if (bad || records == 0 || root != 1) exit 1; printf "%d %d\n", human, lume }') || return 1
      local -a counts=( ${=summary} )
      [[ ${#counts} == 2 && ${counts[1]} =~ '^[0-9]{1,4}$' && ${counts[2]} =~ '^[0-9]{1,4}$' ]] || return 1
      human_count=${counts[1]} lume_count=${counts[2]}
    }
    verify_installed_payload() {
      local guest=/usr/local/libexec/darkbloom-sandbox-guest
      local bootstrap=/usr/local/libexec/darkbloom-sandbox-bootstrap.sh
      local job=/Library/LaunchDaemons/io.darkbloom.sandbox.guest.plist
      local synthetic=/private/etc/synthetic.d/io.darkbloom.sandbox
      for file in "$guest" "$bootstrap" "$job" "$synthetic"; do safe_root_file "$file" || return 1; done
      [[ $(hash_file "$guest") == "$guest_sha" && $(hash_file "$bootstrap") == "$bootstrap_sha" &&
         $(hash_file "$job") == "$launchd_sha" && $(/usr/bin/stat -f %z "$synthetic") == 10 &&
         $(<"$synthetic") == workspace ]] || return 1
      /usr/bin/codesign --verify --strict "-R=$guest_requirement" "$guest" >/dev/null 2>&1
    }
    run_bounded_log() {
      emulate -L zsh
      setopt NO_UNSET PIPE_FAIL
      local destination=$1
      shift
      [[ $# -ge 1 && $destination == /* && ! -e $destination && ! -L $destination ]] || return 70
      local -a statuses
      "$@" 2>&1 | /usr/bin/head -c 65537 > "$destination"
      statuses=("${pipestatus[@]}")
      command_exit=${statuses[1]} capture_exit=${statuses[2]} capture_overflow=false
      diagnostic_bytes=$(/usr/bin/stat -f %z "$destination") || return 70
      if (( diagnostic_bytes > 65536 )); then
        capture_overflow=true
        /usr/bin/head -c 65536 "$destination" > "$destination.bounded" || return 70
        /bin/mv -f "$destination.bounded" "$destination" || return 70
        diagnostic_bytes=65536
      fi
    }
    """#
}
