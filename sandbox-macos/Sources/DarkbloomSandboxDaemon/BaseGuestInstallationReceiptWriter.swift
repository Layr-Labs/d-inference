enum BaseGuestInstallationReceiptWriter {
    // plutil can emit JSON but cannot edit a JSON document in place on macOS.
    // Build an XML plist, convert once, then publish the completed private file.
    // Positional arguments keep values out of executable shell source.
    static let shellFunction = #"""
    write_base_installation_receipt() (
      set -euo pipefail
      umask 077
      [[ $# == 7 ]] || exit 70
      destination=$1
      [[ ! -e $destination && ! -L $destination ]] || exit 70
      temporary=$(/usr/bin/mktemp "${destination}.XXXXXX")
      trap '[[ -z $temporary ]] || /bin/rm -f "$temporary"' EXIT
      /usr/bin/plutil -create xml1 "$temporary"
      /usr/bin/plutil -insert schemaVersion -integer 1 "$temporary"
      /usr/bin/plutil -insert guestSHA256 -string "$2" "$temporary"
      /usr/bin/plutil -insert bootstrapSHA256 -string "$3" "$temporary"
      /usr/bin/plutil -insert launchdSHA256 -string "$4" "$temporary"
      /usr/bin/plutil -insert installerSHA256 -string "$5" "$temporary"
      /usr/bin/plutil -insert guestOperatingSystemVersion -string "$6" "$temporary"
      /usr/bin/plutil -insert guestArchitecture -string "$7" "$temporary"
      /usr/bin/plutil -insert bootstrapRetired -bool true "$temporary"
      /usr/bin/plutil -convert json "$temporary"
      /bin/chmod 0600 "$temporary"
      # A hard link publishes atomically without replacing an existing receipt.
      /bin/ln -h "$temporary" "$destination"
      /bin/rm -f "$temporary"
      temporary=''
      /bin/sync
      /bin/cat "$destination"
    )
    """#
}
