#!/bin/zsh
# Root-only boot path; a missing or ambiguous disk never starts tenant work.
set -euo pipefail
umask 077
fail() { print -u2 -- "Sandbox bootstrap failed: $1"; exit 1; }
[[ $EUID == 0 ]] || fail 'requires guest root'
[[ $(/usr/sbin/sysctl -n kern.hv_vmm_present) == 1 ]] || fail 'requires a virtual machine'
state=/var/db/darkbloom-sandbox
[[ ! -L $state && $(/usr/bin/stat -f '%u:%Lp' "$state") == 0:700 ]] || fail 'unsafe state directory'
scratch=$(/usr/bin/mktemp -d "$state/bootstrap.XXXXXXXX")
trap '/bin/rm -rf -- "$scratch"' EXIT

field() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }
info() { /usr/sbin/diskutil info -plist "$1" > "$2"; }
/usr/sbin/diskutil list -plist > "$scratch/disks.plist"
disks=("${(@f)$(/usr/bin/plutil -extract AllDisks xml1 -o - "$scratch/disks.plist" | /usr/bin/sed -n 's/.*<string>\(disk[0-9s]*\)<\/string>.*/\1/p')}")
control=''
workspace=''
for disk in "${disks[@]}"; do
  info "$disk" "$scratch/info.plist"
  label=$(field "$scratch/info.plist" VolumeName 2>/dev/null || true)
  case $label in
    DBCONTROL)
      [[ -z $control ]] || fail 'duplicate control volume'
      control=$disk ;;
    DBWORK)
      [[ -z $workspace ]] || fail 'duplicate workspace volume'
      workspace=$disk ;;
  esac
done
[[ -n $control && -n $workspace ]] || fail 'control or workspace disk absent'

whole_disk() {
  info "$1" "$scratch/volume.plist"
  [[ $(field "$scratch/volume.plist" FilesystemType) == apfs ]] || fail 'disk must be APFS'
  if field "$scratch/volume.plist" APFSPhysicalStores.1 >/dev/null 2>&1; then
    fail 'multiple APFS physical stores are unsupported'
  fi
  physical=$(field "$scratch/volume.plist" APFSPhysicalStores.0.APFSPhysicalStore)
  info "$physical" "$scratch/physical.plist"
  field "$scratch/physical.plist" ParentWholeDisk
}
control_whole=$(whole_disk "$control")
workspace_whole=$(whole_disk "$workspace")
[[ $control_whole != $workspace_whole ]] || fail 'control and workspace share a disk'
info "$control_whole" "$scratch/control-disk.plist"
[[ $(field "$scratch/control-disk.plist" WritableMedia) == false ]] || fail 'control media must be read-only'

/bin/mkdir -p "$state/control"
[[ ! -L $state/control ]] || fail 'control mountpoint is a symlink'
info "$control" "$scratch/control-volume.plist"
mounted=$(field "$scratch/control-volume.plist" MountPoint 2>/dev/null || true)
if [[ -n $mounted && $mounted != "$state/control" ]]; then
  /usr/sbin/diskutil unmount "$control" >/dev/null
fi
/usr/sbin/diskutil mount readOnly -mountPoint "$state/control" "$control" >/dev/null
configuration="$state/control/instance.json"
[[ -f $configuration && ! -L $configuration ]] || fail 'configuration absent'
[[ $(/usr/bin/stat -f '%Lp:%l' "$configuration") == 600:1 ]] || fail 'unsafe configuration permissions'
source_owner=$(/usr/bin/stat -f %u "$configuration")
[[ $source_owner != 2001 ]] || fail 'tenant owns control configuration'
# The broker UID can differ from root in the guest. It must not identify any
# guest non-root account that could read the media before the root-only copy.
/usr/bin/dscl . -list /Users UniqueID > "$scratch/users.txt"
if [[ $source_owner != 0 ]] && /usr/bin/awk -v uid="$source_owner" '$2 == uid {found=1} END {exit !found}' "$scratch/users.txt"; then
  fail 'control owner is an active guest account'
fi
[[ $(field "$configuration" version) == 1 ]] || fail 'unsupported configuration version'
[[ $(field "$configuration" workspacePath) == /workspace ]] || fail 'unexpected workspace path'
[[ $(field "$configuration" tenantUID) == 2001 && $(field "$configuration" tenantGID) == 2001 ]] || fail 'unexpected tenant identity'
expected=$(field "$configuration" workspaceDiskBytes)
[[ $expected == <-> ]] || fail 'workspace disk capacity absent'
info "$workspace_whole" "$scratch/workspace-disk.plist"
[[ $(field "$scratch/workspace-disk.plist" TotalSize) == "$expected" ]] || fail 'workspace disk capacity mismatch'
[[ $(field "$scratch/workspace-disk.plist" WritableMedia) == true ]] || fail 'workspace media is read-only'

requirement='anchor apple generic and identifier "io.darkbloom.sandbox.guest" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
/usr/bin/codesign --verify --strict "-R=$requirement" /usr/local/libexec/darkbloom-sandbox-guest
# A restarted supervisor may inherit a still-running tenant. Stop it before
# any workspace mount/path operation; native serve repeats the proof and uses
# only descriptor-relative nofollow operations for tenant-controlled entries.
/usr/local/libexec/darkbloom-sandbox-guest quiesce-tenant
/bin/mkdir -p /workspace
[[ ! -L /workspace ]] || fail 'workspace mountpoint is a symlink'
info "$workspace" "$scratch/workspace-volume.plist"
mounted=$(field "$scratch/workspace-volume.plist" MountPoint 2>/dev/null || true)
if [[ -n $mounted && $mounted != /workspace ]]; then
  /usr/sbin/diskutil unmount "$workspace" >/dev/null
fi
/usr/sbin/diskutil mount -mountPoint /workspace "$workspace" >/dev/null
[[ $(/usr/bin/stat -f %d /workspace) != $(/usr/bin/stat -f %d /) ]] || fail 'workspace is not separate from boot volume'
for group in admin wheel operator; do
  membership=$(/usr/bin/dsmemberutil checkmembership -U darkbloomtenant -G "$group")
  [[ $membership == *'is not a member'* ]] || fail "forbidden tenant group: $group"
done
/usr/bin/codesign --verify --strict "-R=$requirement" /usr/local/libexec/darkbloom-sandbox-guest
/usr/bin/install -o root -g wheel -m 0600 "$configuration" "$scratch/instance.json"
/bin/mv -f "$scratch/instance.json" "$state/instance.json"
/bin/rm -rf -- "$scratch"
trap - EXIT
exec /usr/local/libexec/darkbloom-sandbox-guest serve --configuration "$state/instance.json"
