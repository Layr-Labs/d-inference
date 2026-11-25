#!/usr/bin/env bash
# Check that the zip and the disk image electron-builder packaged hold the app
# the signing job signed, unchanged, and nothing else. release-desktop.yml runs
# this before the disk image is signed, so the Developer ID signature goes only
# on a container of the signed, notarized app.
#
# "Unchanged" is the code directory hash: it covers the executable, every
# nested signature and every sealed resource. Each copy must also verify and
# carry the notarization ticket. The zip is extracted to WORK/from-zip, which
# the release verification reads afterwards. WORK must not exist.
#
# usage: check-desktop-packages.sh SIGNED_APP ZIP DMG WORK
set -euo pipefail

[[ $# == 4 ]] || { echo 'usage: check-desktop-packages.sh SIGNED_APP ZIP DMG WORK' >&2; exit 2; }
signed_app=$1
zip=$2
dmg=$3
work=$4

fail() {
  echo "::error::$1" >&2
  exit 1
}

# Empty when the path has no code signature; the callers decide what that means.
cdhash() {
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' || true
}

expected=$(cdhash "$signed_app")
[[ "$expected" =~ ^[0-9a-f]{40}$ ]] || fail "The signed app has no code directory hash: $signed_app"

same_app() {
  [[ -d "$1" && ! -L "$1" ]] || fail "Missing app: $1"
  codesign --verify --deep --strict --verbose=2 "$1"
  xcrun stapler validate "$1"
  [[ "$(cdhash "$1")" == "$expected" ]] || fail "$1 is not the app the signing job signed"
}

mkdir "$work"
ditto -x -k "$zip" "$work/from-zip"
[[ "$(ls -A "$work/from-zip")" == Darkbloom.app ]] || fail 'The zip holds more than the app'
same_app "$work/from-zip/Darkbloom.app"

hdiutil verify "$dmg"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$work/dmg" >/dev/null
trap 'hdiutil detach "$work/dmg" >/dev/null || true' EXIT
while IFS= read -r entry; do
  case "$entry" in
    Darkbloom.app | Applications | .DS_Store | .VolumeIcon.icns | .background.tiff | .fseventsd) ;;
    *) fail "Unexpected entry in the disk image: $entry" ;;
  esac
done < <(ls -A "$work/dmg")
# The layout files are written by the packaging job, which ran npm code: each
# must be a plain file (no link, folder or app inside), and .fseventsd a folder
# of plain files only.
for entry in .DS_Store .VolumeIcon.icns .background.tiff; do
  if [[ -e "$work/dmg/$entry" || -L "$work/dmg/$entry" ]]; then
    [[ -f "$work/dmg/$entry" && ! -L "$work/dmg/$entry" ]] || fail "Disk image entry $entry is not a regular file"
  fi
done
if [[ -e "$work/dmg/.fseventsd" || -L "$work/dmg/.fseventsd" ]]; then
  [[ -d "$work/dmg/.fseventsd" && ! -L "$work/dmg/.fseventsd" ]] || fail 'Disk image entry .fseventsd is not a folder'
  [[ -z "$(find "$work/dmg/.fseventsd" -mindepth 1 \( ! -type f -o -type l \) -print -quit)" ]] \
    || fail 'Disk image entry .fseventsd holds something other than plain files'
fi
[[ "$(readlink "$work/dmg/Applications")" == /Applications ]] || fail 'The disk image has no link to /Applications'
same_app "$work/dmg/Darkbloom.app"
# The disk image is signed next, so it must be detached; a failed detach fails here.
trap - EXIT
hdiutil detach "$work/dmg" >/dev/null
