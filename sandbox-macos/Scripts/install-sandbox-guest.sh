#!/bin/zsh
# Run only inside a disposable base VM. No Python/CLT dependency in the guest.
set -euo pipefail
umask 077
fail() { print -u2 -- "Guest installation failed: $1"; exit 1; }
retire_lume=0
[[ $# -ge 1 && $1 == --install ]] || fail 'usage: install-sandbox-guest.sh --install [--retire-lume-bootstrap]'
shift
if [[ $# == 1 && $1 == --retire-lume-bootstrap ]]; then
  retire_lume=1
  shift
fi
[[ $# == 0 ]] || fail 'unsupported installation arguments'
[[ $EUID == 0 ]] || fail 'requires root inside the guest'
[[ $(/usr/sbin/sysctl -n kern.hv_vmm_present) == 1 ]] || fail 'refusing a physical host'
source_dir=${0:A:h}
requirement='anchor apple generic and identifier "io.darkbloom.sandbox.guest" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
/usr/bin/codesign --verify --strict "-R=$requirement" "$source_dir/darkbloom-sandbox-guest"

has_lume=0
if /usr/bin/dscl . -read /Users/lume >/dev/null 2>&1; then
  has_lume=1
  (( retire_lume == 1 )) || fail 'known bootstrap account requires --retire-lume-bootstrap'
  bootstrap_uid=$(/usr/bin/dscl . -read /Users/lume UniqueID | /usr/bin/awk '{print $2}')
  bootstrap_home=$(/usr/bin/dscl . -read /Users/lume NFSHomeDirectory | /usr/bin/awk '{print $2}')
  [[ $bootstrap_uid == 501 && $bootstrap_home == /Users/lume ]] || fail 'unexpected bootstrap identity; refusing to modify it'
fi
unexpected=$(/usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '$2 >= 500 && $1 != "lume" && $1 != "nobody" {print $1}')
[[ -z $unexpected ]] || fail 'unexpected non-system account in base VM'
for policy in /private/etc/sudoers /private/etc/sudoers.d/*(N); do
  [[ ! -L $policy && $(/usr/bin/stat -f %u "$policy") == 0 ]] || fail 'unsafe sudoers policy'
  rules=$(/usr/bin/sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$policy")
  if [[ $policy == /private/etc/sudoers.d/lume ]]; then
    [[ $has_lume == 1 ]] || fail 'unexpected bootstrap sudoers policy'
    [[ $(print -r -- "$rules" | /usr/bin/wc -l | /usr/bin/tr -d ' ') == 1 ]] || fail 'unexpected bootstrap sudoers content'
    print -r -- "$rules" | /usr/bin/grep -Eq '^[[:space:]]*lume[[:space:]]+ALL[[:space:]]*=[[:space:]]*\(ALL(:ALL)?\)[[:space:]]+NOPASSWD:[[:space:]]*ALL[[:space:]]*$' || fail 'unexpected bootstrap sudoers rule'
  elif print -r -- "$rules" | /usr/bin/grep -q NOPASSWD; then
    fail 'unexpected passwordless sudo policy'
  fi
done

for record in /Users/darkbloomtenant /Groups/darkbloomtenant; do
  if /usr/bin/dscl . -read "$record" >/dev/null 2>&1; then
    fail 'tenant identity already exists; use a fresh base VM'
  fi
done
[[ -z $(/usr/bin/dscl . -search /Users UniqueID 2001) ]] || fail 'UID 2001 is allocated'
[[ -z $(/usr/bin/dscl . -search /Groups PrimaryGroupID 2001) ]] || fail 'GID 2001 is allocated'
for target in /usr/local/libexec/darkbloom-sandbox-guest /usr/local/libexec/darkbloom-sandbox-bootstrap.sh /Library/LaunchDaemons/io.darkbloom.sandbox.guest.plist /var/db/darkbloom-sandbox; do
  [[ ! -e $target && ! -L $target ]] || fail "destination already exists: $target"
done
for ancestor in /usr /usr/local /usr/local/libexec /Library /Library/LaunchDaemons /private/var/db; do
  [[ ! -L $ancestor ]] || fail "symlink ancestor: $ancestor"
  if [[ -e $ancestor ]]; then
    [[ $(/usr/bin/stat -f %u "$ancestor") == 0 ]] || fail "non-root ancestor: $ancestor"
    mode=$(/usr/bin/stat -f %Lp "$ancestor")
    (( (8#$mode & 8#022) == 0 )) || fail "writable ancestor: $ancestor"
  fi
done

/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/libexec
/usr/bin/install -o root -g wheel -m 0755 "$source_dir/darkbloom-sandbox-guest" /usr/local/libexec/darkbloom-sandbox-guest
/usr/bin/install -o root -g wheel -m 0755 "$source_dir/darkbloom-sandbox-bootstrap.sh" /usr/local/libexec/darkbloom-sandbox-bootstrap.sh
/usr/bin/install -o root -g wheel -m 0644 "$source_dir/io.darkbloom.sandbox.guest.plist" /Library/LaunchDaemons/io.darkbloom.sandbox.guest.plist
/usr/bin/install -d -o root -g wheel -m 0700 /var/db/darkbloom-sandbox
/usr/bin/codesign --verify --strict "-R=$requirement" /usr/local/libexec/darkbloom-sandbox-guest
# Only stage a one-column synthetic manifest. The sealed root exposes this
# empty mountpoint at the next clone boot, after base-image shutdown.
/usr/local/libexec/darkbloom-sandbox-guest provision-workspace-mountpoint
/usr/local/libexec/darkbloom-sandbox-guest validate-tenant-identity
if (( has_lume == 1 )); then
  # The existing provisioning SSH session may finish; future boots cannot start sshd.
  /bin/launchctl disable system/com.openssh.sshd
  if [[ -f /private/etc/sudoers.d/lume ]]; then
    /bin/rm /private/etc/sudoers.d/lume
  fi
  /usr/sbin/dseditgroup -o edit -d lume -t user admin
  /usr/bin/dscl . -delete /Users/lume
  if /usr/bin/dscl . -read /Users/lume >/dev/null 2>&1; then
    fail 'bootstrap account retirement did not complete'
  fi
fi
/usr/sbin/visudo -c >/dev/null
print 'Guest supervisor installed; no service started. Per-instance control disk and bounded workspace are required.'
